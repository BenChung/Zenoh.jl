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
    function ZBytes(r::Vector{T}) where T
        out = new{Base.RefValue{LibZenohC.z_owned_bytes_t}}(Ref{LibZenohC.z_owned_bytes_t}(), nothing)
        Base.preserve_handle(r)
        rtc = LibZenohC.z_bytes_from_buf(out.b, r, length(r)*sizeof(T),
            @cfunction(_release, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid})), Base.pointer_from_objref(r))
        rtc == LibZenohC.Z_OK || Base.unpreserve_handle(r)
        _handle_result(rtc)
        return out
    end
    # `owner` is the value the loaned pointer borrows from; pass it so the
    # ZBytes keeps the source buffer alive (see field doc above).
    function ZBytes(p::Ptr{LibZenohC.z_loaned_bytes_t}, owner=nothing)
        return new{Ptr{LibZenohC.z_loaned_bytes_t}}(p, owner)
    end
    function ZBytes(s::String)
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
Base.length(z::ZBytes{Base.RefValue{LibZenohC.z_owned_bytes_t}}) = LibZenohC.z_bytes_len(_loan(z.b))
Base.length(z::ZBytes{Ptr{LibZenohC.z_loaned_bytes_t}}) = LibZenohC.z_bytes_len(z.b)

_move(p::ZBytes) = _move(p.b)

_loaned_bytes(b::ZBytes{Base.RefValue{LibZenohC.z_owned_bytes_t}}) = _loan(b.b)
_loaned_bytes(b::ZBytes{Ptr{LibZenohC.z_loaned_bytes_t}}) = b.b

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
    # don't have to do anything
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
