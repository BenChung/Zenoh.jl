mutable struct ShmClientStorage
    s::Base.RefValue{LibZenohC.z_owned_shm_client_storage_t}
end

function default_shm_clients()
    ref = Ref{LibZenohC.z_owned_shm_client_storage_t}()
    LibZenohC.z_shm_client_storage_new_default(ref)
    finalizer(r -> _drop(_move(r)), ref)
    return ShmClientStorage(ref)
end

export ShmClientStorage, default_shm_clients
