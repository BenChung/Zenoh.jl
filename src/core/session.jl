"""
    Session

The central Zenoh runtime handle, holding the connection state of this node to
the Zenoh network. Wraps an owned `z_owned_session_t` and is the object every
[`put`](@ref), [`get`](@ref), and declaration ([`Publisher`](@ref),
[`Subscriber`](@ref), [`Queryable`](@ref)) routes through — internally via a
`_loan` chokepoint that throws once the session is closed, so a use-after-free
can never reach the dropped handle.

Open one with [`open`](@ref)`(::Config)` and release it with [`close`](@ref),
which runs the graceful shutdown and frees the handle deterministically on the
calling task. A GC finalizer drops the handle as a safety net for sessions that
were never explicitly closed.

The struct stays immutable; close state and discovered shared-memory capability
live in mutable cells so they can be updated in place. Query identity and
topology with [`zid`](@ref), [`router_zids`](@ref), and [`peer_zids`](@ref).
"""
struct Session
    s::Base.RefValue{LibZenohC.z_owned_session_t}
    # Cached session-derived SHM provider (a `SharedShmProvider`) or `nothing`.
    # Populated by `open` only when `shm_clients` is passed *and* the build
    # actually enables SHM; otherwise stays `nothing`. Held in a mutable cell
    # so `Session` can remain immutable. `zref(::Session, T)` reads this to
    # decide its backing — see types/zref.jl. The cached provider deliberately
    # does NOT back-reference the session (see `_obtain_shared_provider`), so
    # there is no session⇄provider finalizer cycle.
    shm::Base.RefValue{Any}
    # Optional user callback invoked when `zref(::Session, T)` hits a
    # `ShmAllocError` (segment full / needs defrag) before degrading to Julia
    # memory. `nothing` (the default) means degrade silently. The callback
    # receives the `ShmAllocError`; if it throws, the error propagates out of
    # `zref` (turning the silent fallback into explicit failure).
    shm_alloc_handler::Base.RefValue{Any}
    # Discovered SHM capability, snapshotted at `open` from the provider state
    # zenoh-c reports. See `shm_state` / `shm_capable`. `:none` until probed.
    shm_state::Base.RefValue{Symbol}
    # Serializes the lazy SHM bind (`_bind_session_shm!`): the first-bind
    # check-obtain-cache is otherwise an unsynchronized read/write of `shm`/
    # `shm_state`, reachable concurrently from `open`, `zref(s,T)`, and
    # `shm_ready`. The cached fast path (`shm[] !== nothing`) returns before
    # taking this, so there is no hot-path cost.
    shm_lock::ReentrantLock
    # `true` once `close` (or the finalizer) has torn the session down. Atomic on
    # two counts: it keeps `Session` immutable, and its check-then-set serializes
    # concurrent closes against a double-drop. Every handle accessor reads it (as
    # `closed[]`) and throws rather than touch a freed handle.
    closed::Threads.Atomic{Bool}
    Session() = new(Ref{LibZenohC.z_owned_session_t}(),
                    Ref{Any}(nothing), Ref{Any}(nothing), Ref{Symbol}(:none),
                    ReentrantLock(), Threads.Atomic{Bool}(false))
end

# Loan the session for any operation; throws once closed so a use-after-free
# can't reach the dropped handle (this is the chokepoint every declare/put/get
# routes through).
function _loan(s::Session)
    s.closed[] && throw(ArgumentError("session is closed"))
    return _loan(s.s)
end

"""
Opens a new Zenoh session with a given Zenoh config. Copies the config.

Pass `shm_clients=default_shm_clients()` (or a custom `ShmClientStorage`) to
open the session with shared-memory client support enabled. When unset, the
session is opened without SHM clients — same behavior as zenoh-c's `z_open`.

`on_shm_alloc_error` registers a callback invoked when `zref(::Session, T)`
fails to allocate from the session's SHM provider (a `ShmAllocError` — segment
full or needing defragmentation) and is about to fall back to Julia memory. The
callback receives the `ShmAllocError`; return normally to allow the (silent)
fallback, or `throw` to escalate the failure out of `zref`. When unset, the
fallback is silent (a `@debug` is still emitted).

`wait_for_shm` blocks until the session's SHM provider is ready before
returning (only meaningful with `shm_clients`). `true` waits up to
`shm_wait_timeout` seconds; a number waits up to that many seconds; `false`
(default) returns immediately. Waiting only applies while the provider is
`:initializing` — terminal states (`:unavailable`/`:disabled`/`:error`) return
at once. Inspect `shm_state(s)` / `shm_ready(s)` afterwards to see the outcome.
"""
function Base.open(c::Config; shm_clients=nothing, on_shm_alloc_error=nothing,
        wait_for_shm::Union{Bool,Real}=false, shm_wait_timeout::Real=10.0)
    s = Session()
    s.shm_alloc_handler[] = on_shm_alloc_error
    # Put the handle in a valid (null) state and arm the safety-net finalizer
    # BEFORE the fallible open, so a throwing `z_open` can't strand a
    # partially-initialized session for the process lifetime: the finalizer then
    # drops a null handle (a documented no-op) on failure, or the real handle once
    # open succeeds. It frees on GC only if the session wasn't explicitly closed —
    # `close` tears down deterministically on the caller's thread and flips
    # `closed`, keeping the graceful `z_session_drop` (which drains the tokio
    # runtime) off the GC / process-exit finalizer thread.
    LibZenohC.z_internal_session_null(s.s)
    let handle = s.s, closed = s.closed
        finalizer(handle) do h
            # Flip `closed` before dropping so a closed-gated path racing this
            # (notably a `DeclaredKeyexpr` finalizer reading `session.closed[]`)
            # can't observe a live session while the handle is freed.
            Threads.atomic_xchg!(closed, true) || _drop(_move(h))
        end
    end
    cfg_copy = Ref{LibZenohC.z_owned_config_t}()
    GC.@preserve c LibZenohC.z_config_clone(cfg_copy, LibZenohC.z_config_loan(c.c))

    try
        if shm_clients === nothing
            opts = Ref{LibZenohC.z_open_options_t}()
            LibZenohC.z_open_options_default(opts)
            GC.@preserve cfg_copy _handle_result(LibZenohC.z_open(s.s, _move(cfg_copy), opts))
        else
            GC.@preserve cfg_copy _handle_result(LibZenohC.z_open_with_custom_shm_clients(
                s.s, _move(cfg_copy), _loan(shm_clients.s)))
        end
    catch
        # `z_open` consumes `cfg_copy` only on success; a throw before/at the move
        # leaves the clone owned here, so drop it (a no-op if it was moved).
        _drop(_move(cfg_copy))
        rethrow()
    end

    # Discover the session's SHM capability once, here — the one place SHM is
    # acknowledged. `_bind_session_shm!` reads the provider state zenoh-c
    # reports and caches the provider only when it's usable (ready/initializing);
    # `zref(session, T)` then transparently allocates from it, falling back to
    # Julia memory otherwise. `shm_state(s)` exposes what was discovered.
    if shm_clients !== nothing
        _bind_session_shm!(s)
        wait_secs = wait_for_shm === true  ? Float64(shm_wait_timeout) :
                    wait_for_shm === false ? 0.0 : Float64(wait_for_shm)
        wait_secs > 0 && _wait_for_shm_ready!(s, wait_secs)
    end
    return s
end

"""
    close(s::Session; timeout=nothing)

Closes a Zenoh session: gracefully shuts it down (`z_close`) and frees the
handle (`z_session_drop`), deterministically on the calling task. Idempotent — a
second `close` is a no-op, and the GC finalizer skips an already-closed session.
After `close` the session is unusable; operations on it throw.

`z_close` waits up to `timeout` seconds (Zenoh's default is 10 s) for the
session's transports to shut down. Then `close`:

- frees the handle, whatever `z_close` returned;
- logs a warning with the Zenoh result code when the graceful shutdown fails or
  times out;
- returns `nothing`, so a `close` in a `finally` block leaves an in-flight
  exception intact.

Sessions that share a process and a router close promptly in client mode
(`ZenohConfig(mode = :client)`), where each holds a single link, to the router.
Peer-mode siblings gossip-connect to one another, and that link can race a
closing session's teardown and stall every later `close` in the process for the
full timeout. `Gossip(enabled = false)` in [`Scouting`](@ref) also keeps those
sibling links from forming. A smaller `timeout` bounds how long such a stall
blocks the calling task.

!!! warning
    `close` must not run concurrently with in-flight operations on the *same*
    session from other tasks. It frees the handle, so an operation parked in a C
    call holding a pointer loaned from this session (the `_loan` chokepoint checks
    `closed` but does not hold a lock across the call) could touch freed memory.
    Quiesce a shared session — join its publisher/subscriber tasks — before
    closing it.
"""
function Base.close(s::Session; timeout::Union{Nothing,Real}=nothing)
    # Atomically claim the close: only the caller that flips `closed` false→true
    # proceeds, so concurrent closes (or a close racing the finalizer) can't both
    # drop the handle. The `finally` drop below runs unconditionally to close a
    # leak: an interrupted `z_close` must not strand the owned session — and thus
    # its tokio runtime / SHM subsystem — for the process lifetime. The guaranteed
    # drop is why claiming `closed` first never lets the finalizer double-drop.
    Threads.atomic_xchg!(s.closed, true) && return nothing
    opts = Ref{LibZenohC.z_close_options_t}()
    LibZenohC.z_close_options_default(opts)
    if timeout !== nothing
        timeout >= 0 || throw(ArgumentError("close timeout must be non-negative, got $timeout"))
        Base.unsafe_convert(Ptr{LibZenohC.z_close_options_t}, opts).internal_timeout_ms =
            UInt32(round(timeout * 1000))
    end
    try
        # GC-safe so a stop-the-world GC on another thread can proceed while z_close
        # blocks (up to the timeout); sound because the call reads only pointers
        # pinned by the `@preserve`.
        sp = _loan(s.s)
        rc = GC.@preserve s opts begin
            @ccall gc_safe=true LibZenohC.libzenohc.z_close(
                sp::Ptr{LibZenohC.z_loaned_session_t},
                opts::Ptr{LibZenohC.z_close_options_t})::LibZenohC.z_result_t
        end
        # A warning suffices: the handle is freed below regardless, and throwing
        # would mask an in-flight exception when `close` runs in a `finally`.
        rc == LibZenohC.Z_OK ||
            @warn "Graceful session close did not complete; the handle was freed anyway" zenoh_result=rc
    finally
        _drop(_move(s.s))   # free now, on this task — even if z_close errored
        # Close the cached SHM provider with the session, which unlocks its pool now
        # instead of at the next GC.
        prov = lock(s.shm_lock) do
            p = s.shm[]
            s.shm[] = nothing
            p
        end
        prov === nothing || close(prov::AbstractShmProvider)
    end
    return nothing
end

"""
Checks if zenoh session is open.
"""
Base.isopen(s::Session) = !s.closed[] && !GC.@preserve s LibZenohC.z_session_is_closed(_loan(s.s))

"""
Returns the session’s Zenoh ID.

A valid session always yields a non-zero ID; an all-zero 16-byte array means the session was invalid.
"""
zid(s::Session) = GC.@preserve s LibZenohC.z_info_zid(_loan(s))

function Base.show(io::IO, id::LibZenohC.z_id_t)
    r=Ref{LibZenohC.z_owned_string_t}()
    idr=Ref{LibZenohC.z_id_t}(id)
    LibZenohC.z_id_to_string(idr, r)
    res = _string(r)
    _drop(_move(r))
    print(io, "z_id: $res")
end

"""
    to_le_bytes(id::z_id_t) -> NTuple{16, UInt8}

The Zenoh id as its raw 16-byte little-endian array — the form zenoh hashes and
serializes (the Rust `ZenohId::to_le_bytes`). Note this is *not* the byte order of
the printed/`show`n string: the string renders these bytes reversed
(most-significant first) with leading zero bytes elided.
"""
to_le_bytes(id::LibZenohC.z_id_t) = getfield(id, :data)

"""
Fetches the Zenoh IDs of all connected routers.
"""
function router_zids(s::Session)
    routers = LibZenohC.z_id_t[]
    recv_func, recv_ctx = cclosure(2, Cvoid, (Ptr{LibZenohC.z_id_t}, )) do id
        push!(routers, unsafe_load(id)) 
        return nothing
    end
    callback = Ref{LibZenohC.z_owned_closure_zid_t}()
    LibZenohC.z_closure_zid(callback, recv_func, C_NULL, recv_ctx)
    GC.@preserve s recv_ctx recv_func callback _handle_result(LibZenohC.z_info_routers_zid(_loan(s), _move(callback)))
    return routers
end

"""
Fetches the Zenoh IDs of all connected peers.
"""
function peer_zids(s::Session)
    routers = LibZenohC.z_id_t[]
    recv_func, recv_ctx = cclosure(2, Cvoid, (Ptr{LibZenohC.z_id_t}, )) do id
        push!(routers, unsafe_load(id)) 
        return nothing
    end
    callback = Ref{LibZenohC.z_owned_closure_zid_t}()
    LibZenohC.z_closure_zid(callback, recv_func, C_NULL, recv_ctx)
    GC.@preserve s recv_ctx recv_func callback _handle_result(LibZenohC.z_info_peers_zid(_loan(s), _move(callback)))
    return routers
end

export Session, zid, router_zids, peer_zids, to_le_bytes