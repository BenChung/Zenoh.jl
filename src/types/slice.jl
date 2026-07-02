# ZSlice — owned/loaned byte slice. The owned form attaches a drop
# finalizer; the buffer-borrowing constructor pins the source `Vector`
# until libzenoh releases it via the _release callback (see bytes.jl).

"""
    ZSlice{S}

A contiguous byte slice, Zenoh's `z_owned_slice_t` / `z_loaned_slice_t`. The `S`
type parameter selects the ownership state: an owned slice (`Ref{z_owned_slice_t}`)
or a borrowed one (`Ptr{z_loaned_slice_t}`).

Construct one of three ways:

- `ZSlice()` — an empty owned slice.
- `ZSlice(buf::Vector{UInt8}; copy=false)` — wraps a Julia byte vector. The
  default borrows `buf` zero-copy; `buf` must stay reachable and unmodified
  (no `resize!`) until libzenoh releases it. Pass `copy=true` to have libzenoh
  take its own copy immediately, freeing `buf` from that obligation.
- `ZSlice(ref::Ptr{z_loaned_slice_t})` — a loaned slice borrowing C-owned memory.

Owned slices carry a GC drop finalizer; loaned slices own nothing and need no
cleanup. `length` and `isempty` report the slice's byte count.

Unlike an owned [`ZBytes`](@ref), which deliberately omits a finalizer, owned
slices finalize on the GC because they are never SHM-backed.
"""
struct ZSlice{S <: Union{Base.RefValue{LibZenohC.z_owned_slice_t}, Ptr{LibZenohC.z_loaned_slice_t}}}
    s::S
    function ZSlice()
        ref = Ref{LibZenohC.z_owned_slice_t}()
        LibZenohC.z_slice_empty(ref)
        return _add_finalizer(new{Base.RefValue{LibZenohC.z_owned_slice_t}}(ref))
    end
    function ZSlice(buf::Vector{UInt8}; copy=false)
        ref = Ref{LibZenohC.z_owned_slice_t}()
        if copy
            _handle_result(LibZenohC.z_slice_copy_from_buf(ref, buf, length(buf)))
            return _add_finalizer(new{Base.RefValue{LibZenohC.z_owned_slice_t}}(ref))
        else
            Base.preserve_handle(buf)
            rtc = LibZenohC.z_slice_from_buf(ref, buf, length(buf),
                @cfunction(_release, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid})), Base.pointer_from_objref(buf))
            # On failure the deleter never fires, so unpin to avoid leaking.
            rtc == LibZenohC.Z_OK || Base.unpreserve_handle(buf)
            _handle_result(rtc)
            return _add_finalizer(new{Base.RefValue{LibZenohC.z_owned_slice_t}}(ref))
        end
    end
    function ZSlice(ref::Ptr{LibZenohC.z_loaned_slice_t})
        return new{Ptr{LibZenohC.z_loaned_slice_t}}(ref)
    end
end
Base.length(s::ZSlice{Base.RefValue{LibZenohC.z_owned_slice_t}}) = LibZenohC.z_slice_len(_loan(s.s))
Base.length(s::ZSlice{Ptr{LibZenohC.z_loaned_slice_t}}) = LibZenohC.z_slice_len(s.s)
Base.isempty(s::ZSlice{Base.RefValue{LibZenohC.z_owned_slice_t}}) = LibZenohC.z_slice_is_empty(_loan(s.s))
Base.isempty(s::ZSlice{Ptr{LibZenohC.z_loaned_slice_t}}) = LibZenohC.z_slice_is_empty(s.s)

function _add_finalizer(z::ZSlice{Base.RefValue{LibZenohC.z_owned_slice_t}})
    finalizer(r -> LibZenohC.z_slice_drop(_move(r)), z.s)
    return z
end

export ZSlice
