# ZBytes — owned/loaned byte payload, plus the IO/iterator views used to
# read it back out.
#
# `_release` is the deleter libzenohc invokes when it's done with an
# externally-allocated buffer the ZBytes wraps. `Base.preserve_handle`
# pins the Julia source object until the C side releases it; `_release`
# unpreserves on completion.
#
# NOTE: libzenohc may call `_release` from one of its own runtime threads
# (e.g. once a zero-copy `put` finishes transmitting), so this runs the
# Julia-heap-touching `unsafe_pointer_to_objref` / `unpreserve_handle`
# off a foreign thread. That relies on the runtime auto-adopting the
# thread on cfunction entry; it is the one place we knowingly diverge
# from callback.jl's "no Julia heap on foreign threads" discipline.

function _release(data::Ptr{Cvoid}, ctx::Ptr{Cvoid})
    Base.unpreserve_handle(Base.unsafe_pointer_to_objref(ctx))
    return C_NULL
end

"""
    ZBytes

Zenoh's raw byte payload, with minimized copying. The `R` type parameter selects
the underlying C handle: an owned `z_owned_bytes_t` for payloads you build to send,
or a borrowed `z_loaned_bytes_t` for inbound payloads that borrow a [`Sample`](@ref)'s
buffer. A single payload may stitch together multiple network fragments, so iterating
a `ZBytes` walks its byte slices (see `iterate`); materialize the whole
thing with `String(z)` or `Vector{UInt8}(z)`.

Constructors:
- `ZBytes()` — empty owned payload.
- `ZBytes(v::Vector{T}; copy=false)`, `ZBytes(m::Memory{T})`, `ZBytes(r::Ref{T})` —
  by default zero-copy: the source is pinned and handed to libzenoh with a deleter, so
  it is freed only once the C side is done. Pass `copy=true` for libzenoh to take its
  own copy immediately, releasing the source.
- `ZBytes(s::String; copy=false)` — same zero-copy/copy choice for a string.
- `ZBytes(s::Symbol)` — a static-lifetime string payload, no pinning.

Owned `ZBytes` deliberately carry no GC finalizer: reclaim one by moving it into
[`put`](@ref)/`reply`/`get`, which hands ownership to zenoh, or by [`close`](@ref)ing
it on your own task. A moved `ZBytes` is consumed and must not be reused. This keeps
cleanup on the caller's task, never a finalizer thread, which avoids an SHM bookkeeping
deadlock.

See also [`ZBytesWriter`](@ref) for incremental construction.
"""
struct ZBytes{R <: Union{Base.RefValue{LibZenohC.z_owned_bytes_t}, Ptr{LibZenohC.z_loaned_bytes_t}}}
        b::R
        # For the loaned form (`b::Ptr`), `owner` holds the Julia value the
        # pointer borrows from (a Sample/Query/Reply) so the underlying
        # buffer outlives this ZBytes. `nothing` for owned ZBytes, which
        # carry their own lifetime via `b`.
        owner::Any
        function ZBytes(r::Ref{T}) where T
            out = new{Base.RefValue{LibZenohC.z_owned_bytes_t}}(Ref{LibZenohC.z_owned_bytes_t}(), nothing)
            Base.preserve_handle(r)
            rtc = LibZenohC.z_bytes_from_buf(out.b, Base.unsafe_convert(Ptr{UInt8}, Base.unsafe_convert(Ptr{T}, r)), sizeof(T),
                @cfunction(_release, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid})), Base.pointer_from_objref(r))
            # On failure the deleter never fires, so unpin here to avoid
            # leaking the preserved handle.
            rtc == LibZenohC.Z_OK || Base.unpreserve_handle(r)
            _handle_result(rtc)
            return out
        end
    # Empty payload. Owned, but holds nothing — handy as a writer seed or a
    # zero-length reply body.
    function ZBytes()
        out = new{Base.RefValue{LibZenohC.z_owned_bytes_t}}(Ref{LibZenohC.z_owned_bytes_t}(), nothing)
        LibZenohC.z_bytes_empty(out.b)
        return out
    end
    # `copy=false` (default): zero-copy — pin `r` and hand libzenoh a deleter
    # so the buffer is freed only once the C side is done with it. `copy=true`:
    # libzenoh takes its own copy immediately, so `r` need not outlive the
    # ZBytes (mirrors `ZSlice(buf; copy=true)`).
    function ZBytes(r::Vector{T}; copy::Bool=false) where T
        out = new{Base.RefValue{LibZenohC.z_owned_bytes_t}}(Ref{LibZenohC.z_owned_bytes_t}(), nothing)
        if copy
            GC.@preserve r _handle_result(LibZenohC.z_bytes_copy_from_buf(out.b, r, length(r)*sizeof(T)))
            return out
        end
        Base.preserve_handle(r)
        rtc = LibZenohC.z_bytes_from_buf(out.b, r, length(r)*sizeof(T),
            @cfunction(_release, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid})), Base.pointer_from_objref(r))
        rtc == LibZenohC.Z_OK || Base.unpreserve_handle(r)
        _handle_result(rtc)
        return out
    end
    # Serialize a Memory{T} buffer for sending — borrowed (zero-copy) like the
    # Vector form; the Memory is pinned until libzenoh releases it.
    function ZBytes(m::Memory{T}) where T
        out = new{Base.RefValue{LibZenohC.z_owned_bytes_t}}(Ref{LibZenohC.z_owned_bytes_t}(), nothing)
        Base.preserve_handle(m)
        rtc = GC.@preserve m LibZenohC.z_bytes_from_buf(out.b,
            Ptr{UInt8}(pointer(m)), length(m)*sizeof(T),
            @cfunction(_release, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid})), Base.pointer_from_objref(m))
        rtc == LibZenohC.Z_OK || Base.unpreserve_handle(m)
        _handle_result(rtc)
        return out
    end
    # `owner` is the value the loaned pointer borrows from; pass it so the
    # ZBytes keeps the source buffer alive (see field doc above).
    function ZBytes(p::Ptr{LibZenohC.z_loaned_bytes_t}, owner=nothing)
        return new{Ptr{LibZenohC.z_loaned_bytes_t}}(p, owner)
    end
    function ZBytes(s::String; copy::Bool=false)
        # `copy=true`: libzenoh takes its own copy, so we don't pin `s`.
        if copy
            b = Ref{LibZenohC.z_owned_bytes_t}()
            GC.@preserve s _handle_result(LibZenohC.z_bytes_copy_from_buf(b, Base.unsafe_convert(Ptr{UInt8}, s), sizeof(s)))
            return new{Base.RefValue{LibZenohC.z_owned_bytes_t}}(b, nothing)
        end
        # Box the String in a RefValue so we have a stable, mutable handle to
        # pass as ctx to the C deleter. preserve_handle/unpreserve_handle pin
        # the box (and transitively the String) until libzenoh releases it.
        box = Ref{String}(s)
        Base.preserve_handle(box)
        cstr = Base.unsafe_convert(Cstring, s)
        b = Ref{LibZenohC.z_owned_bytes_t}()
        rtc = GC.@preserve s LibZenohC.z_bytes_from_str(b, pointer(cstr),
            @cfunction(_release, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid})), Base.pointer_from_objref(box))
        rtc == LibZenohC.Z_OK || Base.unpreserve_handle(box)
        _handle_result(rtc)
        return new{Base.RefValue{LibZenohC.z_owned_bytes_t}}(b, nothing)
    end
    function ZBytes(s::Symbol)
        out = new{Base.RefValue{LibZenohC.z_owned_bytes_t}}(Ref{LibZenohC.z_owned_bytes_t}(), nothing)
        rtc = LibZenohC.z_bytes_from_static_str(out.b, Base.unsafe_convert(Ptr{UInt8}, s))
        _handle_result(rtc)
        return out
    end
    # Wrap a z_owned_bytes_t that an external builder (z_bytes_from_shm,
    # z_bytes_from_shm_mut, …) has already populated. shm.jl uses this.
    function ZBytes(b::Base.RefValue{LibZenohC.z_owned_bytes_t}, ::Val{:owned})
        return new{Base.RefValue{LibZenohC.z_owned_bytes_t}}(b, nothing)
    end
end
# NOTE on ownership: owned ZBytes deliberately carry NO GC finalizer, and one
# must not be added. `z_bytes_drop` invokes the zero-copy deleter (`_release`,
# which touches the Julia heap); on the GC/finalizer thread, dropping an
# SHM-backed payload off-thread corrupts zenoh's SHM segment bookkeeping and
# wedges SHM delivery (a session-fast-path round-trip hangs) under GC pressure.
# Cleanup must run on the caller's task.
#
# This is safe because no API forces a user to hold an owned ZBytes: the
# pub/sub/query paths all `_move` their bytes into a C call, and inbound
# payloads are loaned. The two ways to get a user-held owned ZBytes —
# `ZBytes(x)` and `finish(::ZBytesWriter)` — both have a leak-free exit:
#   • move-on-send — pass it to `put`/`reply`/`get`; the move (below, via the
#     `ZBytes(::ZBytes)` identity) hands ownership to zenoh, which frees it;
#   • `close(z)` — drop it explicitly on the caller's task if you won't send.
# Only build-then-discard-without-either leaks, which is a degenerate program.

Base.length(z::ZBytes{Base.RefValue{LibZenohC.z_owned_bytes_t}}) = LibZenohC.z_bytes_len(_loan(z.b))
Base.length(z::ZBytes{Ptr{LibZenohC.z_loaned_bytes_t}}) = LibZenohC.z_bytes_len(z.b)

# Identity for an owned ZBytes. Lets the send APIs — which build their payload
# with `ZBytes(payload)` and then `_move` it — accept an already-built owned
# ZBytes (e.g. from `finish(::ZBytesWriter)`) and move it in unchanged. The
# move consumes it, so a sent ZBytes can't leak. (Loaned ZBytes have no owned
# handle to move; forwarding a received payload would need an explicit clone.)
ZBytes(z::ZBytes{Base.RefValue{LibZenohC.z_owned_bytes_t}}) = z

_move(p::ZBytes) = _move(p.b)

_loaned_bytes(b::ZBytes{Base.RefValue{LibZenohC.z_owned_bytes_t}}) = _loan(b.b)
_loaned_bytes(b::ZBytes{Ptr{LibZenohC.z_loaned_bytes_t}}) = b.b

Base.isempty(z::ZBytes) = LibZenohC.z_bytes_is_empty(_loaned_bytes(z))

# Explicitly reclaim an owned ZBytes you built but won't send — drops the C
# handle on the caller's task (never a finalizer/GC thread, so no hang risk).
# A no-op for loaned ZBytes, which borrow their buffer. Don't use the ZBytes
# after closing it.
function Base.close(z::ZBytes{Base.RefValue{LibZenohC.z_owned_bytes_t}})
    LibZenohC.z_bytes_drop(_move(z.b))
    return nothing
end
Base.close(::ZBytes{Ptr{LibZenohC.z_loaned_bytes_t}}) = nothing

# Materialize the whole payload into a Julia String. Copies out of the
# (possibly multi-slice) payload, so the result is independent of `z`.
function Base.String(z::ZBytes)
    s = Ref{LibZenohC.z_owned_string_t}()
    _handle_result(LibZenohC.z_bytes_to_string(_loaned_bytes(z), s))
    try
        return _string(s)
    finally
        _drop(_move(s))
    end
end

# Materialize the whole payload into an owned Julia byte vector.
function Base.Vector{UInt8}(z::ZBytes)
    sl = Ref{LibZenohC.z_owned_slice_t}()
    _handle_result(LibZenohC.z_bytes_to_slice(_loaned_bytes(z), sl))
    try
        loaned = _loan(sl)
        n = LibZenohC.z_slice_len(loaned)
        out = Vector{UInt8}(undef, n)
        n == 0 || GC.@preserve out unsafe_copyto!(pointer(out), LibZenohC.z_slice_data(loaned), n)
        return out
    finally
        LibZenohC.z_slice_drop(_move(sl))
    end
end

"""
    ZBytesReader

An `IO`-conforming, seekable reader over a [`ZBytes`](@ref) payload. Obtain one with
`open(z, Val(:read))`; it borrows the payload's buffer (so the source `ZBytes` must
outlive it) and reads the bytes back via the usual `IO` interface — `read`,
`readbytes!`, `unsafe_read`, `readavailable`, plus `seek`/`skip`/`position`,
`bytesavailable`, and `eof`. Borrowing nothing of its own, [`close`](@ref) is a no-op.

For walking the payload one network fragment at a time without copying, see
[`ZBytesSliceReader`](@ref).
"""
struct ZBytesReader{Z <: ZBytes} <: IO
    z::Z
    r::Base.RefValue{LibZenohC.z_bytes_reader_t}
end
function Base.open(z::ZBytes{Base.RefValue{LibZenohC.z_owned_bytes_t}}, ::Val{:read})
    return ZBytesReader(z, Ref(LibZenohC.z_bytes_get_reader(_loan(z.b))))
end
function Base.open(z::ZBytes{Ptr{LibZenohC.z_loaned_bytes_t}}, ::Val{:read})
    return ZBytesReader(z, Ref(LibZenohC.z_bytes_get_reader(z.b)))
end
function Base.read(zr::ZBytesReader, ::Type{UInt8})
    byte = Ref{UInt8}()
    unsafe_read(zr, byte, 1)
    return byte[]
end
Base.readbytes!(zr::ZBytesReader, b::AbstractVector{UInt8}, nb::Csize_t) = LibZenohC.z_bytes_reader_read(zr.r, Base.unsafe_convert(Ptr{UInt8}, b), nb)
Base.unsafe_read(zr::ZBytesReader, b::Ptr{UInt8}, nb::UInt) = LibZenohC.z_bytes_reader_read(zr.r, b, nb)
Base.seek(zr::ZBytesReader, pos) = _handle_result(LibZenohC.z_bytes_reader_seek(zr.r, pos, 0))
Base.skip(zr::ZBytesReader, num) = _handle_result(LibZenohC.z_bytes_reader_seek(zr.r, num, 1)) # seek_cur
Base.position(zr::ZBytesReader) = LibZenohC.z_bytes_reader_tell(zr.r)
Base.bytesavailable(zr::ZBytesReader) = LibZenohC.z_bytes_reader_remaining(zr.r)
function Base.readavailable(zr::ZBytesReader)
    nbytes = bytesavailable(zr)
    arr = Vector{UInt8}(undef, nbytes)
    readbytes!(zr, arr, nbytes)
    return arr
end
Base.eof(zr::ZBytesReader) = bytesavailable(zr) == 0
function Base.close(zr::ZBytesReader)
    # the reader borrows the ZBytes buffer; nothing owned to free
end

struct ZBytesSliceIterator
    it::Base.RefValue{LibZenohC.z_bytes_slice_iterator_t}
end

function Base.iterate(b::ZBytes)
    biterator = ZBytesSliceIterator(Ref(LibZenohC.z_bytes_get_slice_iterator(_loaned_bytes(b))))
    item = Ref{LibZenohC.z_view_slice_t}()
    has_next = LibZenohC.z_bytes_slice_iterator_next(biterator.it, item)
    if has_next
        return (item, biterator)
    else
        return nothing
    end
end

function Base.iterate(b::ZBytes, biterator::ZBytesSliceIterator)
    item = Ref{LibZenohC.z_view_slice_t}()
    has_next = LibZenohC.z_bytes_slice_iterator_next(biterator.it, item)
    if has_next
        return (item, biterator)
    else
        return nothing
    end
end

"""
    ZBytesSliceReader

An `IO`-conforming reader that streams a [`ZBytes`](@ref) payload across its underlying
network fragments, copying out of one borrowed slice at a time rather than materializing
the whole payload. Obtain one with `open(z, Val(:readslice))`; it borrows the payload's
buffer (so the source `ZBytes` must outlive it). Reads — `read`, `readbytes!`,
`unsafe_read` — transparently advance to the next slice when the current one is
exhausted; `skip`, `position`, `bytesavailable`, and `eof` track progress over the whole
payload. Borrowing nothing of its own, [`close`](@ref) is a no-op.

For a seekable reader over the payload as a single stream, see [`ZBytesReader`](@ref).
"""
mutable struct ZBytesSliceReader{Z <: ZBytes} <: IO
    z::Z

    iterator::Base.RefValue{LibZenohC.z_bytes_slice_iterator_t}
    current::Base.RefValue{LibZenohC.z_view_slice_t}
    current_ptr::Union{Ptr{UInt8}, Nothing}
    current_bytes_remaining::UInt64
    bytes_remaining::UInt64
    position::UInt64
end
function Base.open(z::ZBytes, ::Val{:readslice})
    bytes_remaining = length(z)
    return ZBytesSliceReader(z, Ref(LibZenohC.z_bytes_get_slice_iterator(_loan(z.b))), Ref{LibZenohC.z_view_slice_t}(), nothing, UInt64(0), bytes_remaining, UInt64(0))
end
Base.readbytes!(zr::ZBytesSliceReader, b::AbstractVector{UInt8}, nb) = unsafe_read(zr, Base.unsafe_convert(Ptr{UInt8}, b), nb)
function Base.unsafe_read(zr::ZBytesSliceReader, b::Ptr{UInt8}, nb::UInt)
    if zr.bytes_remaining < nb
        nb = zr.bytes_remaining
    end
    if zr.current_bytes_remaining >= nb
        unsafe_copyto!(b, zr.current_ptr, nb)
        zr.current_bytes_remaining -= nb
        zr.bytes_remaining -= nb
        zr.current_ptr += nb
        zr.position += nb
        return nb
    else
        if zr.current_bytes_remaining > 0
            unsafe_copyto!(b, zr.current_ptr, zr.current_bytes_remaining)
            zr.bytes_remaining -= zr.current_bytes_remaining
            zr.position += nb
        end
        read_bytes = zr.current_bytes_remaining
        next_b = b + read_bytes
        residual = nb - read_bytes
        has_next = LibZenohC.z_bytes_slice_iterator_next(zr.iterator, zr.current)
        if !has_next
            return read_bytes
        end
        loaned_slice = LibZenohC.z_view_slice_loan(zr.current)
        zr.current_ptr = LibZenohC.z_slice_data(loaned_slice)
        zr.current_bytes_remaining = LibZenohC.z_slice_len(loaned_slice)
        return unsafe_read(zr, next_b, residual) + read_bytes
    end
end
Base.bytesavailable(zr::ZBytesSliceReader) = zr.bytes_remaining
Base.eof(zr::ZBytesSliceReader) = bytesavailable(zr) == 0
Base.position(zr::ZBytesSliceReader) = zr.position
function Base.skip(zr::ZBytesSliceReader, nb)
    if zr.bytes_remaining < nb
        nb = zr.bytes_remaining
    end
    if zr.current_bytes_remaining >= nb
        zr.current_bytes_remaining -= nb
        zr.bytes_remaining -= nb
        zr.current_ptr += nb
        zr.position += nb
        return nothing
    else
        if zr.current_bytes_remaining > 0
            zr.bytes_remaining -= zr.current_bytes_remaining
            zr.position += nb
        end
        read_bytes = zr.current_bytes_remaining
        residual = nb - read_bytes
        has_next = LibZenohC.z_bytes_slice_iterator_next(zr.iterator, zr.current)
        if !has_next
            return read_bytes
        end
        loaned_slice = LibZenohC.z_view_slice_loan(zr.current)
        zr.current_ptr = LibZenohC.z_slice_data(loaned_slice)
        zr.current_bytes_remaining = LibZenohC.z_slice_len(loaned_slice)
        return skip(zr, residual)
    end
end

function Base.close(z::ZBytesSliceReader)
end

# ZBytesWriter — the write-side mirror of ZBytesReader. Build a payload
# incrementally with `write`/`append!`, then `finish` it into a ZBytes.
#
# The writer owns a C resource (`z_owned_bytes_writer_t`) that `finish`
# consumes (moves) out. It deliberately carries NO GC finalizer: dropping a
# zenoh handle from the finalizer thread risks blocking on zenoh-internal
# locks (see the ownership note above ZBytes), and a hang risk is
# unacceptable. So cleanup is explicit and always runs on the caller's task:
# `finish` consumes the writer; `close` drops an unfinished one. The do-block
# form below guarantees one of these always fires. The only way to leak the
# writer is to build one with the bare constructor and then drop the
# reference without `finish`/`close` — a misuse, not a normal path.
"""
    ZBytesWriter()

An `IO`-conforming, incremental builder for a [`ZBytes`](@ref) payload. `write(w, x)`
appends a value's raw bytes and `append!``(w, z)` splices an existing `ZBytes`
onto the tail (moving it, zero-copy when possible). [`finish`](@ref)`(w)` consumes the
writer and returns the assembled payload.

The writer owns a C resource and carries no GC finalizer, so reclaim it explicitly on
your own task: [`finish`](@ref) consumes it, or [`close`](@ref) drops an unfinished one.
The do-block form `open(ZBytes, Val(:write)) do w … end` guarantees one of these always
fires and returns the finished payload:

```julia
bytes = open(ZBytes, Val(:write)) do w
    write(w, "header")
    write(w, payload)
end
```
"""
mutable struct ZBytesWriter <: IO
    w::Base.RefValue{LibZenohC.z_owned_bytes_writer_t}
    done::Bool
    function ZBytesWriter()
        w = Ref{LibZenohC.z_owned_bytes_writer_t}()
        _handle_result(LibZenohC.z_bytes_writer_empty(w))
        return new(w, false)
    end
end

# Backs `write(w, x)` for every type Base lowers to a raw byte write.
function Base.unsafe_write(w::ZBytesWriter, p::Ptr{UInt8}, n::UInt)
    w.done && error("write to a finished ZBytesWriter")
    _handle_result(LibZenohC.z_bytes_writer_write_all(_loan_mut(w.w), p, n))
    return Int(n)
end

# Splice an existing ZBytes onto the tail of the writer. This *moves* `z`
# (zero-copy when possible), so `z` must not be used afterward.
function Base.append!(w::ZBytesWriter, z::ZBytes)
    w.done && error("append! to a finished ZBytesWriter")
    _handle_result(LibZenohC.z_bytes_writer_append(_loan_mut(w.w), _move(z)))
    return w
end

"""
    finish(w::ZBytesWriter) -> ZBytes

Consume the writer and return the assembled owned [`ZBytes`](@ref) payload. This moves
the writer's C resource out, so the writer is spent afterward and any further
`write`/`append!`/`finish` errors.

`finish` is also defined for [`ZSerializer`](@ref), where it closes out the structured
codec into a payload.
"""
function finish(w::ZBytesWriter)
    w.done && error("ZBytesWriter already finished")
    b = Ref{LibZenohC.z_owned_bytes_t}()
    LibZenohC.z_bytes_writer_finish(_move(w.w), b)
    w.done = true
    return ZBytes(b, Val(:owned))
end

# Drop an unfinished writer's C resource explicitly (no-op once finished).
# Runs on the caller's task, so unlike a finalizer it can't deadlock with
# zenoh internals. Call it to discard a writer you won't `finish`.
function Base.close(w::ZBytesWriter)
    w.done && return nothing
    w.done = true
    LibZenohC.z_bytes_writer_drop(_move(w.w))
    return nothing
end

# Do-block form mirroring `open(z, Val(:read))`: returns the finished ZBytes.
# Guarantees the writer is cleaned up — `finish` on success, `close` if `f`
# throws — so this form can never leak the writer.
#   bytes = open(ZBytes, Val(:write)) do w
#       write(w, "header"); write(w, payload)
#   end
function Base.open(f::Function, ::Type{ZBytes}, ::Val{:write})
    w = ZBytesWriter()
    try
        f(w)
        return finish(w)
    catch
        close(w)
        rethrow()
    end
end

export ZBytes, ZBytesWriter, finish
