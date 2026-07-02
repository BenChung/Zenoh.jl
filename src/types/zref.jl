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

"""
    ZRef{T, B}

A typed, transport-agnostic, minimum-copy handle over a payload buffer for an
isbits type `T`. The authoring API (`r[] = x`, `r[]`, `pointer(r)`), the send
path ([`put`](@ref)), and the receive constructor are identical whether the
bytes live in Julia heap, a shared-memory segment, or a network view; the backing
`B` is the only axis of variation.

Construct one with [`zref`](@ref): a writable handle backed by Julia memory or an
SHM segment on the send side, or a reconstruction of a received [`Sample`](@ref)
on the receive side. [`isborrowed`](@ref) reports whether the handle is a
zero-copy view or owns a materialized copy.

A send-side `ZRef` is single-use: `put` borrows or moves its backing and marks it
consumed, after which any access throws. A receive-side borrowed `ZRef` is valid
only while reachable (it pins the sample) — read or copy out before the callback
returns.
"""
mutable struct ZRef{T, B}
    backing::B
    ptr::Ptr{T}
    consumed::Bool       # send-side: true once `put` moved/borrowed the backing
    # Recycle token for a borrowed receive-side ZRef (tier-1 SHM / tier-2 slice over
    # an in-place-reused source); `nothing` for send-side and owned-copy (tier-3)
    # handles. Checked in `_check_live` so a read after the source recycled throws
    # `BorrowError` instead of reading freed memory.
    tok::Union{Nothing,Tuple{_RecycleEpoch,UInt64}}
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
    return ZRef{T, typeof(box)}(box, Base.unsafe_convert(Ptr{T}, box), false, nothing)
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
    return ZRef{T, ShmBufMut}(buf, Ptr{T}(pointer(buf)), false, nothing)
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
    s.closed[] && throw(ArgumentError("session is closed"))   # don't alloc from a closed session
    prov = s.shm[]
    if prov === nothing && s.shm_state[] ∉ (:none, :disabled, :error)
        _bind_session_shm!(s)        # leak-safe: no-op if cached; cheap failed obtain while warming up
        prov = s.shm[]
    end
    if prov !== nothing
        try
            return zref(prov::AbstractShmProvider, T)
        catch e
            # Both operational SHM errors degrade to Julia memory: a full/fragmented
            # segment (ShmAllocError), or a layout the provider can't honor even
            # unaligned (ShmLayoutError, which `zref(p,T)`'s unaligned retry lets
            # escape). Anything else is a genuine bug — rethrow.
            if e isa ShmAllocError
                @debug "SHM allocation failed; falling back to Julia memory" exception=e type=T bytes=sizeof(T)
                handler = s.shm_alloc_handler[]
                handler === nothing || handler(e)     # user callback may rethrow to escalate
            elseif e isa ShmLayoutError
                @debug "SHM provider layout-incompatible; falling back to Julia memory" exception=e type=T bytes=sizeof(T)
            else
                rethrow()
            end
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
        return ZRef{T, typeof(shm)}(shm, Ptr{T}(pointer(shm)), false, _token(zb))
    end

    # Tier 2 — non-SHM, single contiguous slice, if it happens to be aligned.
    view = Ref{LibZenohC.z_view_slice_t}()
    if LibZenohC.z_bytes_get_contiguous_view(_loaned_bytes(zb), view) == LibZenohC.Z_OK
        sl = LibZenohC.z_view_slice_loan(view)
        p  = LibZenohC.z_slice_data(sl)
        if LibZenohC.z_slice_len(sl) >= n && _aligned(p, T)
            backing = _ZRefView(zb, view)
            return ZRef{T, _ZRefView}(backing, Ptr{T}(p), false, _token(zb))
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
    return ZRef{T, typeof(box)}(box, Base.unsafe_convert(Ptr{T}, box), false, nothing)
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

# --- Borrowed: a scope-validated view of the payload ----------------
#
# A `Borrowed{T}` is a checked, value-first view of a payload reinterpreted as
# `T` — usually a single struct, occasionally a buffer of `T`. It behaves both
# like the struct (`b.field` reads/writes a field, forwarded through pointer
# arithmetic) and like an array view (`b[]`, `b[i]`, iterate, `length`,
# `collect`). While valid it pins its `owner` (the Sample/ZBytes, or an owned
# copy) so the bytes stay live; on `close` it drops that pin and flips `valid`,
# after which *every* access throws a `BorrowError` rather than reading freed
# memory. This turns "must not escape the callback" from undefined behaviour into
# a loud, catchable error — see `with_memory`/`borrow`.
#
# Mutation (`b.field = v`, `b[i] = v`, `b[] = v`) is only allowed on a
# `writable` borrow, which owns a private copy — mutating a zero-copy view of a
# *received* payload would write to loaned/shared (possibly read-only) memory.
#
# NOTE: property access is forwarded, so this type's own fields are reached only
# via `getfield`/`setfield!` internally, never `b.field`.

"""
    BorrowError <: Exception

Signals that a [`Borrowed`](@ref) view (or a [`GuardedPayloadView`](@ref)) was
used outside its valid scope: after `close`, or after it escaped the
[`with_memory`](@ref) / [`with_payload_memory_checked`](@ref) call that produced
it. The check fires on every access so a stale view raises a catchable error
rather than reading freed memory.
"""
struct BorrowError <: Exception
    msg::String
end
BorrowError() = BorrowError("")
Base.showerror(io::IO, e::BorrowError) = print(io, "BorrowError: ",
    isempty(e.msg) ?
        "borrowed payload used outside its valid scope (it must not escape \
         `with_memory`, and must not be used after `close`)" :
        e.msg)

"""
    Borrowed{T}

A scope-validated, value-first view of a payload reinterpreted as `T`. It reads
both like the struct — `b[]` dereferences the single element, `b.field` reads a
field — and like an array — `b[i]`, iteration, `length`, `collect`. While valid
it pins its source (the [`Sample`](@ref)/[`ZBytes`](@ref) or an owned copy) so
the bytes stay live; `close(b)` drops the pin, after which every access throws a
[`BorrowError`](@ref).

Mutation (`b.field = v`, `b[i] = v`, `b[] = v`) requires a writable borrow, which
owns a private copy. A zero-copy view of a received payload is read-only, since
its backing is loaned or shared memory.

Construct one with [`borrow`](@ref), or scope it to a block with
[`with_memory`](@ref), which closes it automatically and so catches escapes.
"""
mutable struct Borrowed{T}
    ptr::Ptr{T}
    n::Int            # number of T-elements in the view (1 for the common struct case)
    owner::Any        # pins the source while valid; cleared on close
    valid::Bool
    writable::Bool    # true ⇒ owns a private copy; mutation is allowed
    # Recycle token for a zero-copy borrow over an in-place-reused source (iterate
    # box / SampleHolder); `nothing` for an owned-copy borrow. Checked after `valid`
    # so a held view fails with `BorrowError` once its source slot recycled.
    tok::Union{Nothing,Tuple{_RecycleEpoch,UInt64}}
end

@inline function _check(b::Borrowed)
    getfield(b, :valid) || throw(BorrowError())   # closed/escaped first — never deref a stale tok
    _check_token(getfield(b, :tok))               # source recycled out from under a zero-copy view
end
@inline _check_writable(b::Borrowed{T}) where {T} =
    getfield(b, :writable) || throw(ArgumentError(
        "Borrowed{$T} is a read-only view; create it with `writable=true` (which copies) to mutate"))

Base.isvalid(b::Borrowed) = getfield(b, :valid)
Base.length(b::Borrowed)  = (_check(b); getfield(b, :n))
Base.eltype(::Type{Borrowed{T}}) where {T} = T
Base.IteratorSize(::Type{<:Borrowed}) = Base.HasLength()
Base.iswritable(b::Borrowed) = getfield(b, :writable)

# Single-value deref / assign — the common case (payload is one struct).
function Base.getindex(b::Borrowed{T}) where {T}
    _check(b)
    getfield(b, :n) == 1 || throw(ArgumentError(
        "Borrowed{$T} holds $(getfield(b, :n)) elements; index with `b[i]`, iterate, or `collect(b)`"))
    return GC.@preserve b unsafe_load(getfield(b, :ptr))
end
function Base.setindex!(b::Borrowed{T}, v) where {T}
    _check(b); _check_writable(b)
    getfield(b, :n) == 1 || throw(ArgumentError(
        "Borrowed{$T} holds $(getfield(b, :n)) elements; assign with `b[i] = v`"))
    GC.@preserve b unsafe_store!(getfield(b, :ptr), convert(T, v))
    return v
end
# Indexed access / assign — the buffer case.
function Base.getindex(b::Borrowed{T}, i::Integer) where {T}
    _check(b)
    (1 <= i <= getfield(b, :n)) || throw(BoundsError(b, i))
    return GC.@preserve b unsafe_load(getfield(b, :ptr), i)
end
function Base.setindex!(b::Borrowed{T}, v, i::Integer) where {T}
    _check(b); _check_writable(b)
    (1 <= i <= getfield(b, :n)) || throw(BoundsError(b, i))
    GC.@preserve b unsafe_store!(getfield(b, :ptr), convert(T, v), i)
    return v
end
function Base.iterate(b::Borrowed, i::Int=1)
    _check(b)
    i > getfield(b, :n) && return nothing
    return (GC.@preserve b unsafe_load(getfield(b, :ptr), i), i + 1)
end
function Base.collect(b::Borrowed{T}) where {T}
    _check(b)
    n = getfield(b, :n)
    out = Vector{T}(undef, n)
    GC.@preserve b out unsafe_copyto!(pointer(out), getfield(b, :ptr), n)
    return out
end
# Escape hatch: a raw pointer, checked at the call. The returned pointer is only
# valid while the borrow is — using it after `close` is back to undefined.
Base.pointer(b::Borrowed) = (_check(b); getfield(b, :ptr))

# --- struct-field proxy: b.field get/set, forwarded by offset --------
@inline function _field_index(::Type{T}, name::Symbol) where {T}
    i = findfirst(==(name), fieldnames(T))
    i === nothing && throw(ArgumentError("$T has no field `$name`"))
    return i
end
function Base.getproperty(b::Borrowed{T}, name::Symbol) where {T}
    _check(b)
    getfield(b, :n) == 1 || throw(ArgumentError(
        "property access on Borrowed{$T} needs a single element (it holds $(getfield(b, :n))); index first with `b[i]`"))
    i   = _field_index(T, name)
    FT  = fieldtype(T, i)
    off = fieldoffset(T, i)
    return GC.@preserve b unsafe_load(Ptr{FT}(getfield(b, :ptr) + off))
end
function Base.setproperty!(b::Borrowed{T}, name::Symbol, v) where {T}
    _check(b); _check_writable(b)
    getfield(b, :n) == 1 || throw(ArgumentError(
        "property assignment on Borrowed{$T} needs a single element (it holds $(getfield(b, :n))); index first with `b[i]`"))
    i   = _field_index(T, name)
    FT  = fieldtype(T, i)
    off = fieldoffset(T, i)
    GC.@preserve b unsafe_store!(Ptr{FT}(getfield(b, :ptr) + off), convert(FT, v))
    return v
end
Base.propertynames(::Borrowed{T}) where {T} = fieldnames(T)

function Base.close(b::Borrowed)
    setfield!(b, :valid, false)
    setfield!(b, :owner, nothing)      # release the pin so the source can be reclaimed
    setfield!(b, :tok, nothing)        # drop the recycle-token reference
    return nothing
end

Base.show(io::IO, b::Borrowed{T}) where {T} = print(io,
    getfield(b, :valid) ?
        "Borrowed{$T}($(getfield(b, :n)) element$(getfield(b, :n) == 1 ? "" : "s")$(getfield(b, :writable) ? ", writable" : ""))" :
        "Borrowed{$T}(invalidated)")

"""
    borrow(z::ZBytes, T=UInt8; writable=false)   -> Borrowed{T}
    borrow(s::Sample, T=UInt8; writable=false)   -> Borrowed{T}

A scope-validated view of the payload as `T`. Read a single struct with `b[]` or
`b.field`, a buffer with `b[i]`/iteration; get the length with `length(b)`. The
borrow pins its source while valid; call `close(b)` when done, after which any
use throws a [`BorrowError`](@ref). Prefer [`with_memory`](@ref), which closes
automatically (and so detects escapes).

With `writable=false` (default) the view is zero-copy when possible (SHM-backed
or a single contiguous, `T`-aligned network slice), else a one-time copy, and is
**read-only** — mutating a view of received/shared memory is unsafe. With
`writable=true` it always owns a private copy, and `b.field = v` / `b[i] = v` /
`b[] = v` mutate that copy in place (use `collect`/`as_memory` to extract it).
"""
function borrow(z::ZBytes, ::Type{T}=UInt8; writable::Bool=false) where {T}
    isbitstype(T) || throw(ArgumentError("borrow requires an isbits type, got $T"))
    nb = Int(length(z))
    nb % sizeof(T) == 0 ||
        throw(ArgumentError("payload ($nb bytes) is not a multiple of sizeof($T)=$(sizeof(T))"))
    n = nb ÷ sizeof(T)

    if !writable
        # Zero-copy tier 1 — SHM segment.
        shm = as_shm(z)
        if shm !== nothing && length(shm) >= nb && _aligned(pointer(shm), T)
            return Borrowed{T}(Ptr{T}(pointer(shm)), n, shm, true, false, _token(z))
        end
        # Zero-copy tier 2 — single contiguous, aligned network slice.
        view = Ref{LibZenohC.z_view_slice_t}()
        if LibZenohC.z_bytes_get_contiguous_view(_loaned_bytes(z), view) == LibZenohC.Z_OK
            sl = LibZenohC.z_view_slice_loan(view)
            p  = LibZenohC.z_slice_data(sl)
            if LibZenohC.z_slice_len(sl) >= nb && _aligned(p, T)
                return Borrowed{T}(Ptr{T}(p), n, _ZRefView(z, view), true, false, _token(z))
            end
        end
    end

    # Owned copy — the fragmented/misaligned fallback, and the only safely
    # mutable backing. `owner = mem` keeps it alive while the borrow is valid.
    mem = as_memory(z, T)
    return Borrowed{T}(Ptr{T}(pointer(mem)), n, mem, true, writable, nothing)
end
borrow(s::Sample, ::Type{T}=UInt8; writable::Bool=false) where {T} =
    borrow(payload(s), T; writable=writable)

"""
    with_memory(f, z::ZBytes, T=UInt8; writable=false)
    with_memory(f, s::AbstractSample, T=UInt8; writable=false)

Call `f(b::Borrowed{T})` with a scope-validated view of the payload, then close
the borrow — so a `Borrowed` (or pointer) that escapes `f` is invalidated and any
later use throws a [`BorrowError`](@ref) instead of reading freed memory. Read a
single struct with `b[]`/`b.field`, a buffer with `b[i]`/iteration. With
`writable=true`, `b` owns a copy you may mutate (`b.field = v`, `b[i] = v`).
Returns `f`'s result. To keep data past the call, copy out with [`as_memory`](@ref)
or `collect(b)`.
"""
function with_memory(f, z::ZBytes, ::Type{T}=UInt8; writable::Bool=false) where {T}
    b = borrow(z, T; writable=writable)
    try
        return f(b)
    finally
        close(b)
    end
end
with_memory(f, s::AbstractSample, ::Type{T}=UInt8; writable::Bool=false) where {T} =
    with_memory(f, payload(s), T; writable=writable)

"""
    PayloadView <: DenseVector{UInt8}

An **isbits** `(ptr, len)` view of a byte buffer as a `DenseVector{UInt8}`, so a
borrowed payload can back a `CDRReader` / `CDRString` / `CDRView` with **no heap
allocation** — unlike `unsafe_wrap(Memory{UInt8}, …)`, which heap-allocates a
`Memory` header per borrow. Because it is isbits, a `CDRString{PayloadView}` (and
the `CDRView` holding it) is itself isbits and stack-allocates.

Holds **no GC root** of its own: the bytes are kept alive by the enclosing
[`with_payload_memory`](@ref)'s `GC.@preserve` for the duration of `f` only. Any
use past `f` (a view that escapes the handler) reads freed memory — the same
contract as `with_payload_memory`.
"""
struct PayloadView <: DenseVector{UInt8}
    ptr::Ptr{UInt8}
    len::Int
end
@inline Base.size(p::PayloadView) = (getfield(p, :len),)
@inline Base.length(p::PayloadView) = getfield(p, :len)
Base.IndexStyle(::Type{PayloadView}) = Base.IndexLinear()
@inline function Base.getindex(p::PayloadView, i::Int)
    @boundscheck checkbounds(p, i)
    return unsafe_load(getfield(p, :ptr), i)
end
@inline Base.pointer(p::PayloadView) = getfield(p, :ptr)
@inline Base.pointer(p::PayloadView, i::Integer) = getfield(p, :ptr) + (Int(i) - 1)
@inline Base.unsafe_convert(::Type{Ptr{UInt8}}, p::PayloadView) = getfield(p, :ptr)
@inline Base.elsize(::Type{PayloadView}) = 1

"""
    with_payload_memory(f, z::ZBytes)
    with_payload_memory(f, s::AbstractSample)

Call `f(view::PayloadView)` with a zero-copy [`PayloadView`](@ref) of the payload
bytes for the duration of `f`, with **no allocation** on the contiguous path: no
`Borrowed`/`_ZRefView` wrappers (unlike [`with_memory`](@ref)) and — since
`PayloadView` is isbits — no `unsafe_wrap` `Memory` header either. SHM payloads
and a single contiguous network slice are viewed in place; a fragmented payload
falls back to an owned `as_memory` copy, still presented as a `PayloadView` (so
`f` sees one type on every tier). The backing bytes are kept alive across `f` via
`GC.@preserve`.

Lower-level than `with_memory`: it skips the scope-validated `BorrowError` safety
net, so it's for internal decode paths that consume the bytes within `f` and
don't let them escape. Anything escaping `f` reads freed memory.
"""
function with_payload_memory(f, z::ZBytes)
    nb = Int(length(z))
    nb == 0 && return f(PayloadView(Ptr{UInt8}(C_NULL), 0))
    # Tier 1 — SHM segment (view its data directly).
    shm = as_shm(z)
    if shm !== nothing && length(shm) >= nb
        return GC.@preserve z shm f(PayloadView(Ptr{UInt8}(pointer(shm)), nb))
    end
    # Tier 2 — single contiguous network slice (UInt8 ⇒ always aligned). No
    # `Borrowed`/`_ZRefView` and no `Memory` header: just the view handle (a Ref the
    # compiler stack-elides since it doesn't escape) + an isbits `PayloadView`.
    view = Ref{LibZenohC.z_view_slice_t}()
    if LibZenohC.z_bytes_get_contiguous_view(_loaned_bytes(z), view) == LibZenohC.Z_OK
        GC.@preserve z view begin
            sl = LibZenohC.z_view_slice_loan(view)
            if LibZenohC.z_slice_len(sl) >= nb
                return f(PayloadView(Ptr{UInt8}(LibZenohC.z_slice_data(sl)), nb))
            end
        end
    end
    # Tier 3 — fragmented/misaligned: owned copy, viewed in place (kept alive
    # across `f` by `GC.@preserve`, so `f` still gets a `PayloadView`).
    mem = as_memory(z, UInt8)
    return GC.@preserve mem f(PayloadView(Ptr{UInt8}(pointer(mem)), nb))
end
with_payload_memory(f, s::AbstractSample) =
    GC.@preserve s with_payload_memory(f, payload(s))

"""
    GuardedPayloadView <: DenseVector{UInt8}

Like [`PayloadView`](@ref) but carrying a shared validity flag: once the
enclosing [`with_payload_memory_checked`](@ref) call returns, the flag is cleared
and **every subsequent access throws [`BorrowError`](@ref)**. This turns the
fast-path's silent use-after-free (a `CDRView`/`CDRString` that escaped the
handler) into a loud, debuggable error — over the *same* representation the
zero-copy path ships, so it validates the exact code you'll run unchecked.

Not isbits (it holds the flag `Ref`), so it allocates — it's the validation tier,
not the production tier.
"""
struct GuardedPayloadView <: DenseVector{UInt8}
    ptr::Ptr{UInt8}
    len::Int
    valid::Base.RefValue{Bool}
end
@inline _guard(p::GuardedPayloadView) = getfield(p, :valid)[] ||
    throw(BorrowError("payload view used after the handler returned — the borrowed \
                       CDRView/CDRString escaped its scope (use `decode_owned`/`materialize` \
                       to keep it, or switch to an owned subscription)"))
@inline Base.size(p::GuardedPayloadView) = (getfield(p, :len),)
@inline Base.length(p::GuardedPayloadView) = getfield(p, :len)
Base.IndexStyle(::Type{GuardedPayloadView}) = Base.IndexLinear()
@inline function Base.getindex(p::GuardedPayloadView, i::Int)
    @boundscheck checkbounds(p, i)
    _guard(p)
    return unsafe_load(getfield(p, :ptr), i)
end
@inline Base.pointer(p::GuardedPayloadView) = (_guard(p); getfield(p, :ptr))
@inline Base.pointer(p::GuardedPayloadView, i::Integer) = (_guard(p); getfield(p, :ptr) + (Int(i) - 1))
@inline Base.unsafe_convert(::Type{Ptr{UInt8}}, p::GuardedPayloadView) = (_guard(p); getfield(p, :ptr))
@inline Base.elsize(::Type{GuardedPayloadView}) = 1

"""
    with_payload_memory_checked(f, z::ZBytes)
    with_payload_memory_checked(f, s::AbstractSample)

Like [`with_payload_memory`](@ref) but hands `f` a [`GuardedPayloadView`](@ref):
the zero-copy fast-path representation plus a runtime escape check. The view is
invalidated the instant `f` returns, so a `CDRView`/`CDRString` that escaped `f`
throws `BorrowError` on its next access instead of reading freed memory. The
validation tier — run a view handler under this to confirm it doesn't escape,
then switch to `with_payload_memory` for the allocation-free production path.
"""
function with_payload_memory_checked(f, z::ZBytes)
    valid = Ref(true)
    return with_payload_memory(z) do view
        gv = GuardedPayloadView(pointer(view), length(view), valid)
        try
            return f(gv)
        finally
            valid[] = false      # invalidate before the borrow's bytes go out of scope
        end
    end
end
with_payload_memory_checked(f, s::AbstractSample) =
    GC.@preserve s with_payload_memory_checked(f, payload(s))

# --- unsafe (uninstrumented) views -----------------------------------
#
# Same zero-copy/copy tiers as the safe API, but handing back a *raw* `Memory{T}`
# with no validity wrapper and no per-access checks. The caller takes on the
# lifetime contract themselves. Use in hot paths once the access pattern is
# known-correct; otherwise prefer `with_memory` / `borrow`.

"""
    unsafe_with_memory(f, z::ZBytes, T=UInt8)
    unsafe_with_memory(f, s::Sample, T=UInt8)

Like [`with_memory`](@ref) but passes `f` a **raw** `Memory{T}` instead of a
validated [`Borrowed`](@ref) — no per-access checks and no escape detection. The
view is zero-copy when possible (SHM / contiguous aligned slice), else a one-time
copy, and is pinned only for the duration of `f` via `GC.@preserve`. If the
`Memory` (or a pointer into it) escapes `f`, any later use is undefined
behaviour. Returns `f`'s result.
"""
function unsafe_with_memory(f, z::ZBytes, ::Type{T}=UInt8) where {T}
    isbitstype(T) || throw(ArgumentError("unsafe_with_memory requires an isbits type, got $T"))
    nb = Int(length(z))
    nb % sizeof(T) == 0 ||
        throw(ArgumentError("payload ($nb bytes) is not a multiple of sizeof($T)=$(sizeof(T))"))
    n = nb ÷ sizeof(T)

    shm = as_shm(z)
    if shm !== nothing && length(shm) >= nb && _aligned(pointer(shm), T)
        return GC.@preserve shm f(unsafe_wrap(Memory{T}, Ptr{T}(pointer(shm)), n))
    end

    view = Ref{LibZenohC.z_view_slice_t}()
    if LibZenohC.z_bytes_get_contiguous_view(_loaned_bytes(z), view) == LibZenohC.Z_OK
        sl = LibZenohC.z_view_slice_loan(view)
        p  = LibZenohC.z_slice_data(sl)
        if LibZenohC.z_slice_len(sl) >= nb && _aligned(p, T)
            return GC.@preserve z view f(unsafe_wrap(Memory{T}, Ptr{T}(p), n))
        end
    end

    return f(as_memory(z, T))    # owned copy
end
unsafe_with_memory(f, s::Sample, ::Type{T}=UInt8) where {T} = unsafe_with_memory(f, payload(s), T)

"""
    unsafe_memory(b::Borrowed{T}) -> Memory{T}

Extract the underlying `Memory{T}` from a [`Borrowed`](@ref) for a tight inner
loop, bypassing the per-access checks. Validity is checked **once**, here; the
returned `Memory` is raw — it is only valid while `b` is (before `close(b)` /
before the enclosing `with_memory` returns), and you must keep `b` reachable
(e.g. `GC.@preserve b`) while using it.
"""
function unsafe_memory(b::Borrowed{T}) where {T}
    _check(b)
    return unsafe_wrap(Memory{T}, getfield(b, :ptr), getfield(b, :n))
end

# --- accessors -------------------------------------------------------

@inline function _check_live(r::ZRef)
    r.consumed && throw(ArgumentError("ZRef has been consumed by put; its buffer is no longer valid"))
    _check_token(r.tok)   # borrowed receive ZRef: throw if its source slot was recycled
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
    # A borrowed (receive-side) ZRef views a loaned payload that's valid only while
    # reachable in the handler / before iteration advances. Handing out the raw
    # pointer lets it escape that scope with NO GC pin (unlike `r[]`, which loads
    # under `GC.@preserve r`), the worst silent use-after-free. Read with `r[]`
    # in-scope, or copy out (`collect`/`as_memory`); a writable send-side ZRef
    # (the common `pointer` use, for field-wise authoring) is unaffected.
    isborrowed(r) && throw(ArgumentError(
        "pointer() on a borrowed (receive-side) ZRef would escape the payload's loan; \
         read with `r[]` before the handler returns / iteration advances, or copy out \
         with `collect`/`as_memory`"))
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
    # Claim before the move: `_zref_bytes` hands the backing to a C consumer that
    # gravestones it even on a non-OK return, so the backing is gone regardless of
    # outcome. Marking consumed first keeps `r` from being retried/read over a
    # gravestoned handle if the move throws.
    r.consumed = true
    return _zref_bytes(r.backing)
end

"""
    put(p::Publisher, r::ZRef; kwargs...)
    put(ap::AdvancedPublisher, r::ZRef; kwargs...)
    put(s::Session, k::Keyexpr, r::ZRef; congestion_control, priority, express, allowed_destination, kwargs...)

Publish the value held by [`ZRef`](@ref) `r`. A Julia-backed handle is borrowed
(pinned for the lifetime of the payload); an SHM-backed handle is moved into the
payload zero-copy. Either way the backing becomes the published bytes and `r` is
marked consumed — a second `put` (or any access) on it throws.

`kwargs` set per-put options such as `encoding`, `attachment`, and `timestamp`.
"""
function put(p::Publisher, r::ZRef; kwargs...)
    # Build the (fallible) options and convert the ZRef BEFORE the C put, so a bad
    # `attachment` throws while `r` is still intact — after the irreversible move,
    # a throw would orphan a finalizer-less owned SHM payload. If the move itself
    # throws, release the already-built attachment on this task.
    opts, enc_ref, attach_ref, ts = _make_put_opts(LibZenohC.z_publisher_put_options_t; kwargs...)
    local bytes
    try
        bytes = _zref_to_bytes(r)
    catch
        attach_ref === nothing || close(attach_ref)
        rethrow()
    end
    # Lock against close/undeclare across the C put so we never loan a gravestoned handle (see
    # put(::Publisher, payload)). `r` is already consumed by `_zref_to_bytes`, so the post-close
    # no-op leaves it consumed.
    @lock p.lock begin
        if p.closed
            close(bytes)
            attach_ref === nothing || close(attach_ref)
            return nothing
        end
        GC.@preserve bytes enc_ref attach_ref ts begin
            _handle_result(LibZenohC.z_publisher_put(_loan(p.pub), _move(bytes), opts))
        end
    end
    return nothing
end

function put(ap::AdvancedPublisher, r::ZRef; kwargs...)
    inner, enc_ref, attach_ref, ts = _make_put_opts(LibZenohC.z_publisher_put_options_t; kwargs...)
    opts = Ref{LibZenohC.ze_advanced_publisher_put_options_t}()
    LibZenohC.ze_advanced_publisher_put_options_default(opts)
    _store_field!(opts, 1, inner[])  # ze_advanced_publisher_put_options_t.put_options
    local bytes
    try
        bytes = _zref_to_bytes(r)
    catch
        attach_ref === nothing || close(attach_ref)
        rethrow()
    end
    @lock ap.lock begin
        if ap.closed
            close(bytes)
            attach_ref === nothing || close(attach_ref)
            return nothing
        end
        GC.@preserve bytes enc_ref attach_ref ts begin
            _handle_result(LibZenohC.ze_advanced_publisher_put(_loan(ap.pub), _move(bytes), opts))
        end
    end
    return nothing
end

function put(s::Session, k::Keyexpr, r::ZRef;
        congestion_control::Union{Nothing, CongestionControl} = nothing,
        priority::Union{Nothing, Priority}                    = nothing,
        express::Union{Nothing, Bool}                         = nothing,
        allowed_destination::Union{Nothing, Locality}         = nothing,
        kwargs...)
    GC.@preserve s k begin
        sp = _loan(s); kp = _loan(k)        # closed-check BEFORE any owned payload is built/moved
        opts, enc_ref, attach_ref, ts = _make_put_opts(LibZenohC.z_put_options_t; kwargs...)
        optsP = Base.unsafe_convert(Ptr{LibZenohC.z_put_options_t}, opts)
        isnothing(congestion_control)  || (optsP.congestion_control  = _raw(congestion_control))
        isnothing(priority)            || (optsP.priority            = _raw(priority))
        isnothing(express)             || (optsP.is_express          = express)
        isnothing(allowed_destination) || (optsP.allowed_destination = _raw(allowed_destination))
        local bytes
        try
            bytes = _zref_to_bytes(r)       # move is the last fallible step before the C call
        catch
            attach_ref === nothing || close(attach_ref)
            rethrow()
        end
        GC.@preserve bytes enc_ref attach_ref ts begin
            _handle_result(LibZenohC.z_put(sp, kp, _move(bytes), opts))
        end
    end
end

export ZRef, zref, isborrowed, as_memory, with_memory, with_payload_memory, with_payload_memory_checked,
    PayloadView, GuardedPayloadView, borrow, Borrowed, BorrowError
export unsafe_with_memory, unsafe_memory
