struct ShmAllocError <: Exception
    kind::Symbol
end
struct ShmLayoutError <: Exception
    kind::Symbol
end
Base.showerror(io::IO, e::ShmAllocError) = print(io, "ShmAllocError(:", e.kind, ")")
Base.showerror(io::IO, e::ShmLayoutError) = print(io, "ShmLayoutError(:", e.kind, ")")

function _alloc_error_sym(e::LibZenohC.z_alloc_error_t)
    e == LibZenohC.Z_ALLOC_ERROR_NEED_DEFRAGMENT && return :need_defragment
    e == LibZenohC.Z_ALLOC_ERROR_OUT_OF_MEMORY   && return :out_of_memory
    return :other
end
function _layout_error_sym(e::LibZenohC.z_layout_error_t)
    e == LibZenohC.Z_LAYOUT_ERROR_INCORRECT_LAYOUT_ARGS && return :incorrect_layout_args
    return :provider_incompatible
end

abstract type AbstractShmProvider end

mutable struct ShmProvider <: AbstractShmProvider
    p::Base.RefValue{LibZenohC.z_owned_shm_provider_t}
end
function ShmProvider(size::Integer)
    ref = Ref{LibZenohC.z_owned_shm_provider_t}()
    _handle_result(LibZenohC.z_posix_shm_provider_new(ref, Csize_t(size)))
    finalizer(r -> _drop(_move(r)), ref)
    return ShmProvider(ref)
end

mutable struct SharedShmProvider <: AbstractShmProvider
    p::Base.RefValue{LibZenohC.z_owned_shared_shm_provider_t}
    session::Session
end
function obtain_shm_provider(s::Session)
    ref = Ref{LibZenohC.z_owned_shared_shm_provider_t}()
    state = Ref{LibZenohC.z_shm_provider_state}(LibZenohC.Z_SHM_PROVIDER_STATE_DISABLED)
    _handle_result(LibZenohC.z_obtain_shm_provider(_loan(s), ref, state))
    finalizer(r -> _drop(_move(r)), ref)
    return SharedShmProvider(ref, s)
end

_loan_provider(p::ShmProvider) = _loan(p.p)
_loan_provider(p::SharedShmProvider) =
    LibZenohC.z_shared_shm_provider_loan_as(LibZenohC.z_shared_shm_provider_loan(p.p))

available(p::AbstractShmProvider)       = Int(LibZenohC.z_shm_provider_available(_loan_provider(p)))
defragment(p::AbstractShmProvider)      = Int(LibZenohC.z_shm_provider_defragment(_loan_provider(p)))
garbage_collect(p::AbstractShmProvider) = Int(LibZenohC.z_shm_provider_garbage_collect(_loan_provider(p)))

mutable struct ShmBufMut
    b::Base.RefValue{LibZenohC.z_owned_shm_mut_t}
    mem::Memory{UInt8}
end

mutable struct ShmBuf{R <: Union{Base.RefValue{LibZenohC.z_owned_shm_t},
                                  Ptr{LibZenohC.z_loaned_shm_t}}}
    b::R
    mem::Memory{UInt8}
    parent::Any
end

Base.length(b::ShmBufMut) = length(b.mem)
Base.length(b::ShmBuf)    = length(b.mem)
Base.pointer(b::ShmBufMut) = pointer(b.mem)
Base.pointer(b::ShmBuf)    = pointer(b.mem)
data(b::ShmBufMut) = b.mem
data(b::ShmBuf)    = b.mem
Base.copyto!(b::ShmBufMut, src::AbstractVector{UInt8}) =
    (length(src) <= length(b.mem) || throw(BoundsError(b.mem, length(src)));
     unsafe_copyto!(pointer(b.mem), pointer(src), length(src)); b)

function _alignment(align::Integer)
    align > 0 || throw(ArgumentError("alignment must be > 0"))
    p = trailing_zeros(align)
    (1 << p) == align || throw(ArgumentError("alignment must be a power of 2"))
    return LibZenohC.z_alloc_alignment_t(UInt8(p))
end

function alloc(p::AbstractShmProvider, n::Integer;
        align::Union{Nothing,Integer}=nothing, blocking::Bool=false)
    result = Ref{LibZenohC.z_buf_layout_alloc_result_t}()
    lp = _loan_provider(p)
    GC.@preserve p begin
        if blocking
            if align === nothing
                LibZenohC.z_shm_provider_alloc_gc_defrag_blocking(result, lp, Csize_t(n))
            else
                LibZenohC.z_shm_provider_alloc_gc_defrag_blocking_aligned(
                    result, lp, Csize_t(n), _alignment(align))
            end
        else
            if align === nothing
                LibZenohC.z_shm_provider_alloc(result, lp, Csize_t(n))
            else
                LibZenohC.z_shm_provider_alloc_aligned(
                    result, lp, Csize_t(n), _alignment(align))
            end
        end
    end
    status = result[].status
    if status == LibZenohC.ZC_BUF_LAYOUT_ALLOC_STATUS_OK
        # Extract the moved z_owned_shm_mut_t from the result struct via _take,
        # which leaves the source in a moved-from state so result_ref's stack
        # storage holds no live ownership.
        buf_ref = Ref{LibZenohC.z_owned_shm_mut_t}()
        GC.@preserve result buf_ref begin
            res_ptr = Base.unsafe_convert(
                Ptr{LibZenohC.z_buf_layout_alloc_result_t}, result)
            buf_src = Base.getproperty(res_ptr, :buf)  # Ptr{z_owned_shm_mut_t}
            # Move semantics, by hand: zenoh-c's z_shm_mut_take / z_shm_mut_move
            # are header-only inlines and not exported as real symbols, and the
            # auto-generated _take has known issues for the symbol-missing case.
            # Bitwise-copy src→dst, then null the source so it carries no
            # residual ownership when the result struct goes out of scope.
            dst_ptr = Base.unsafe_convert(
                Ptr{LibZenohC.z_owned_shm_mut_t}, buf_ref)
            unsafe_store!(dst_ptr, unsafe_load(buf_src))
            LibZenohC.z_internal_shm_mut_null(buf_src)
        end
        finalizer(r -> _drop(_move(r)), buf_ref)
        len = LibZenohC.z_shm_mut_len(_loan(buf_ref))
        ptr = LibZenohC.z_shm_mut_data_mut(_loan_mut(buf_ref))
        mem = unsafe_wrap(Memory{UInt8}, ptr, len)
        return ShmBufMut(buf_ref, mem)
    elseif status == LibZenohC.ZC_BUF_LAYOUT_ALLOC_STATUS_ALLOC_ERROR
        throw(ShmAllocError(_alloc_error_sym(result[].alloc_error)))
    else
        throw(ShmLayoutError(_layout_error_sym(result[].layout_error)))
    end
end

# Freeze a mutable buffer into an immutable one. Consumes `buf`.
function ShmBuf(buf::ShmBufMut)
    out = Ref{LibZenohC.z_owned_shm_t}()
    LibZenohC.z_shm_from_mut(out, _move(buf.b))
    finalizer(r -> _drop(_move(r)), out)
    ptr = LibZenohC.z_shm_data(_loan(out))
    len = LibZenohC.z_shm_len(_loan(out))
    mem = unsafe_wrap(Memory{UInt8}, ptr, len)
    return ShmBuf{Base.RefValue{LibZenohC.z_owned_shm_t}}(out, mem, nothing)
end

# Consume a ShmBufMut into a z_owned_bytes_t. After this call, the underlying
# z_owned_shm_mut_t handle has been moved into zenoh-c's bytes object; the
# original Ref's finalizer becomes a no-op (drop on moved-from is documented
# safe by zenoh-c).
function ZBytes(buf::ShmBufMut)
    out_ref = Ref{LibZenohC.z_owned_bytes_t}()
    _handle_result(LibZenohC.z_bytes_from_shm_mut(out_ref, _move(buf.b)))
    return ZBytes(out_ref, Val(:owned))
end

function ZBytes(buf::ShmBuf{Base.RefValue{LibZenohC.z_owned_shm_t}})
    out_ref = Ref{LibZenohC.z_owned_bytes_t}()
    _handle_result(LibZenohC.z_bytes_from_shm(out_ref, _move(buf.b)))
    return ZBytes(out_ref, Val(:owned))
end

# View a received ZBytes as an SHM buffer. Returns nothing if the bytes are
# not backed by SHM. The returned ShmBuf pins `z` so the loan stays valid.
function as_shm(z::ZBytes)
    out_ptr = Ref{Ptr{LibZenohC.z_loaned_shm_t}}(C_NULL)
    rtc = LibZenohC.z_bytes_as_loaned_shm(_loaned_bytes(z), out_ptr)
    rtc != LibZenohC.Z_OK && return nothing
    loaned = out_ptr[]
    loaned == C_NULL && return nothing
    ptr = LibZenohC.z_shm_data(loaned)
    len = LibZenohC.z_shm_len(loaned)
    mem = unsafe_wrap(Memory{UInt8}, ptr, len)
    return ShmBuf{Ptr{LibZenohC.z_loaned_shm_t}}(loaned, mem, z)
end

function is_shm(z::ZBytes)
    out_ptr = Ref{Ptr{LibZenohC.z_loaned_shm_t}}(C_NULL)
    return LibZenohC.z_bytes_as_loaned_shm(_loaned_bytes(z), out_ptr) == LibZenohC.Z_OK
end

cleanup_orphaned_shm_segments() = LibZenohC.zc_cleanup_orphaned_shm_segments()

# Specializations for `put(...; shm=provider, ...)`. The Nothing fallback is
# defined in Zenoh.jl so `put` works without shm.jl needing to be loaded yet.
function _shm_zbytes(provider::AbstractShmProvider, data::AbstractVector{UInt8})
    buf = alloc(provider, length(data))
    copyto!(buf, data)
    return ZBytes(buf)
end
function _shm_zbytes(provider::AbstractShmProvider, s::AbstractString)
    bytes = codeunits(s)
    buf = alloc(provider, length(bytes))
    GC.@preserve s begin
        unsafe_copyto!(pointer(buf.mem), Base.unsafe_convert(Ptr{UInt8}, s), length(bytes))
    end
    return ZBytes(buf)
end
function _shm_zbytes(provider::AbstractShmProvider, r::Base.RefValue{T}) where T
    buf = alloc(provider, sizeof(T))
    GC.@preserve r begin
        src = Base.unsafe_convert(Ptr{UInt8}, Base.unsafe_convert(Ptr{T}, r))
        unsafe_copyto!(pointer(buf.mem), src, sizeof(T))
    end
    return ZBytes(buf)
end
function _shm_zbytes(provider::AbstractShmProvider, v::AbstractVector{T}) where T
    nbytes = length(v) * sizeof(T)
    buf = alloc(provider, nbytes)
    GC.@preserve v begin
        unsafe_copyto!(pointer(buf.mem), Base.unsafe_convert(Ptr{UInt8}, pointer(v)), nbytes)
    end
    return ZBytes(buf)
end

export AbstractShmProvider, ShmProvider, SharedShmProvider
export ShmBuf, ShmBufMut
export ShmAllocError, ShmLayoutError
export obtain_shm_provider, alloc, available, defragment, garbage_collect
export data, as_shm, is_shm, cleanup_orphaned_shm_segments
