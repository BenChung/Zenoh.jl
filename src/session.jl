struct Session 
    s::Base.RefValue{LibZenohC.z_owned_session_t}
    Session() = new(Ref{LibZenohC.z_owned_session_t}())
end

"""
Opens a new Zenoh session with a given Zenoh config. Copies the config.
"""
function Base.open(c::Config)
    s = Session()
    cfg_copy = Ref{LibZenohC.z_owned_config_t}()
    LibZenohC.z_config_clone(cfg_copy, LibZenohC.z_config_loan(c.c))

    # there's no options?
    opts = Ref{LibZenohC.z_open_options_t}()
    LibZenohC.z_open_options_default(opts)

    result = LibZenohC.z_open(s.s, _move(cfg_copy), opts)
    _handle_result(result)

    finalizer(s -> _drop(_move(s)), s.s)
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
    res = unsafe_string(LibZenohC.z_string_data(_loan(r)))
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