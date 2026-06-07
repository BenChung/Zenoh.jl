"""
    ShmAllocError <: Exception

Signals that a runtime shared-memory allocation could not be satisfied. The
`kind::Symbol` field carries the reason from zenoh's allocator:

  - `:need_defragment` — the segment is fragmented; [`defragment`](@ref) may
    free a contiguous run large enough to retry.
  - `:out_of_memory`   — the provider has no free space for the request.
  - `:other`           — any other allocator failure.

Thrown by [`alloc`](@ref). [`zref`](@ref)`(s::Session, T)` catches this and
falls back to Julia memory.
"""
struct ShmAllocError <: Exception
    kind::Symbol
end
"""
    ShmLayoutError <: Exception

Signals that a shared-memory allocation's size/alignment layout is invalid or
the provider cannot honor it. The `kind::Symbol` field is one of:

  - `:incorrect_layout_args`  — the requested size/alignment is not a valid
    layout.
  - `:provider_incompatible`  — the provider cannot serve the requested layout.

Thrown by [`alloc`](@ref).
"""
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

"""
    AbstractShmProvider

Supertype of the shared-memory provider wrappers, [`ShmProvider`](@ref) (a
standalone POSIX segment) and [`SharedShmProvider`](@ref) (a session-derived
provider). A provider is the source zero-copy SHM buffers are allocated from;
[`alloc`](@ref), [`available`](@ref), [`defragment`](@ref),
[`garbage_collect`](@ref), and [`zref`](@ref)`(p, T)` all dispatch on this type.
"""
abstract type AbstractShmProvider end

"""
    ShmProvider <: AbstractShmProvider
    ShmProvider(size::Integer)

A standalone POSIX shared-memory provider of fixed byte capacity, backed by a
`/dev/shm` segment created directly via `z_posix_shm_provider_new`. The owned
provider handle is released by a finalizer.

Use this to allocate SHM buffers without a session; for the provider tied to an
open session (and the transparent [`zref`](@ref)`(s::Session, T)` fast path),
see [`SharedShmProvider`](@ref) and [`obtain_shm_provider`](@ref).
"""
mutable struct ShmProvider <: AbstractShmProvider
    p::Base.RefValue{LibZenohC.z_owned_shm_provider_t}
end
function ShmProvider(size::Integer)
    ref = Ref{LibZenohC.z_owned_shm_provider_t}()
    _handle_result(LibZenohC.z_posix_shm_provider_new(ref, Csize_t(size)))
    finalizer(r -> _drop(_move(r)), ref)
    return ShmProvider(ref)
end

"""
    SharedShmProvider <: AbstractShmProvider

The shared-memory provider belonging to an open [`Session`](@ref), obtained from
its SHM subsystem via `z_obtain_shm_provider`. This is the provider cached in
`Session.shm` and used by the transparent [`zref`](@ref)`(s::Session, T)` fast
path; [`obtain_shm_provider`](@ref) returns one for explicit use.

When obtained through the public API it pins its `Session` alive (loaning the
provider reaches into session state); the session's own cached copy holds no
back-reference, since the session already outlives it.
"""
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

"""
    obtain_shm_provider(s::Session) -> SharedShmProvider

Obtain the [`SharedShmProvider`](@ref) for an open session, for explicit
allocation via [`alloc`](@ref) or inspection via [`available`](@ref). The
returned provider pins `s` alive for as long as it is held.

For the transparent fast path that allocates SHM when available and falls back
to Julia memory otherwise, prefer [`zref`](@ref)`(s::Session, T)`, which uses
the session's own cached provider.
"""
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
# Idempotent and concurrency-safe: the cached provider (`s.shm[]`) is the
# session's single provider, so binding more than once is wasteful. The fast path
# returns when already bound; the bind itself runs under `s.shm_lock` with a
# double-check, so racing first-binders perform exactly one obtain and readers
# never observe a torn write. Repeated callers (the warm-up wait loop,
# `shm_ready`) re-attempt only while still warming up — obtains fail cheaply
# (`:unavailable`) and allocate nothing — and stop the moment one succeeds and is
# cached (zenoh reports ready or initializing, lazy mode); `disabled`/`error` are
# recorded but not cached.
# (Whether a redundant obtain would leak `/dev/shm` segments or merely clone a
# refcount is the open §0 question in docs/design; the lock makes it moot here by
# ensuring a single obtain.)
function _bind_session_shm!(s::Session)
    s.shm[] === nothing || return s              # fast path: already bound, no lock
    lock(s.shm_lock) do
        s.shm[] === nothing || return            # double-check: another task won the race
        ref   = Ref{LibZenohC.z_owned_shared_shm_provider_t}()
        state = Ref{LibZenohC.z_shm_provider_state}(LibZenohC.Z_SHM_PROVIDER_STATE_DISABLED)
        rc = LibZenohC.z_obtain_shm_provider(_loan(s), ref, state)
        if rc != LibZenohC.Z_OK
            s.shm_state[] = :unavailable
            return
        end
        finalizer(r -> _drop(_move(r)), ref)
        st = state[]
        s.shm_state[] = _shm_state_sym(st)
        if st == LibZenohC.Z_SHM_PROVIDER_STATE_READY ||
           st == LibZenohC.Z_SHM_PROVIDER_STATE_INITIALIZING
            s.shm[] = SharedShmProvider(ref, nothing)   # no back-ref → no finalizer cycle
        end
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
    session_shm_provider(s::Session) -> Union{SharedShmProvider, Nothing}

The session's own cached SHM provider (bound at `open` when `shm_clients` was
supplied and SHM became usable), or `nothing` otherwise. A **pure read** — unlike
[`obtain_shm_provider`](@ref) it neither re-obtains nor pins the session, so a
caller reuses the session's single provider with no double-obtain; it is released
with the session.

Note the provider warms up lazily: just after `open` (without `wait_for_shm`) this
may still be `nothing` even though SHM will shortly become ready. Capturing the
result once is therefore only safe behind `open(...; wait_for_shm=true)` or a
[`shm_ready`](@ref)`(s)` gate — otherwise a capture taken too early pins the Julia
fallback for the session's life. For the transparent self-healing path that
re-checks on every call, use [`zref`](@ref)`(s::Session, T)` instead.
"""
session_shm_provider(s::Session) =
    (s.closed[] ? nothing : (p = s.shm[]; p === nothing ? nothing : p::SharedShmProvider))

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
    _bind_session_shm!(s)
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

"""
    available(p::AbstractShmProvider) -> Int

Bytes currently free for allocation from the provider. Wraps
`z_shm_provider_available`.
"""
available(p::AbstractShmProvider)       = GC.@preserve p Int(LibZenohC.z_shm_provider_available(_loan_provider(p)))
"""
    defragment(p::AbstractShmProvider) -> Int

Coalesce the provider's free space into larger contiguous runs and return the
resulting size. Useful to recover from a [`ShmAllocError`](@ref)`(:need_defragment)`
before retrying [`alloc`](@ref). Wraps `z_shm_provider_defragment`.
"""
defragment(p::AbstractShmProvider)      = GC.@preserve p Int(LibZenohC.z_shm_provider_defragment(_loan_provider(p)))
"""
    garbage_collect(p::AbstractShmProvider) -> Int

Reclaim free chunks no longer referenced anywhere in the SHM domain and return
the collected size. Wraps `z_shm_provider_garbage_collect`.
"""
garbage_collect(p::AbstractShmProvider) = GC.@preserve p Int(LibZenohC.z_shm_provider_garbage_collect(_loan_provider(p)))

"""
    ShmBufMut

An owned, writable shared-memory segment produced by [`alloc`](@ref), exposing
its bytes as a `Memory{UInt8}` ([`data`](@ref), `pointer`,
`length`, `copyto!`). Write the payload, then move it into a
sendable [`ZBytes`](@ref) (`ZBytes(buf)`, the zero-copy send path) or freeze it
into an immutable [`ShmBuf`](@ref) (`ShmBuf(buf)`). Wraps `z_owned_shm_mut_t`;
the handle is released by a finalizer, or consumed by the move.
"""
mutable struct ShmBufMut
    b::Base.RefValue{LibZenohC.z_owned_shm_mut_t}
    mem::Memory{UInt8}
end

"""
    ShmBuf{R}

An immutable shared-memory buffer exposing its bytes as a `Memory{UInt8}`
([`data`](@ref), `pointer`, `length`), in one of two forms
selected by the backing `R`:

  - owned (`Base.RefValue{z_owned_shm_t}`) — frozen from a [`ShmBufMut`](@ref)
    via `ShmBuf(buf)`, dropped by a finalizer.
  - borrowed (`Ptr{z_loaned_shm_t}`) — a zero-copy view over a received SHM
    payload returned by [`as_shm`](@ref), pinning its parent [`ZBytes`](@ref)
    so the loan stays valid.

Send an owned buffer by moving it into a [`ZBytes`](@ref) (`ZBytes(buf)`).
"""
mutable struct ShmBuf{R <: Union{Base.RefValue{LibZenohC.z_owned_shm_t},
                                  Ptr{LibZenohC.z_loaned_shm_t}}}
    b::R
    mem::Memory{UInt8}
    parent::Any
end

# Recycle token for a borrowed ShmBuf view: forwarded from the parent ZBytes (and
# thence the sample/holder). `nothing` for the owned freeze form (parent=nothing),
# so the gated accessors below are a no-op on the send side.
@inline _token(b::ShmBuf) = b.parent isa ZBytes ? _token(b.parent::ZBytes) : nothing

Base.length(b::ShmBufMut) = length(b.mem)
Base.length(b::ShmBuf)    = (_check_token(_token(b)); length(b.mem))
Base.pointer(b::ShmBufMut) = pointer(b.mem)
Base.pointer(b::ShmBuf)    = (_check_token(_token(b)); pointer(b.mem))
"""
    data(b::ShmBufMut) -> Memory{UInt8}
    data(b::ShmBuf)    -> Memory{UInt8}

The buffer's bytes as a `Memory{UInt8}` backed directly by the shared-memory
segment (zero-copy). Mutating the result of `data(::ShmBufMut)` writes the
segment in place.
"""
data(b::ShmBufMut) = b.mem
data(b::ShmBuf)    = (_check_token(_token(b)); b.mem)
Base.copyto!(b::ShmBufMut, src::AbstractVector{UInt8}) =
    (length(src) <= length(b.mem) || throw(BoundsError(b.mem, length(src)));
     unsafe_copyto!(pointer(b.mem), pointer(src), length(src)); b)

"""
    close(buf::ShmBufMut)

Release an allocated-but-unsent [`ShmBufMut`](@ref) promptly on the calling task
rather than waiting for the GC finalizer. The off-thread finalizer drop is itself
safe (the SHM segment refcount is atomic — see the ownership note in
`types/bytes.jl`), but error/cleanup paths that abandon a buffer should still
`close` it to free the segment deterministically instead of at an arbitrary later
GC. Idempotent, and a no-op once the buffer was moved into a
[`ZBytes`](@ref)/[`ShmBuf`](@ref): the check guard skips a moved-from or
already-closed handle.
"""
function Base.close(buf::ShmBufMut)
    GC.@preserve buf begin
        bp = Base.unsafe_convert(Ptr{LibZenohC.z_owned_shm_mut_t}, buf.b)
        if LibZenohC.z_internal_shm_mut_check(bp)
            LibZenohC.z_shm_mut_drop(_move(buf.b))   # real symbol; _move is the pointer-cast
            LibZenohC.z_internal_shm_mut_null(bp)    # gravestone so the finalizer no-ops
        end
    end
    return nothing
end

"""
    close(b::ShmBuf)

Release an owned (frozen) [`ShmBuf`](@ref) on the calling task — the on-task twin
of [`close`](@ref)`(::ShmBufMut)` for a buffer frozen via `ShmBuf(buf)` but not
sent. The off-thread finalizer drop is itself safe; this just frees the segment
deterministically. Idempotent; a no-op for a borrowed view (from [`as_shm`](@ref),
which owns nothing) and once the buffer was moved into a [`ZBytes`](@ref).
"""
function Base.close(b::ShmBuf{Base.RefValue{LibZenohC.z_owned_shm_t}})
    GC.@preserve b begin
        bp = Base.unsafe_convert(Ptr{LibZenohC.z_owned_shm_t}, b.b)
        if LibZenohC.z_internal_shm_check(bp)
            LibZenohC.z_shm_drop(_move(b.b))
            LibZenohC.z_internal_shm_null(bp)
        end
    end
    return nothing
end
Base.close(::ShmBuf{Ptr{LibZenohC.z_loaned_shm_t}}) = nothing

"""
    close(p::ShmProvider)
    close(p::SharedShmProvider)

Release a provider's handle on the calling task instead of waiting for the GC
finalizer. Idempotent. This frees the Julia-side handle, not the provider's
`/dev/shm` segments (those are reference-counted across the domain; a crashed
process's leftovers need [`cleanup_orphaned_shm_segments`](@ref)). Don't close a
[`SharedShmProvider`](@ref) still cached in its session — [`close`](@ref)`(::Session)`
releases that one.
"""
function Base.close(p::ShmProvider)
    GC.@preserve p begin
        pp = Base.unsafe_convert(Ptr{LibZenohC.z_owned_shm_provider_t}, p.p)
        if LibZenohC.z_internal_shm_provider_check(pp)
            LibZenohC.z_shm_provider_drop(_move(p.p))
            LibZenohC.z_internal_shm_provider_null(pp)
        end
    end
    return nothing
end
function Base.close(p::SharedShmProvider)
    GC.@preserve p begin
        pp = Base.unsafe_convert(Ptr{LibZenohC.z_owned_shared_shm_provider_t}, p.p)
        if LibZenohC.z_internal_shared_shm_provider_check(pp)
            LibZenohC.z_shared_shm_provider_drop(_move(p.p))
            LibZenohC.z_internal_shared_shm_provider_null(pp)
        end
    end
    return nothing
end

function _alignment(align::Integer)
    align > 0 || throw(ArgumentError("alignment must be > 0"))
    p = trailing_zeros(align)
    (1 << p) == align || throw(ArgumentError("alignment must be a power of 2"))
    return LibZenohC.z_alloc_alignment_t(UInt8(p))
end

# Run the layout-alloc ccall into `result`. `blocking` selects the
# GC+defrag+blocking policy (waits for room); otherwise try-once. `_alignment`
# throws ArgumentError for a non-power-of-two before any ccall.
function _native_alloc!(result, lp, n::Integer, align::Union{Nothing,Integer}, blocking::Bool)
    if blocking
        # `gc_safe`: the blocking allocator parks the calling thread waiting for
        # room; marking the ccall GC-safe lets a stop-the-world GC on another
        # thread treat it as parked instead of deadlocking in
        # `jl_gc_wait_for_the_world` (see core/gc_safe_threadcall.jl for the same
        # hazard on the recv path). Sound because the call writes only into the C
        # `result` struct — it touches no Julia heap during the gc-safe window.
        if align === nothing
            @ccall gc_safe=true LibZenohC.libzenohc.z_shm_provider_alloc_gc_defrag_blocking(
                result::Ptr{LibZenohC.z_buf_layout_alloc_result_t},
                lp::Ptr{LibZenohC.z_loaned_shm_provider_t}, Csize_t(n)::Csize_t)::Cvoid
        else
            @ccall gc_safe=true LibZenohC.libzenohc.z_shm_provider_alloc_gc_defrag_blocking_aligned(
                result::Ptr{LibZenohC.z_buf_layout_alloc_result_t},
                lp::Ptr{LibZenohC.z_loaned_shm_provider_t}, Csize_t(n)::Csize_t,
                _alignment(align)::LibZenohC.z_alloc_alignment_t)::Cvoid
        end
    else
        if align === nothing
            LibZenohC.z_shm_provider_alloc(result, lp, Csize_t(n))
        else
            LibZenohC.z_shm_provider_alloc_aligned(
                result, lp, Csize_t(n), _alignment(align))
        end
    end
    return result
end

# Move the allocated z_owned_shm_mut_t out of an OK result struct and wrap it as
# a finalizer-owned ShmBufMut. Shared by `alloc`/`alloc_blocking`/`try_alloc`.
function _take_shmbufmut(result::Ref{LibZenohC.z_buf_layout_alloc_result_t})
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
end

function _alloc(p::AbstractShmProvider, n::Integer, align::Union{Nothing,Integer}, blocking::Bool)
    result = Ref{LibZenohC.z_buf_layout_alloc_result_t}()
    lp = _loan_provider(p)
    GC.@preserve p _native_alloc!(result, lp, n, align, blocking)
    status = result[].status
    if status == LibZenohC.ZC_BUF_LAYOUT_ALLOC_STATUS_OK
        return _take_shmbufmut(result)
    elseif status == LibZenohC.ZC_BUF_LAYOUT_ALLOC_STATUS_ALLOC_ERROR
        throw(ShmAllocError(_alloc_error_sym(result[].alloc_error)))
    else
        throw(ShmLayoutError(_layout_error_sym(result[].layout_error)))
    end
end

"""
    alloc(p::AbstractShmProvider, n::Integer; align=nothing) -> ShmBufMut

Allocate an `n`-byte writable [`ShmBufMut`](@ref) from the provider, trying once
and returning immediately. `align`, when given, must be a power of two and
constrains the segment's start to that boundary.

Throws [`ShmAllocError`](@ref) when the segment cannot satisfy the request (full
or fragmented — the *expected* steady state under load; see [`try_alloc`](@ref)
for a non-throwing twin) and [`ShmLayoutError`](@ref) when the size/alignment
layout is invalid. For the GC + defragment + blocking policy, see
[`alloc_blocking`](@ref).
"""
alloc(p::AbstractShmProvider, n::Integer; align::Union{Nothing,Integer}=nothing) =
    _alloc(p, n, align, false)

"""
    alloc_blocking(p::AbstractShmProvider, n::Integer; align=nothing) -> ShmBufMut

Like [`alloc`](@ref) but selects the GC + defragment + **blocking** allocation
policy: it reclaims and coalesces free space and **waits** for room rather than
failing fast.

!!! warning
    This **blocks the calling task** until room frees up — keep it off a
    publish/serialize hot path, where a stall would back up your own pipeline.
    The blocking ccall is marked `gc_safe`, so it does **not** stall a
    stop-the-world GC on another thread (unlike a plain blocking ccall, which
    would — see `core/gc_safe_threadcall.jl`). The split from [`alloc`](@ref) is
    deliberate: the hot path cannot reach the blocking policy by flipping a flag.
"""
alloc_blocking(p::AbstractShmProvider, n::Integer; align::Union{Nothing,Integer}=nothing) =
    _alloc(p, n, align, true)

"""
    try_alloc(p::AbstractShmProvider, n::Integer; align=nothing) -> Union{ShmBufMut, Nothing}

Non-throwing, try-once twin of [`alloc`](@ref): returns the [`ShmBufMut`](@ref) on
success and `nothing` when the segment is full or fragmented (`ShmAllocError`'s
conditions — the expected steady state under load, so no exception is constructed
on that path). A genuine misconfiguration still throws: an invalid size/alignment
layout raises [`ShmLayoutError`](@ref), and a non-power-of-two `align` raises
`ArgumentError`. Use this on degrade-aware paths to avoid try/catch over a
non-exceptional outcome.
"""
function try_alloc(p::AbstractShmProvider, n::Integer; align::Union{Nothing,Integer}=nothing)
    result = Ref{LibZenohC.z_buf_layout_alloc_result_t}()
    lp = _loan_provider(p)
    GC.@preserve p _native_alloc!(result, lp, n, align, false)   # try-once, non-blocking
    status = result[].status
    status == LibZenohC.ZC_BUF_LAYOUT_ALLOC_STATUS_OK && return _take_shmbufmut(result)
    status == LibZenohC.ZC_BUF_LAYOUT_ALLOC_STATUS_ALLOC_ERROR && return nothing  # full/fragmented → transient
    throw(ShmLayoutError(_layout_error_sym(result[].layout_error)))               # genuine layout misconfig
end

# Freeze a mutable buffer into an immutable one. Consumes `buf`.
function ShmBuf(buf::ShmBufMut)
    out = Ref{LibZenohC.z_owned_shm_t}()
    # `_move(buf.b)` hands C a pointer aliasing buf's storage; preserve buf so its
    # finalizer can't run mid-consume (matches the heap path's GC.@preserve).
    GC.@preserve buf LibZenohC.z_shm_from_mut(out, _move(buf.b))
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
"""
    ZBytes(buf::ShmBufMut, n::Integer = length(data(buf)))

Move an SHM buffer into a sendable owned [`ZBytes`](@ref), consuming `buf`. `n`
bounds how many bytes are sent and must be ≤ the granted length. Only `n` equal to
the full granted length is supported: the default POSIX provider grants exactly
the requested size, and the bound libzenohc exposes no length-bounded SHM move, so
a shorter `n` errors rather than silently over-sending trailing segment bytes.
"""
function ZBytes(buf::ShmBufMut, n::Integer)
    granted = length(data(buf))
    n <= granted || throw(BoundsError(data(buf), n))
    n == granted || throw(ArgumentError(
        "ZBytes(buf, n) with n < granted ($n < $granted) is unsupported: the bound \
         libzenohc has no length-bounded SHM move. Allocate exactly n bytes instead."))
    out_ref = Ref{LibZenohC.z_owned_bytes_t}()
    # See ShmBuf(buf): preserve buf across the move-consume so its finalizer
    # can't read the gravestoned storage concurrently.
    GC.@preserve buf _handle_result(LibZenohC.z_bytes_from_shm_mut(out_ref, _move(buf.b)))
    return ZBytes(out_ref, Val(:owned))
end
ZBytes(buf::ShmBufMut) = ZBytes(buf, length(data(buf)))

"""
    shm_serialize(fill!, p::AbstractShmProvider, n::Integer; align=nothing) -> ZBytes

Allocate an `n`-byte SHM buffer from `p`, call `fill!(mem::Memory{UInt8})` to write
the payload straight into the segment, then move it into a sendable owned
[`ZBytes`](@ref) — alloc, fill, bounded move, and cleanup all inside the library.
If `fill!` throws, the buffer is released on the calling task (`close`) before
rethrowing, so a half-filled segment never leaks. Throws the same
[`ShmAllocError`](@ref)/[`ShmLayoutError`](@ref) as [`alloc`](@ref) when the
segment can't be obtained; catch those to fall back to heap memory.
"""
function shm_serialize(fill!, p::AbstractShmProvider, n::Integer; align::Union{Nothing,Integer}=nothing)
    buf = alloc(p, n; align=align)
    try
        fill!(data(buf))
    catch
        close(buf)            # drop the half-filled segment on THIS task
        rethrow()
    end
    return ZBytes(buf, n)     # bounded move; consumes buf
end

function ZBytes(buf::ShmBuf{Base.RefValue{LibZenohC.z_owned_shm_t}})
    out_ref = Ref{LibZenohC.z_owned_bytes_t}()
    _handle_result(LibZenohC.z_bytes_from_shm(out_ref, _move(buf.b)))
    return ZBytes(out_ref, Val(:owned))
end

# View a received ZBytes as an SHM buffer. Returns nothing if the bytes are
# not backed by SHM. The returned ShmBuf pins `z` so the loan stays valid.
"""
    as_shm(z::ZBytes) -> Union{ShmBuf,Nothing}

View a received payload as a borrowed [`ShmBuf`](@ref) for zero-copy reads,
pinning `z` so the loan stays valid. Returns `nothing` when the payload is not
backed by a shared-memory segment (e.g. it arrived over the network). Use
[`is_shm`](@ref) to test without constructing a view.
"""
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

"""
    is_shm(z::ZBytes) -> Bool

True if the received payload is backed by a shared-memory segment (and so can be
read zero-copy via [`as_shm`](@ref)); false if it arrived as a plain byte copy.
"""
function is_shm(z::ZBytes)
    out_ptr = Ref{Ptr{LibZenohC.z_loaned_shm_t}}(C_NULL)
    return LibZenohC.z_bytes_as_loaned_shm(_loaned_bytes(z), out_ptr) == LibZenohC.Z_OK
end

"""
    cleanup_orphaned_shm_segments()

Reclaim POSIX `/dev/shm` segments left behind by processes that exited without
releasing them (Linux only). SHM buffers are reference-counted and auto-reclaimed
across the domain, but a crashed process's backing segments need this sweep —
they are not freed on provider drop or session close. Wraps the unstable
zenoh-c-specific `zc_cleanup_orphaned_shm_segments`.
"""
cleanup_orphaned_shm_segments() = LibZenohC.zc_cleanup_orphaned_shm_segments()

# Specializations for `put(...; shm=provider, ...)`. The Nothing fallback is
# defined in Zenoh.jl so `put` works without shm.jl needing to be loaded yet.
# An already-built ZBytes is sent as-is — there's nothing to copy into SHM, so
# the provider is ignored (the bytes are moved by the caller, as usual). This is
# the provider-named twin of the `::Nothing` passthrough in messaging/publisher.jl;
# both rely on the `ZBytes(::ZBytes)` identity (types/bytes.jl) to forward an
# already-built owned (e.g. SHM-backed) payload zero-copy.
_shm_zbytes(::AbstractShmProvider, z::ZBytes) = z
# Each variant allocs then copies into the segment. If the copy throws (a lazy
# source's `pointer` faults, an unexpected length, an interrupt), `close` the
# buffer on THIS task before rethrowing — abandoning it would leave the only
# release path the GC finalizer (mirrors `shm_serialize`'s guard).
function _shm_zbytes(provider::AbstractShmProvider, data::AbstractVector{UInt8})
    buf = alloc(provider, length(data))
    try
        copyto!(buf, data)
    catch
        close(buf); rethrow()
    end
    return ZBytes(buf)
end
function _shm_zbytes(provider::AbstractShmProvider, s::AbstractString)
    bytes = codeunits(s)
    buf = alloc(provider, length(bytes))
    try
        GC.@preserve s unsafe_copyto!(pointer(buf.mem), Base.unsafe_convert(Ptr{UInt8}, s), length(bytes))
    catch
        close(buf); rethrow()
    end
    return ZBytes(buf)
end
function _shm_zbytes(provider::AbstractShmProvider, r::Base.RefValue{T}) where T
    buf = alloc(provider, sizeof(T))
    try
        GC.@preserve r begin
            src = Base.unsafe_convert(Ptr{UInt8}, Base.unsafe_convert(Ptr{T}, r))
            unsafe_copyto!(pointer(buf.mem), src, sizeof(T))
        end
    catch
        close(buf); rethrow()
    end
    return ZBytes(buf)
end
function _shm_zbytes(provider::AbstractShmProvider, v::AbstractVector{T}) where T
    nbytes = length(v) * sizeof(T)
    buf = alloc(provider, nbytes)
    try
        GC.@preserve v unsafe_copyto!(pointer(buf.mem), Base.unsafe_convert(Ptr{UInt8}, pointer(v)), nbytes)
    catch
        close(buf); rethrow()
    end
    return ZBytes(buf)
end

export AbstractShmProvider, ShmProvider, SharedShmProvider
export ShmBuf, ShmBufMut
export ShmAllocError, ShmLayoutError
export obtain_shm_provider, alloc, alloc_blocking, try_alloc, shm_serialize
export available, defragment, garbage_collect
export shm_state, shm_capable, shm_ready, session_shm_provider
export data, as_shm, is_shm, cleanup_orphaned_shm_segments
