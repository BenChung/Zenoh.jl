module Zenoh
using CClosure
include("../gen/LibZenohC.jl")
include("ownership.jl")
include("result.jl")
include("config.jl")
include("session.jl")



function _string(r::Ref{LibZenohC.z_owned_string_t})
    return unsafe_string(LibZenohC.z_string_data(_loan(r)), LibZenohC.z_string_len(_loan(r)))
end

const _refs_in_flight = Dict{UInt64, Ref}()
const _refptr = Ref{UInt64}(0)

function _release(data::Ptr{Cvoid}, ctx::Ptr{Cvoid})
    Base.unpreserve_handle(Base.unsafe_pointer_to_objref(ctx))
    return C_NULL
end
struct ZBytes{R <: Union{Base.RefValue{LibZenohC.z_owned_bytes_t}, Ptr{LibZenohC.z_loaned_bytes_t}}} 
        b::R
        function ZBytes(r::Ref{T}) where T
            out = new{Base.RefValue{LibZenohC.z_owned_bytes_t}}(Ref{LibZenohC.z_owned_bytes_t}())
            Base.preserve_handle(r)
            rtc = LibZenohC.z_bytes_from_buf(out.b, Base.unsafe_convert(Ptr{UInt8}, Base.unsafe_convert(Ptr{T}, r)), sizeof(T), 
                @cfunction(_release, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid})), Base.pointer_from_objref(r))
            _handle_result(rtc)
            return out
        end
    function ZBytes(r::Vector{T}) where T
        out = new{Base.RefValue{LibZenohC.z_owned_bytes_t}}(Ref{LibZenohC.z_owned_bytes_t}())
        Base.preserve_handle(r)
        rtc = LibZenohC.z_bytes_from_buf(out.b, r, length(r)*sizeof(T), 
            @cfunction(_release, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid})), Base.pointer_from_objref(r))
        _handle_result(rtc)
        return out
    end
    function ZBytes(p::Ptr{LibZenohC.z_loaned_bytes_t})
        return new{Ptr{LibZenohC.z_loaned_bytes_t}}(p)
    end
    function ZBytes(s::String)
        Base.preserve_handle(s)
        cstr = Base.unsafe_convert(Cstring, s)
        b = Ref{LibZenohC.z_owned_bytes_t}()
        rtc = LibZenohC.z_bytes_from_str(b, pointer(cstr),
            @cfunction(_release, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid})), Base.reinterpret(Ptr{UInt8}, Base.pointer_from_objref(s)))
        _handle_result(rtc)
        return new{Base.RefValue{LibZenohC.z_owned_bytes_t}}(b)
    end
    function ZBytes(s::Symbol)
        out = new{Base.RefValue{LibZenohC.z_owned_bytes_t}}(Ref{LibZenohC.z_owned_bytes_t}())
        rtc = LibZenohC.z_bytes_from_static_str(out.b, Base.unsafe_convert(Ptr{UInt8}, s))
        _handle_result(rtc)
        return out
    end
end
Base.length(z::ZBytes{Base.RefValue{LibZenohC.z_owned_bytes_t}}) = LibZenohC.z_bytes_len(_loan(z.b))
Base.length(z::ZBytes{Ptr{LibZenohC.z_loaned_bytes_t}}) = LibZenohC.z_bytes_len(z.b)

struct ZBytesReader{Z <: ZBytes} <: IO
    z::Z
    r::Ref{LibZenohC.z_bytes_reader_t}
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
                @cfunction(_release, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid})), Base.reinterpret(Ptr{UInt8}, Base.pointer_from_objref(s))))
            return _add_finalizer(new{Base.RefValue{LibZenohC.z_owned_slice_t}}(ref))
        end
    end
    function ZSlice(ref::Ptr{LibZenohC.z_loaned_slice_t})
        return new{Ptr{LibZenohC.z_loaned_slice_t}}(ref)
    end
end
Base.length(s::ZSlice) = LibZenohC.z_slice_len(s.s)
Base.isempty(s::ZSlice) = LibZenohC.z_slice_is_empty(s.s)

function _add_finalizer(z::ZSlice{Base.RefValue{LibZenohC.z_owned_slice_t}})
    finalizer(s->LibZenohC.z_slice_drop(_move(s.s)), z.s)
    return z
end


struct ZBytesSliceIterator
    it::Ref{LibZenohC.z_bytes_slice_iterator_t}
end
function Base.iterate(b::ZBytes)
    biterator = ZBytesSliceIterator(Ref(LibZenohC.z_bytes_get_slice_iterator(b)))
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



struct Keyexpr
    k::Base.RefValue{LibZenohC.z_owned_keyexpr_t}
    function Keyexpr(s::String; kwargs...)
        return Keyexpr(Base.unsafe_convert(Cstring, s); kwargs...)
    end
    function Keyexpr(s::Cstring; autocanonize=false)
        k = Ref{LibZenohC.z_owned_keyexpr_t}()
        res = new(k)
        if autocanonize
            rtc = LibZenohC.z_keyexpr_from_str_autocanonize(res.k, pointer(s)) # copies but we shouldn't do much of this
        else 
            rtc = LibZenohC.z_keyexpr_from_str(res.k, pointer(s))
        end
        _handle_result(rtc)
        finalizer(k -> LibZenohC.z_keyexpr_drop(_move(k)), k)
        return res
    end
end

struct Subscriber{TC}
    sub::Base.RefValue{LibZenohC.z_owned_subscriber_t}
    keyexpr::Keyexpr
    sub_ctx::Base.RefValue{TC}
end
struct Sample 
    s::Ptr{LibZenohC.z_loaned_sample_t}
end

"""
Subscribe to keyexpr `k` in session `s`, calling handler `f`.
"""
function Base.open(f::Function, s::Session, k::Keyexpr; should_close_on_error=true)
    sub::Union{Subscriber, Nothing} = nothing
    sub_func, sub_ctx = cclosure(2, Cvoid, (Ptr{LibZenohC.z_loaned_sample_t}, )) do sample 
        try
            f(Sample(sample))
        catch e
            Base.showerror(stderr, e, catch_backtrace())
            if should_close_on_error && !isnothing(sub)
                close(sub)
            end
        end
        nothing
    end
    sub = Subscriber{typeof(sub_ctx)}(Ref{LibZenohC.z_owned_subscriber_t}(), k, Ref{typeof(sub_ctx)}())
    sub.sub_ctx[] = sub_ctx
    sub_closure = Ref{LibZenohC.z_owned_closure_sample_t}()
    LibZenohC.z_closure_sample(sub_closure, sub_func, C_NULL, sub.sub_ctx)

    ret = LibZenohC.z_declare_subscriber(_loan(s), sub.sub, _loan(k), _move(sub_closure), C_NULL)
    _handle_result(ret)
    return sub
end
function Base.close(s::Subscriber)
    _handle_result(LibZenohC.z_undeclare_subscriber(_move(s.sub)))
end

struct Publisher
    pub::Base.RefValue{LibZenohC.z_owned_publisher_t}
    keyexpr::Keyexpr # we have to keep this for GC
    function Publisher(s::Session, k::Keyexpr)
        opts = Ref{LibZenohC.z_publisher_options_t}()
        LibZenohC.z_publisher_options_default(opts)
        pub = Ref{LibZenohC.z_owned_publisher_t}()
        ret = LibZenohC.z_declare_publisher(_loan(s), pub, _loan(k), opts)
        _handle_result(ret)
        return new(pub, k)
    end
end
function Base.close(s::Publisher)
    _handle_result(LibZenohC.z_undeclare_publisher(_move(s.pub)))
end


struct ZTimestamp
    ts::Base.RefValue{LibZenohC.z_timestamp_t}
end

function ZTimestamp(s::Session)
    ts = Ref{LibZenohC.z_timestamp_t}()
    ret = LibZenohC.z_timestamp_new(ts, _loan(s))
    _handle_result(ret)
    return ZTimestamp(ts)
end

function ZTimestamp(ptr::Ptr{LibZenohC.z_timestamp_t})
    ts = Ref{LibZenohC.z_timestamp_t}()
    # Copy the timestamp data by value
    unsafe_copyto!(Base.unsafe_convert(Ptr{LibZenohC.z_timestamp_t}, ts), ptr, 1)
    return ZTimestamp(ts)
end

zid(z::ZTimestamp) = LibZenohC.z_timestamp_id(z.ts)
ntp64_time(z::ZTimestamp) = LibZenohC.z_timestamp_ntp64_time(z.ts)

function _init_put_opts(::Type{LibZenohC.z_publisher_put_options_t})
    opts = Ref{LibZenohC.z_publisher_put_options_t}()
    LibZenohC.z_publisher_put_options_default(opts)
    return opts
end

function _init_put_opts(::Type{LibZenohC.z_put_options_t})
    opts = Ref{LibZenohC.z_put_options_t}()
    LibZenohC.z_put_options_default(opts)
    return opts
end

const _Put_Types = Union{LibZenohC.z_publisher_put_options_t, LibZenohC.z_put_options_t}
function _make_put_opts(::Type{T}; timestamp::Union{Nothing, ZTimestamp}=nothing) where T<:_Put_Types
    opts = _init_put_opts(T)
    
    if !isnothing(timestamp)
        Base.unsafe_convert(Ptr{LibZenohC.z_publisher_put_options_t}, opts).timestamp = Base.unsafe_convert(Ptr{LibZenohC.z_timestamp_t}, timestamp.ts)
    end
    
    return opts
end

function put(p::Publisher, payload; kwargs...)
    bytes = ZBytes(payload)
    opts = _make_put_opts(LibZenohC.z_publisher_put_options_t; kwargs...)
    
    rtc = LibZenohC.z_publisher_put(_loan(p.pub), _move(bytes), opts)
    _handle_result(rtc)
end

function put(s::Session, k::Keyexpr, payload; kwargs...)
    bytes = ZBytes(payload)
    opts = _make_put_opts(LibZenohC.z_put_options_t; kwargs...)
    
    rtc = LibZenohC.z_put(_loan(s), _loan(k), _move(bytes), opts)
    _handle_result(rtc)
end

function timestamp(s::Sample)
    ts = LibZenohC.z_sample_timestamp(s.s)
    if ts == C_NULL
        return nothing
    else
        ZTimestamp(ts)
    end
end

function payload(s::Sample)
    return ZBytes(LibZenohC.z_sample_payload(s.s))
end

function setup_logging()
    _handle_result(LibZenohC.zc_init_log_from_env_or("info"))
end


_loan(s::Session) = _loan(s.s)
_loan(s::Keyexpr) = _loan(s.k)
_move(p::ZBytes) = _move(p.b)

end # module Zenoh
