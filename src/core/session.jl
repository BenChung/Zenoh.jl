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
    Session() = new(Ref{LibZenohC.z_owned_session_t}(),
                    Ref{Any}(nothing), Ref{Any}(nothing), Ref{Symbol}(:none))
end

_loan(s::Session) = _loan(s.s)

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

    finalizer(s -> _drop(_move(s)), s.s)

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

function Base.close(s::Session)
    opts = Ref{LibZenohC.z_close_options_t}()
    LibZenohC.z_close_options_default(opts)
    _handle_result(LibZenohC.z_close(_loan(s.s), opts))
end

"""
Checks if zenoh session is open.
"""
Base.isopen(s::Session) = !LibZenohC.z_session_is_closed(_loan(s.s))

"""
Returns the session’s Zenoh ID.

Unless the session is invalid, that ID is guaranteed to be non-zero. In other words, this function returning an array of 16 zeros means you failed to pass it a valid session.
"""
zid(s::Session) = LibZenohC.z_info_zid(_loan(s.s))

function Base.show(io::IO, id::LibZenohC.z_id_t)
    r=Ref{LibZenohC.z_owned_string_t}()
    idr=Ref{LibZenohC.z_id_t}(id)
    LibZenohC.z_id_to_string(idr, r)
    res = _string(r)
    _drop(_move(r))
    print(io, "z_id: $res")
end

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
    GC.@preserve recv_ctx recv_func _handle_result(LibZenohC.z_info_routers_zid(_loan(s.s), _move(callback)))
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
    GC.@preserve recv_ctx recv_func _handle_result(LibZenohC.z_info_peers_zid(_loan(s.s), _move(callback)))
    return routers
end

export Session, zid, router_zids, peer_zids