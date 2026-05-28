# ZSlice — owned/loaned byte slice. The owned form attaches a drop
# finalizer; the buffer-borrowing constructor pins the source `Vector`
# until libzenoh releases it via the _release callback (see bytes.jl).

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
            _handle_result(LibZenohC.z_slice_from_buf(ref, buf, length(buf),
                @cfunction(_release, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid})), Base.pointer_from_objref(buf)))
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
