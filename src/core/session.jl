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
    # `true` once `close` (or the finalizer) has torn the session down. In a
    # mutable cell so `Session` stays immutable; guards `close` against running
    # `z_close`/`z_session_drop` twice and lets every handle accessor fail loudly
    # instead of touching a freed handle.
    closed::Base.RefValue{Bool}
    Session() = new(Ref{LibZenohC.z_owned_session_t}(),
                    Ref{Any}(nothing), Ref{Any}(nothing), Ref{Symbol}(:none),
                    Ref(false))
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
    cfg_copy = Ref{LibZenohC.z_owned_config_t}()
    LibZenohC.z_config_clone(cfg_copy, LibZenohC.z_config_loan(c.c))

    if shm_clients === nothing
        opts = Ref{LibZenohC.z_open_options_t}()
        LibZenohC.z_open_options_default(opts)
        _handle_result(LibZenohC.z_open(s.s, _move(cfg_copy), opts))
    else
        _handle_result(LibZenohC.z_open_with_custom_shm_clients(
            s.s, _move(cfg_copy), _loan(shm_clients.s)))
    end

    # Safety net: free the handle on GC only if it wasn't explicitly closed.
    # `close` does the teardown deterministically on the caller's thread and
    # flips `closed`, so for a closed session this no-ops — keeping the
    # graceful `z_session_drop` (which drains the tokio runtime) off the GC /
    # process-exit finalizer thread, where ordering is unpredictable.
    let handle = s.s, closed = s.closed
        finalizer(handle) do h
            closed[] || _drop(_move(h))
        end
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
Closes a Zenoh session: gracefully shuts it down (`z_close`) and frees the
handle (`z_session_drop`), deterministically on the calling task. Idempotent —
a second `close` is a no-op, and the GC finalizer skips an already-closed
session. After `close` the session is unusable; operations on it throw.
"""
function Base.close(s::Session)
    s.closed[] && return nothing
    s.closed[] = true
    opts = Ref{LibZenohC.z_close_options_t}()
    LibZenohC.z_close_options_default(opts)
    GC.@preserve s _handle_result(LibZenohC.z_close(_loan(s.s), opts))
    _drop(_move(s.s))   # free now, on this task — not later on the GC thread
    return nothing
end

"""
Checks if zenoh session is open.
"""
Base.isopen(s::Session) = !s.closed[] && !LibZenohC.z_session_is_closed(_loan(s.s))

"""
Returns the session’s Zenoh ID.

A valid session always yields a non-zero ID; an all-zero 16-byte array means the session was invalid.
"""
zid(s::Session) = LibZenohC.z_info_zid(_loan(s))

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
    GC.@preserve recv_ctx recv_func _handle_result(LibZenohC.z_info_routers_zid(_loan(s), _move(callback)))
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
    GC.@preserve recv_ctx recv_func _handle_result(LibZenohC.z_info_peers_zid(_loan(s), _move(callback)))
    return routers
end

export Session, zid, router_zids, peer_zids, to_le_bytes