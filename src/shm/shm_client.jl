"""
    ShmClientStorage

The set of SHM client implementations a session registers at open so it can read incoming
shared-memory buffers. Each registered client knows how to map one SHM protocol's segments
into the process, giving the session the capability to interpret SHM-backed payloads it
receives. Pass one to [`open`](@ref) via the `shm_clients` keyword; without it the session
has no SHM and [`shm_state`](@ref) reports `:none`.

Build the default set with [`default_shm_clients`](@ref). Wraps `z_owned_shm_client_storage_t`.
"""
mutable struct ShmClientStorage
    s::Base.RefValue{LibZenohC.z_owned_shm_client_storage_t}
end

"""
    default_shm_clients() -> ShmClientStorage

A [`ShmClientStorage`](@ref) populated with the default client set, ready to enable shared
memory on a session. Pass it as `open(cfg; shm_clients = default_shm_clients())` so the
session can read SHM buffers for the standard protocols.

Wraps `z_shm_client_storage_new_default`.
"""
function default_shm_clients()
    ref = Ref{LibZenohC.z_owned_shm_client_storage_t}()
    LibZenohC.z_shm_client_storage_new_default(ref)
    finalizer(r -> _drop(_move(r)), ref)
    return ShmClientStorage(ref)
end

"""
    close(cs::ShmClientStorage)

Release the client-storage handle on the calling task rather than at GC.
Idempotent. `open(...; shm_clients=cs)` only *loans* the storage (zenoh-c clones
it internally), so closing `cs` after open does not disturb the session.
"""
function Base.close(cs::ShmClientStorage)
    GC.@preserve cs begin
        sp = Base.unsafe_convert(Ptr{LibZenohC.z_owned_shm_client_storage_t}, cs.s)
        if LibZenohC.z_internal_shm_client_storage_check(sp)
            LibZenohC.z_shm_client_storage_drop(_move(cs.s))
            LibZenohC.z_internal_shm_client_storage_null(sp)
        end
    end
    return nothing
end

export ShmClientStorage, default_shm_clients
