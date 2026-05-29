# ZRef{T} — a typed, transport-agnostic, minimum-copy handle over a payload
# buffer. The *only* axis of variation is who owns the backing memory; the
# authoring API (`r[] = x` / `r[]` / `pointer(r)`), the send path (`put`), and
# the receive constructor are identical across SHM and non-SHM.
#
# Backings:
#   send    · Base.RefValue{T}  — plain Julia heap, borrowed by zenoh on `put`
#                                  (z_bytes_from_buf, pinned until the deleter
#                                  fires); the default and the SHM fallback.
#           · ShmBufMut         — a shared-memory segment buffer, *moved* into
#                                  the bytes on `put` (z_bytes_from_shm_mut).
#   receive · ShmBuf            — zero-copy view into the sender's SHM segment.
#           · _ZRefView         — zero-copy view into a contiguous network slice.
#           · Base.RefValue{T}  — one copy, when the payload is fragmented or
#                                  misaligned for T.
#
# `T` must be `isbitstype` — anything with Julia references would serialize live
# heap pointers. Zero-copy in/out requires the buffer to be aligned to T; SHM is
# the only transport that carries the sender's alignment through to the receiver,
# so only it is guaranteed in-place. The network paths fall back to a copy when
# alignment or contiguity don't hold.

# Pins the contiguous-view borrow: `z` keeps the Sample (and thus the buffer)
# alive; `view` holds the z_view_slice_t whose data pointer we borrow.
struct _ZRefView
    z::ZBytes
    view::Base.RefValue{LibZenohC.z_view_slice_t}
end

mutable struct ZRef{T, B}
    backing::B
    ptr::Ptr{T}
    consumed::Bool       # send-side: true once `put` moved/borrowed the backing
end

@inline _check_isbits(::Type{T}) where {T} =
    isbitstype(T) || throw(ArgumentError("ZRef requires an isbits type, got $T"))

@inline _aligned(p::Ptr, ::Type{T}) where {T} =
    reinterpret(UInt, p) % UInt(Base.datatype_alignment(T)) == 0

# --- send-side constructors ------------------------------------------

"""
    zref(T) -> ZRef{T}

A writable, Julia-memory-backed handle for a value of isbits type `T`. Write it
with `r[] = x` (or field-wise through `pointer(r)`), then `put` it. zenoh borrows
the buffer on send — no copy into a zenoh buffer.
"""
function zref(::Type{T}) where {T}
    _check_isbits(T)
    box = Ref{T}()
    return ZRef{T, typeof(box)}(box, Base.unsafe_convert(Ptr{T}, box), false)
end

"""
    zref(provider::AbstractShmProvider, T) -> ZRef{T}

Allocate a shared-memory buffer for `T` from `provider` and return a handle that
writes straight into the segment. Requests alignment matching `T` so the
receiver can view it in place; if the provider can't honor that alignment
(`ShmLayoutError`) it retries unaligned, and the receiver falls back to a copy.
"""
function zref(p::AbstractShmProvider, ::Type{T}) where {T}
    _check_isbits(T)
    buf = try
        alloc(p, sizeof(T); align = Base.datatype_alignment(T))
    catch e
        e isa ShmLayoutError || rethrow()
        alloc(p, sizeof(T))                       # provider can't align → unaligned
    end
    return ZRef{T, ShmBufMut}(buf, Ptr{T}(pointer(buf)), false)
end

"""
    zref(s::Session, T) -> ZRef{T}

The transparent fast path: allocate from the session's SHM provider when one is
available (the session was opened with `shm_clients` and SHM is enabled),
otherwise fall back to Julia memory. A full segment (`ShmAllocError`) also
degrades to Julia memory. Either way you get the same `ZRef{T}` and never name a
provider.

If the provider hasn't been obtained yet (it warms up shortly after the session
connects, and `open` didn't `wait_for_shm`), this lazily attempts the obtain so
the fast path self-heals once SHM becomes ready — without you having to call
`shm_ready`. The attempt is skipped for terminal states (`:none`/`:disabled`/
`:error`); while still warming up the obtain fails cheaply and allocates nothing.

On the `ShmAllocError` degrade path a `@debug` is emitted and the session's
`on_shm_alloc_error` callback (if registered at `open`) is invoked with the
error — it may `throw` to escalate instead of falling back.
"""
function zref(s::Session, ::Type{T}) where {T}
    _check_isbits(T)
    prov = s.shm[]
    if prov === nothing && s.shm_state[] ∉ (:none, :disabled, :error)
        _bind_session_shm!(s)        # leak-safe: no-op if cached; cheap failed obtain while warming up
        prov = s.shm[]
    end
    if prov !== nothing
        try
            return zref(prov::AbstractShmProvider, T)
        catch e
            e isa ShmAllocError || rethrow()      # out-of-memory / needs-defrag → degrade
            @debug "SHM allocation failed; falling back to Julia memory" exception=e type=T bytes=sizeof(T)
            handler = s.shm_alloc_handler[]
            handler === nothing || handler(e)     # user callback may rethrow to escalate
        end
    end
    return zref(T)
end

# --- receive-side constructor ----------------------------------------

"""
    zref(sample::Sample, T) -> ZRef{T}

Reconstruct a `T` from a received sample, transport-agnostically. Zero-copy when
the payload is SHM-backed (tier 1) or a single contiguous, T-aligned network
slice (tier 2); otherwise the bytes are copied once into an aligned box (tier 3).
Read the value with `r[]`. A borrowed `ZRef` is only valid while reachable (it
pins the sample) — read or copy out before the callback returns.
"""
function zref(sample::Sample, ::Type{T}) where {T}
    _check_isbits(T)
    zb = payload(sample)
    n  = sizeof(T)

    # Tier 1 — SHM: contiguous and sender-aligned.
    shm = as_shm(zb)
    if shm !== nothing && length(shm) >= n && _aligned(pointer(shm), T)
        return ZRef{T, typeof(shm)}(shm, Ptr{T}(pointer(shm)), false)
    end

    # Tier 2 — non-SHM, single contiguous slice, if it happens to be aligned.
    view = Ref{LibZenohC.z_view_slice_t}()
    if LibZenohC.z_bytes_get_contiguous_view(_loaned_bytes(zb), view) == LibZenohC.Z_OK
        sl = LibZenohC.z_view_slice_loan(view)
        p  = LibZenohC.z_slice_data(sl)
        if LibZenohC.z_slice_len(sl) >= n && _aligned(p, T)
            backing = _ZRefView(zb, view)
            return ZRef{T, _ZRefView}(backing, Ptr{T}(p), false)
        end
    end

    # Tier 3 — fragmented or misaligned: copy once into an aligned box.
    length(zb) >= n ||
        throw(ArgumentError("payload ($(length(zb)) bytes) smaller than $T ($n bytes)"))
    box = Ref{T}()
    GC.@preserve box begin
        dst = Base.unsafe_convert(Ptr{UInt8}, Base.unsafe_convert(Ptr{T}, box))
        rdr = open(zb, Val(:read))
        Base.unsafe_read(rdr, dst, UInt(n))
    end
    return ZRef{T, typeof(box)}(box, Base.unsafe_convert(Ptr{T}, box), false)
end

# --- payload as Memory{T} (serialization buffers) --------------------

"""
    as_memory(z::ZBytes, T=UInt8) -> Memory{T}

Copy the payload into a freshly-allocated, owned `Memory{T}` — safe to keep past
the originating sample/callback, and ready to hand to a (de)serializer. The byte
length must be a multiple of `sizeof(T)`. For zero-copy access scoped to a block,
use [`with_memory`](@ref). To go the other way (publish a `Memory`), `ZBytes(m)`.
"""
function as_memory(z::ZBytes, ::Type{T}=UInt8) where {T}
    isbitstype(T) || throw(ArgumentError("as_memory requires an isbits type, got $T"))
    nb = Int(length(z))
    nb % sizeof(T) == 0 ||
        throw(ArgumentError("payload ($nb bytes) is not a multiple of sizeof($T)=$(sizeof(T))"))
    mem = Memory{T}(undef, nb ÷ sizeof(T))
    nb == 0 && return mem
    GC.@preserve mem begin
        rdr = open(z, Val(:read))
        Base.unsafe_read(rdr, Ptr{UInt8}(pointer(mem)), UInt(nb))
    end
    return mem
end

"""
    with_memory(f, z::ZBytes, T=UInt8)

Call `f(mem::Memory{T})` with a view of the payload — zero-copy when it is
SHM-backed or a single contiguous, `T`-aligned network slice, otherwise over a
one-time copy. The view borrows from `z` and is valid **only for the duration of
`f`**: do not retain `mem` (or pointers into it) afterwards — copy out (e.g. with
[`as_memory`](@ref)) if you need it to persist. Returns `f`'s result.
"""
function with_memory(f, z::ZBytes, ::Type{T}=UInt8) where {T}
    isbitstype(T) || throw(ArgumentError("with_memory requires an isbits type, got $T"))
    nb = Int(length(z))
    nb % sizeof(T) == 0 ||
        throw(ArgumentError("payload ($nb bytes) is not a multiple of sizeof($T)=$(sizeof(T))"))
    n = nb ÷ sizeof(T)

    # Zero-copy tier 1 — SHM segment.
    shm = as_shm(z)
    if shm !== nothing && length(shm) >= nb && _aligned(pointer(shm), T)
        return GC.@preserve shm f(unsafe_wrap(Memory{T}, Ptr{T}(pointer(shm)), n))
    end

    # Zero-copy tier 2 — single contiguous, aligned network slice.
    view = Ref{LibZenohC.z_view_slice_t}()
    if LibZenohC.z_bytes_get_contiguous_view(_loaned_bytes(z), view) == LibZenohC.Z_OK
        sl = LibZenohC.z_view_slice_loan(view)
        p  = LibZenohC.z_slice_data(sl)
        if LibZenohC.z_slice_len(sl) >= nb && _aligned(p, T)
            return GC.@preserve z view f(unsafe_wrap(Memory{T}, Ptr{T}(p), n))
        end
    end

    # Tier 3 — fragmented or misaligned: one copy.
    return f(as_memory(z, T))
end

# --- accessors -------------------------------------------------------

@inline function _check_live(r::ZRef)
    r.consumed && throw(ArgumentError("ZRef has been consumed by put; its buffer is no longer valid"))
end

@inline function Base.getindex(r::ZRef{T}) where {T}
    _check_live(r)
    return GC.@preserve r unsafe_load(r.ptr)
end
@inline function Base.setindex!(r::ZRef{T}, x) where {T}
    _check_live(r)
    GC.@preserve r unsafe_store!(r.ptr, convert(T, x))
    return x
end
function Base.pointer(r::ZRef)
    _check_live(r)
    return r.ptr
end

"""
    isborrowed(r::ZRef) -> Bool

True if `r` is a zero-copy view into the underlying payload (SHM or contiguous
network slice); false if it owns a materialized copy. Useful for asserting the
fast path was taken.
"""
isborrowed(::ZRef{T, B}) where {T, B <: ShmBuf} = true
isborrowed(::ZRef{T, _ZRefView}) where {T}      = true
isborrowed(::ZRef)                               = false

# --- send path -------------------------------------------------------

# Borrow (Julia box) vs move (SHM buffer) — both produce an owned ZBytes.
_zref_bytes(b::Base.RefValue) = ZBytes(b)        # z_bytes_from_buf, pins the box
_zref_bytes(b::ShmBufMut)     = ZBytes(b)        # z_bytes_from_shm_mut, moves handle

function _zref_to_bytes(r::ZRef)
    _check_live(r)
    bytes = _zref_bytes(r.backing)
    r.consumed = true
    return bytes
end

function put(p::Publisher, r::ZRef; kwargs...)
    bytes = _zref_to_bytes(r)
    opts, enc_ref, attach_ref, ts = _make_put_opts(LibZenohC.z_publisher_put_options_t; kwargs...)
    GC.@preserve enc_ref attach_ref ts begin
        _handle_result(LibZenohC.z_publisher_put(_loan(p.pub), _move(bytes), opts))
    end
end

function put(s::Session, k::Keyexpr, r::ZRef;
        congestion_control::Union{Nothing, CongestionControl} = nothing,
        priority::Union{Nothing, Priority}                    = nothing,
        express::Union{Nothing, Bool}                         = nothing,
        allowed_destination::Union{Nothing, Locality}         = nothing,
        kwargs...)
    bytes = _zref_to_bytes(r)
    opts, enc_ref, attach_ref, ts = _make_put_opts(LibZenohC.z_put_options_t; kwargs...)
    optsP = Base.unsafe_convert(Ptr{LibZenohC.z_put_options_t}, opts)
    isnothing(congestion_control)  || (optsP.congestion_control  = _raw(congestion_control))
    isnothing(priority)            || (optsP.priority            = _raw(priority))
    isnothing(express)             || (optsP.is_express          = express)
    isnothing(allowed_destination) || (optsP.allowed_destination = _raw(allowed_destination))
    GC.@preserve enc_ref attach_ref ts begin
        _handle_result(LibZenohC.z_put(_loan(s), _loan(k), _move(bytes), opts))
    end
end

export ZRef, zref, isborrowed, as_memory, with_memory
