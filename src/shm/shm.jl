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
    # The session this provider was derived from. Held to keep the session
    # alive for as long as the provider is used (loaning the provider reaches
    # into session state). `nothing` when the session itself owns the provider
    # (the `Session.shm` cache) — there the session already outlives the
    # provider, so back-referencing it would only create a finalizer cycle.
    session::Union{Session,Nothing}
end

# Obtain the session-derived provider. `keep_session` controls whether the
# returned provider pins its session: true for the standalone public API
# (`obtain_shm_provider`), false for the `Session.shm` cache (avoids a cycle).
function _obtain_shared_provider(s::Session, keep_session::Bool)
    ref = Ref{LibZenohC.z_owned_shared_shm_provider_t}()
    state = Ref{LibZenohC.z_shm_provider_state}(LibZenohC.Z_SHM_PROVIDER_STATE_DISABLED)
    _handle_result(LibZenohC.z_obtain_shm_provider(_loan(s), ref, state))
    finalizer(r -> _drop(_move(r)), ref)
    return SharedShmProvider(ref, keep_session ? s : nothing)
end

obtain_shm_provider(s::Session) = _obtain_shared_provider(s, true)

_shm_state_sym(st::LibZenohC.z_shm_provider_state) =
    st == LibZenohC.Z_SHM_PROVIDER_STATE_READY        ? :ready        :
    st == LibZenohC.Z_SHM_PROVIDER_STATE_INITIALIZING ? :initializing :
    st == LibZenohC.Z_SHM_PROVIDER_STATE_ERROR        ? :error        : :disabled

# Probe SHM capability and populate the session's cache. Unlike the public
# `obtain_shm_provider`, this never throws: a failed obtain or an unusable
# state is recorded in `s.shm_state[]` and leaves `s.shm[]` as `nothing` so
# `zref(::Session, T)` cleanly falls back to Julia memory.
#
# IMPORTANT: each *successful* `z_obtain_shm_provider` materializes a fresh
# provider whose POSIX `/dev/shm` segments are NOT reclaimed on drop/close
# (only by `cleanup_orphaned_shm_segments`). So obtain at most once per session:
# if a provider is already cached, this is a no-op. Repeated callers (the warm-up
# wait loop, `shm_ready`) thus obtain only while still warming up — when obtains
# *fail* (`:unavailable`) and allocate nothing — and stop the moment one succeeds
# and is cached. The provider is cached when zenoh reports it ready or still
# initializing (lazy mode); `disabled`/`error` are recorded but not cached.
function _bind_session_shm!(s::Session)
    s.shm[] === nothing || return s              # already obtained — never re-obtain (leaks segments)
    ref   = Ref{LibZenohC.z_owned_shared_shm_provider_t}()
    state = Ref{LibZenohC.z_shm_provider_state}(LibZenohC.Z_SHM_PROVIDER_STATE_DISABLED)
    rc = LibZenohC.z_obtain_shm_provider(_loan(s), ref, state)
    if rc != LibZenohC.Z_OK
        s.shm_state[] = :unavailable
        return s
    end
    finalizer(r -> _drop(_move(r)), ref)
    st = state[]
    s.shm_state[] = _shm_state_sym(st)
    if st == LibZenohC.Z_SHM_PROVIDER_STATE_READY ||
       st == LibZenohC.Z_SHM_PROVIDER_STATE_INITIALIZING
        s.shm[] = SharedShmProvider(ref, nothing)   # no back-ref → no finalizer cycle
    end
    return s
end

"""
    shm_state(s::Session) -> Symbol

The session's shared-memory capability as discovered at `open` (snapshot):

  - `:none`        — opened without `shm_clients`; SHM was never requested.
  - `:unavailable` — obtaining a provider failed (build/config has no SHM).
  - `:disabled`    — provider reports disabled.
  - `:initializing`— provider is warming up (lazy mode); allocations may not
                     succeed yet but `zref(s, T)` will start using SHM once ready.
  - `:ready`       — provider is usable now.
  - `:error`       — provider entered an error state.

`zref(s, T)` uses shared memory when this is `:ready` or `:initializing`, and
falls back to Julia memory otherwise.
"""
shm_state(s::Session) = s.shm_state[]

"""
    shm_capable(s::Session) -> Bool

True if the session has a cached SHM provider that `zref(s, T)` will allocate
from (state `:ready` or `:initializing`); false if `zref` falls back to Julia
memory.
"""
shm_capable(s::Session) = s.shm[] !== nothing

"""
    shm_ready(s::Session) -> Bool

Re-probe the session *now* and report whether its SHM provider is ready to
allocate. Unlike `shm_state` (a snapshot taken at `open`), this re-attempts the
provider obtain and *adopts* the provider into the session cache if it has since
become usable — so once this returns `true`, `shm_capable(s)` is also true and
`zref(s, T)` allocates from shared memory. Useful when SHM hadn't finished
warming up at `open` (a session reports `:unavailable`/`:initializing` until the
provider settles, typically within a second or two of connecting). Always
`false` for a session opened without `shm_clients`.
"""
function shm_ready(s::Session)
    s.shm_state[] === :none && return false      # SHM never requested at open
    _bind_session_shm!(s)                         # obtain + adopt (not a throwaway)
    return s.shm_state[] === :ready
end

# Block until the provider is ready or `timeout` seconds elapse. The warm-up
# window surfaces as `:unavailable`/`:initializing` (the obtain itself fails or
# the provider isn't settled yet), so we keep re-attempting `_bind_session_shm!`
# — which adopts the provider the moment it's usable — through both. Only
# `:disabled`/`:error` are truly terminal. Returns the final state symbol.
function _wait_for_shm_ready!(s::Session, timeout::Float64; poll::Float64=0.05)
    deadline = time() + timeout
    while true
        _bind_session_shm!(s)
        st = s.shm_state[]
        st === :ready && return st
        (st === :disabled || st === :error) && return st
        time() >= deadline && return st           # gave up: still :unavailable/:initializing
        sleep(poll)
    end
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
export shm_state, shm_capable, shm_ready
export data, as_shm, is_shm, cleanup_orphaned_shm_segments
