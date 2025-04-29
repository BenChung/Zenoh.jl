module LibZenohC

using ZenohC_jll
export ZenohC_jll

using CEnum

INT8_MIN = typemin(Int8)

struct z_owned_bytes_t
    data::NTuple{40, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_bytes_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{40, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_bytes_t, f::Symbol)
    r = Ref{z_owned_bytes_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_bytes_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_bytes_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_bytes_t
    data::NTuple{40, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_bytes_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{40, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_bytes_t, f::Symbol)
    r = Ref{z_loaned_bytes_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_bytes_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_bytes_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_bytes_loan(this_)
    ccall((:z_bytes_loan, libzenohc), Ptr{z_loaned_bytes_t}, (Ptr{z_owned_bytes_t},), this_)
end

struct z_owned_bytes_writer_t
    data::NTuple{64, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_bytes_writer_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{64, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_bytes_writer_t, f::Symbol)
    r = Ref{z_owned_bytes_writer_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_bytes_writer_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_bytes_writer_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_bytes_writer_t
    data::NTuple{64, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_bytes_writer_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{64, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_bytes_writer_t, f::Symbol)
    r = Ref{z_loaned_bytes_writer_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_bytes_writer_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_bytes_writer_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_bytes_writer_loan(this_)
    ccall((:z_bytes_writer_loan, libzenohc), Ptr{z_loaned_bytes_writer_t}, (Ptr{z_owned_bytes_writer_t},), this_)
end

struct z_owned_closure_hello_t
    _context::Ptr{Cvoid}
    _call::Ptr{Cvoid}
    _drop::Ptr{Cvoid}
end

struct z_loaned_closure_hello_t
    _0::NTuple{3, Csize_t}
end

function z_closure_hello_loan(closure)
    ccall((:z_closure_hello_loan, libzenohc), Ptr{z_loaned_closure_hello_t}, (Ptr{z_owned_closure_hello_t},), closure)
end

struct z_owned_closure_query_t
    _context::Ptr{Cvoid}
    _call::Ptr{Cvoid}
    _drop::Ptr{Cvoid}
end

struct z_loaned_closure_query_t
    _0::NTuple{3, Csize_t}
end

function z_closure_query_loan(closure)
    ccall((:z_closure_query_loan, libzenohc), Ptr{z_loaned_closure_query_t}, (Ptr{z_owned_closure_query_t},), closure)
end

struct z_owned_closure_reply_t
    _context::Ptr{Cvoid}
    _call::Ptr{Cvoid}
    _drop::Ptr{Cvoid}
end

struct z_loaned_closure_reply_t
    _0::NTuple{3, Csize_t}
end

function z_closure_reply_loan(closure)
    ccall((:z_closure_reply_loan, libzenohc), Ptr{z_loaned_closure_reply_t}, (Ptr{z_owned_closure_reply_t},), closure)
end

struct z_owned_closure_sample_t
    _context::Ptr{Cvoid}
    _call::Ptr{Cvoid}
    _drop::Ptr{Cvoid}
end

struct z_loaned_closure_sample_t
    _0::NTuple{3, Csize_t}
end

function z_closure_sample_loan(closure)
    ccall((:z_closure_sample_loan, libzenohc), Ptr{z_loaned_closure_sample_t}, (Ptr{z_owned_closure_sample_t},), closure)
end

struct z_owned_closure_zid_t
    _context::Ptr{Cvoid}
    _call::Ptr{Cvoid}
    _drop::Ptr{Cvoid}
end

struct z_loaned_closure_zid_t
    _0::NTuple{3, Csize_t}
end

function z_closure_zid_loan(closure)
    ccall((:z_closure_zid_loan, libzenohc), Ptr{z_loaned_closure_zid_t}, (Ptr{z_owned_closure_zid_t},), closure)
end

struct z_owned_condvar_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_condvar_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{8, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_condvar_t, f::Symbol)
    r = Ref{z_owned_condvar_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_condvar_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_condvar_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_condvar_t
    data::NTuple{4, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_condvar_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{4, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_condvar_t, f::Symbol)
    r = Ref{z_loaned_condvar_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_condvar_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_condvar_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_condvar_loan(this_)
    ccall((:z_condvar_loan, libzenohc), Ptr{z_loaned_condvar_t}, (Ptr{z_owned_condvar_t},), this_)
end

struct z_owned_config_t
    data::NTuple{1912, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_config_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{1912, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_config_t, f::Symbol)
    r = Ref{z_owned_config_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_config_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_config_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_config_t
    data::NTuple{1912, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_config_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{1912, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_config_t, f::Symbol)
    r = Ref{z_loaned_config_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_config_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_config_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_config_loan(this_)
    ccall((:z_config_loan, libzenohc), Ptr{z_loaned_config_t}, (Ptr{z_owned_config_t},), this_)
end

struct z_owned_encoding_t
    data::NTuple{48, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_encoding_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{48, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_encoding_t, f::Symbol)
    r = Ref{z_owned_encoding_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_encoding_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_encoding_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_encoding_t
    data::NTuple{48, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_encoding_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{48, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_encoding_t, f::Symbol)
    r = Ref{z_loaned_encoding_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_encoding_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_encoding_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_encoding_loan(this_)
    ccall((:z_encoding_loan, libzenohc), Ptr{z_loaned_encoding_t}, (Ptr{z_owned_encoding_t},), this_)
end

struct z_owned_fifo_handler_query_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_fifo_handler_query_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{8, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_fifo_handler_query_t, f::Symbol)
    r = Ref{z_owned_fifo_handler_query_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_fifo_handler_query_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_fifo_handler_query_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_fifo_handler_query_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_fifo_handler_query_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{8, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_fifo_handler_query_t, f::Symbol)
    r = Ref{z_loaned_fifo_handler_query_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_fifo_handler_query_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_fifo_handler_query_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_fifo_handler_query_loan(this_)
    ccall((:z_fifo_handler_query_loan, libzenohc), Ptr{z_loaned_fifo_handler_query_t}, (Ptr{z_owned_fifo_handler_query_t},), this_)
end

struct z_owned_fifo_handler_reply_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_fifo_handler_reply_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{8, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_fifo_handler_reply_t, f::Symbol)
    r = Ref{z_owned_fifo_handler_reply_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_fifo_handler_reply_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_fifo_handler_reply_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_fifo_handler_reply_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_fifo_handler_reply_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{8, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_fifo_handler_reply_t, f::Symbol)
    r = Ref{z_loaned_fifo_handler_reply_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_fifo_handler_reply_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_fifo_handler_reply_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_fifo_handler_reply_loan(this_)
    ccall((:z_fifo_handler_reply_loan, libzenohc), Ptr{z_loaned_fifo_handler_reply_t}, (Ptr{z_owned_fifo_handler_reply_t},), this_)
end

struct z_owned_fifo_handler_sample_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_fifo_handler_sample_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{8, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_fifo_handler_sample_t, f::Symbol)
    r = Ref{z_owned_fifo_handler_sample_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_fifo_handler_sample_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_fifo_handler_sample_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_fifo_handler_sample_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_fifo_handler_sample_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{8, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_fifo_handler_sample_t, f::Symbol)
    r = Ref{z_loaned_fifo_handler_sample_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_fifo_handler_sample_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_fifo_handler_sample_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_fifo_handler_sample_loan(this_)
    ccall((:z_fifo_handler_sample_loan, libzenohc), Ptr{z_loaned_fifo_handler_sample_t}, (Ptr{z_owned_fifo_handler_sample_t},), this_)
end

struct z_owned_hello_t
    data::NTuple{48, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_hello_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{48, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_hello_t, f::Symbol)
    r = Ref{z_owned_hello_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_hello_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_hello_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_hello_t
    data::NTuple{48, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_hello_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{48, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_hello_t, f::Symbol)
    r = Ref{z_loaned_hello_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_hello_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_hello_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_hello_loan(this_)
    ccall((:z_hello_loan, libzenohc), Ptr{z_loaned_hello_t}, (Ptr{z_owned_hello_t},), this_)
end

struct z_owned_keyexpr_t
    data::NTuple{32, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_keyexpr_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{32, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_keyexpr_t, f::Symbol)
    r = Ref{z_owned_keyexpr_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_keyexpr_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_keyexpr_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_keyexpr_t
    data::NTuple{32, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_keyexpr_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{32, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_keyexpr_t, f::Symbol)
    r = Ref{z_loaned_keyexpr_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_keyexpr_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_keyexpr_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_keyexpr_loan(this_)
    ccall((:z_keyexpr_loan, libzenohc), Ptr{z_loaned_keyexpr_t}, (Ptr{z_owned_keyexpr_t},), this_)
end

struct z_owned_liveliness_token_t
    data::NTuple{16, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_liveliness_token_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{16, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_liveliness_token_t, f::Symbol)
    r = Ref{z_owned_liveliness_token_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_liveliness_token_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_liveliness_token_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_liveliness_token_t
    data::NTuple{16, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_liveliness_token_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{16, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_liveliness_token_t, f::Symbol)
    r = Ref{z_loaned_liveliness_token_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_liveliness_token_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_liveliness_token_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_liveliness_token_loan(this_)
    ccall((:z_liveliness_token_loan, libzenohc), Ptr{z_loaned_liveliness_token_t}, (Ptr{z_owned_liveliness_token_t},), this_)
end

struct z_owned_publisher_t
    data::NTuple{104, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_publisher_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{104, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_publisher_t, f::Symbol)
    r = Ref{z_owned_publisher_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_publisher_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_publisher_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_publisher_t
    data::NTuple{104, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_publisher_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{104, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_publisher_t, f::Symbol)
    r = Ref{z_loaned_publisher_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_publisher_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_publisher_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_publisher_loan(this_)
    ccall((:z_publisher_loan, libzenohc), Ptr{z_loaned_publisher_t}, (Ptr{z_owned_publisher_t},), this_)
end

struct z_owned_query_t
    data::NTuple{144, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_query_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{144, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_query_t, f::Symbol)
    r = Ref{z_owned_query_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_query_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_query_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_query_t
    data::NTuple{144, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_query_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{144, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_query_t, f::Symbol)
    r = Ref{z_loaned_query_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_query_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_query_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_query_loan(this_)
    ccall((:z_query_loan, libzenohc), Ptr{z_loaned_query_t}, (Ptr{z_owned_query_t},), this_)
end

struct z_owned_queryable_t
    data::NTuple{16, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_queryable_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{16, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_queryable_t, f::Symbol)
    r = Ref{z_owned_queryable_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_queryable_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_queryable_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_queryable_t
    data::NTuple{16, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_queryable_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{16, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_queryable_t, f::Symbol)
    r = Ref{z_loaned_queryable_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_queryable_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_queryable_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_queryable_loan(this_)
    ccall((:z_queryable_loan, libzenohc), Ptr{z_loaned_queryable_t}, (Ptr{z_owned_queryable_t},), this_)
end

struct z_owned_reply_err_t
    data::NTuple{88, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_reply_err_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{88, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_reply_err_t, f::Symbol)
    r = Ref{z_owned_reply_err_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_reply_err_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_reply_err_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_reply_err_t
    data::NTuple{88, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_reply_err_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{88, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_reply_err_t, f::Symbol)
    r = Ref{z_loaned_reply_err_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_reply_err_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_reply_err_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_reply_err_loan(this_)
    ccall((:z_reply_err_loan, libzenohc), Ptr{z_loaned_reply_err_t}, (Ptr{z_owned_reply_err_t},), this_)
end

struct z_owned_reply_t
    data::NTuple{200, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_reply_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{200, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_reply_t, f::Symbol)
    r = Ref{z_owned_reply_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_reply_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_reply_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_reply_t
    data::NTuple{200, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_reply_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{200, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_reply_t, f::Symbol)
    r = Ref{z_loaned_reply_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_reply_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_reply_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_reply_loan(this_)
    ccall((:z_reply_loan, libzenohc), Ptr{z_loaned_reply_t}, (Ptr{z_owned_reply_t},), this_)
end

struct z_owned_ring_handler_query_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_ring_handler_query_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{8, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_ring_handler_query_t, f::Symbol)
    r = Ref{z_owned_ring_handler_query_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_ring_handler_query_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_ring_handler_query_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_ring_handler_query_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_ring_handler_query_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{8, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_ring_handler_query_t, f::Symbol)
    r = Ref{z_loaned_ring_handler_query_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_ring_handler_query_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_ring_handler_query_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_ring_handler_query_loan(this_)
    ccall((:z_ring_handler_query_loan, libzenohc), Ptr{z_loaned_ring_handler_query_t}, (Ptr{z_owned_ring_handler_query_t},), this_)
end

struct z_owned_ring_handler_reply_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_ring_handler_reply_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{8, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_ring_handler_reply_t, f::Symbol)
    r = Ref{z_owned_ring_handler_reply_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_ring_handler_reply_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_ring_handler_reply_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_ring_handler_reply_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_ring_handler_reply_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{8, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_ring_handler_reply_t, f::Symbol)
    r = Ref{z_loaned_ring_handler_reply_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_ring_handler_reply_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_ring_handler_reply_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_ring_handler_reply_loan(this_)
    ccall((:z_ring_handler_reply_loan, libzenohc), Ptr{z_loaned_ring_handler_reply_t}, (Ptr{z_owned_ring_handler_reply_t},), this_)
end

struct z_owned_ring_handler_sample_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_ring_handler_sample_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{8, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_ring_handler_sample_t, f::Symbol)
    r = Ref{z_owned_ring_handler_sample_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_ring_handler_sample_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_ring_handler_sample_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_ring_handler_sample_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_ring_handler_sample_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{8, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_ring_handler_sample_t, f::Symbol)
    r = Ref{z_loaned_ring_handler_sample_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_ring_handler_sample_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_ring_handler_sample_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_ring_handler_sample_loan(this_)
    ccall((:z_ring_handler_sample_loan, libzenohc), Ptr{z_loaned_ring_handler_sample_t}, (Ptr{z_owned_ring_handler_sample_t},), this_)
end

struct z_owned_sample_t
    data::NTuple{200, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_sample_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{200, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_sample_t, f::Symbol)
    r = Ref{z_owned_sample_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_sample_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_sample_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_sample_t
    data::NTuple{200, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_sample_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{200, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_sample_t, f::Symbol)
    r = Ref{z_loaned_sample_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_sample_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_sample_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_sample_loan(this_)
    ccall((:z_sample_loan, libzenohc), Ptr{z_loaned_sample_t}, (Ptr{z_owned_sample_t},), this_)
end

struct z_owned_session_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_session_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{8, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_session_t, f::Symbol)
    r = Ref{z_owned_session_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_session_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_session_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_session_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_session_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{8, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_session_t, f::Symbol)
    r = Ref{z_loaned_session_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_session_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_session_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_session_loan(this_)
    ccall((:z_session_loan, libzenohc), Ptr{z_loaned_session_t}, (Ptr{z_owned_session_t},), this_)
end

struct z_owned_slice_t
    data::NTuple{32, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_slice_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{32, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_slice_t, f::Symbol)
    r = Ref{z_owned_slice_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_slice_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_slice_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_slice_t
    data::NTuple{32, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_slice_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{32, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_slice_t, f::Symbol)
    r = Ref{z_loaned_slice_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_slice_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_slice_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_slice_loan(this_)
    ccall((:z_slice_loan, libzenohc), Ptr{z_loaned_slice_t}, (Ptr{z_owned_slice_t},), this_)
end

struct z_owned_string_array_t
    data::NTuple{24, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_string_array_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{24, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_string_array_t, f::Symbol)
    r = Ref{z_owned_string_array_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_string_array_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_string_array_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_string_array_t
    data::NTuple{24, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_string_array_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{24, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_string_array_t, f::Symbol)
    r = Ref{z_loaned_string_array_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_string_array_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_string_array_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_string_array_loan(this_)
    ccall((:z_string_array_loan, libzenohc), Ptr{z_loaned_string_array_t}, (Ptr{z_owned_string_array_t},), this_)
end

struct z_owned_string_t
    data::NTuple{32, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_string_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{32, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_string_t, f::Symbol)
    r = Ref{z_owned_string_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_string_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_string_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_string_t
    data::NTuple{32, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_string_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{32, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_string_t, f::Symbol)
    r = Ref{z_loaned_string_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_string_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_string_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_string_loan(this_)
    ccall((:z_string_loan, libzenohc), Ptr{z_loaned_string_t}, (Ptr{z_owned_string_t},), this_)
end

struct z_owned_subscriber_t
    data::NTuple{48, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_subscriber_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{48, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_subscriber_t, f::Symbol)
    r = Ref{z_owned_subscriber_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_subscriber_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_subscriber_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_subscriber_t
    data::NTuple{48, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_subscriber_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{48, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_subscriber_t, f::Symbol)
    r = Ref{z_loaned_subscriber_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_subscriber_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_subscriber_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_subscriber_loan(this_)
    ccall((:z_subscriber_loan, libzenohc), Ptr{z_loaned_subscriber_t}, (Ptr{z_owned_subscriber_t},), this_)
end

struct z_view_keyexpr_t
    data::NTuple{32, UInt8}
end

function Base.getproperty(x::Ptr{z_view_keyexpr_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{32, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_view_keyexpr_t, f::Symbol)
    r = Ref{z_view_keyexpr_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_view_keyexpr_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_view_keyexpr_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_view_keyexpr_loan(this_)
    ccall((:z_view_keyexpr_loan, libzenohc), Ptr{z_loaned_keyexpr_t}, (Ptr{z_view_keyexpr_t},), this_)
end

struct z_view_slice_t
    data::NTuple{32, UInt8}
end

function Base.getproperty(x::Ptr{z_view_slice_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{32, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_view_slice_t, f::Symbol)
    r = Ref{z_view_slice_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_view_slice_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_view_slice_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_view_slice_loan(this_)
    ccall((:z_view_slice_loan, libzenohc), Ptr{z_loaned_slice_t}, (Ptr{z_view_slice_t},), this_)
end

struct z_view_string_t
    data::NTuple{32, UInt8}
end

function Base.getproperty(x::Ptr{z_view_string_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{32, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_view_string_t, f::Symbol)
    r = Ref{z_view_string_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_view_string_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_view_string_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_view_string_loan(this_)
    ccall((:z_view_string_loan, libzenohc), Ptr{z_loaned_string_t}, (Ptr{z_view_string_t},), this_)
end

struct zc_owned_closure_log_t
    _context::Ptr{Cvoid}
    _call::Ptr{Cvoid}
    _drop::Ptr{Cvoid}
end

struct zc_loaned_closure_log_t
    _0::NTuple{3, Csize_t}
end

function zc_closure_log_loan(closure)
    ccall((:zc_closure_log_loan, libzenohc), Ptr{zc_loaned_closure_log_t}, (Ptr{zc_owned_closure_log_t},), closure)
end

struct ze_owned_serializer_t
    data::NTuple{64, UInt8}
end

function Base.getproperty(x::Ptr{ze_owned_serializer_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{64, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::ze_owned_serializer_t, f::Symbol)
    r = Ref{ze_owned_serializer_t}(x)
    ptr = Base.unsafe_convert(Ptr{ze_owned_serializer_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{ze_owned_serializer_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct ze_loaned_serializer_t
    data::NTuple{64, UInt8}
end

function Base.getproperty(x::Ptr{ze_loaned_serializer_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{64, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::ze_loaned_serializer_t, f::Symbol)
    r = Ref{ze_loaned_serializer_t}(x)
    ptr = Base.unsafe_convert(Ptr{ze_loaned_serializer_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{ze_loaned_serializer_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function ze_serializer_loan(this_)
    ccall((:ze_serializer_loan, libzenohc), Ptr{ze_loaned_serializer_t}, (Ptr{ze_owned_serializer_t},), this_)
end

function z_bytes_loan_mut(this_)
    ccall((:z_bytes_loan_mut, libzenohc), Ptr{z_loaned_bytes_t}, (Ptr{z_owned_bytes_t},), this_)
end

function z_bytes_writer_loan_mut(this_)
    ccall((:z_bytes_writer_loan_mut, libzenohc), Ptr{z_loaned_bytes_writer_t}, (Ptr{z_owned_bytes_writer_t},), this_)
end

function z_closure_hello_loan_mut(closure)
    ccall((:z_closure_hello_loan_mut, libzenohc), Ptr{z_loaned_closure_hello_t}, (Ptr{z_owned_closure_hello_t},), closure)
end

function z_closure_query_loan_mut(closure)
    ccall((:z_closure_query_loan_mut, libzenohc), Ptr{z_loaned_closure_query_t}, (Ptr{z_owned_closure_query_t},), closure)
end

function z_closure_reply_loan_mut(closure)
    ccall((:z_closure_reply_loan_mut, libzenohc), Ptr{z_loaned_closure_reply_t}, (Ptr{z_owned_closure_reply_t},), closure)
end

function z_closure_sample_loan_mut(closure)
    ccall((:z_closure_sample_loan_mut, libzenohc), Ptr{z_loaned_closure_sample_t}, (Ptr{z_owned_closure_sample_t},), closure)
end

function z_condvar_loan_mut(this_)
    ccall((:z_condvar_loan_mut, libzenohc), Ptr{z_loaned_condvar_t}, (Ptr{z_owned_condvar_t},), this_)
end

function z_config_loan_mut(this_)
    ccall((:z_config_loan_mut, libzenohc), Ptr{z_loaned_config_t}, (Ptr{z_owned_config_t},), this_)
end

function z_encoding_loan_mut(this_)
    ccall((:z_encoding_loan_mut, libzenohc), Ptr{z_loaned_encoding_t}, (Ptr{z_owned_encoding_t},), this_)
end

function z_hello_loan_mut(this_)
    ccall((:z_hello_loan_mut, libzenohc), Ptr{z_loaned_hello_t}, (Ptr{z_owned_hello_t},), this_)
end

struct z_owned_mutex_t
    data::NTuple{24, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_mutex_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{24, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_mutex_t, f::Symbol)
    r = Ref{z_owned_mutex_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_mutex_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_mutex_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_loaned_mutex_t
    data::NTuple{24, UInt8}
end

function Base.getproperty(x::Ptr{z_loaned_mutex_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{24, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_loaned_mutex_t, f::Symbol)
    r = Ref{z_loaned_mutex_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_loaned_mutex_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_loaned_mutex_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_mutex_loan_mut(this_)
    ccall((:z_mutex_loan_mut, libzenohc), Ptr{z_loaned_mutex_t}, (Ptr{z_owned_mutex_t},), this_)
end

function z_publisher_loan_mut(this_)
    ccall((:z_publisher_loan_mut, libzenohc), Ptr{z_loaned_publisher_t}, (Ptr{z_owned_publisher_t},), this_)
end

function z_query_loan_mut(this_)
    ccall((:z_query_loan_mut, libzenohc), Ptr{z_loaned_query_t}, (Ptr{z_owned_query_t},), this_)
end

function z_reply_err_loan_mut(this_)
    ccall((:z_reply_err_loan_mut, libzenohc), Ptr{z_loaned_reply_err_t}, (Ptr{z_owned_reply_err_t},), this_)
end

function z_reply_loan_mut(this_)
    ccall((:z_reply_loan_mut, libzenohc), Ptr{z_loaned_reply_t}, (Ptr{z_owned_reply_t},), this_)
end

function z_sample_loan_mut(this_)
    ccall((:z_sample_loan_mut, libzenohc), Ptr{z_loaned_sample_t}, (Ptr{z_owned_sample_t},), this_)
end

function z_session_loan_mut(this_)
    ccall((:z_session_loan_mut, libzenohc), Ptr{z_loaned_session_t}, (Ptr{z_owned_session_t},), this_)
end

function z_string_array_loan_mut(this_)
    ccall((:z_string_array_loan_mut, libzenohc), Ptr{z_loaned_string_array_t}, (Ptr{z_owned_string_array_t},), this_)
end

function ze_serializer_loan_mut(this_)
    ccall((:ze_serializer_loan_mut, libzenohc), Ptr{ze_loaned_serializer_t}, (Ptr{ze_owned_serializer_t},), this_)
end

struct z_moved_bytes_t
    data::NTuple{40, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_bytes_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_bytes_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_bytes_t, f::Symbol)
    r = Ref{z_moved_bytes_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_bytes_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_bytes_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_bytes_drop(this_)
    ccall((:z_bytes_drop, libzenohc), Cvoid, (Ptr{z_moved_bytes_t},), this_)
end

struct z_moved_bytes_writer_t
    data::NTuple{64, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_bytes_writer_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_bytes_writer_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_bytes_writer_t, f::Symbol)
    r = Ref{z_moved_bytes_writer_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_bytes_writer_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_bytes_writer_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_bytes_writer_drop(this_)
    ccall((:z_bytes_writer_drop, libzenohc), Cvoid, (Ptr{z_moved_bytes_writer_t},), this_)
end

struct z_moved_closure_hello_t
    _this::z_owned_closure_hello_t
end

function z_closure_hello_drop(this_)
    ccall((:z_closure_hello_drop, libzenohc), Cvoid, (Ptr{z_moved_closure_hello_t},), this_)
end

struct z_moved_closure_query_t
    _this::z_owned_closure_query_t
end

function z_closure_query_drop(closure_)
    ccall((:z_closure_query_drop, libzenohc), Cvoid, (Ptr{z_moved_closure_query_t},), closure_)
end

struct z_moved_closure_reply_t
    _this::z_owned_closure_reply_t
end

function z_closure_reply_drop(closure_)
    ccall((:z_closure_reply_drop, libzenohc), Cvoid, (Ptr{z_moved_closure_reply_t},), closure_)
end

struct z_moved_closure_sample_t
    _this::z_owned_closure_sample_t
end

function z_closure_sample_drop(closure_)
    ccall((:z_closure_sample_drop, libzenohc), Cvoid, (Ptr{z_moved_closure_sample_t},), closure_)
end

struct z_moved_closure_zid_t
    _this::z_owned_closure_zid_t
end

function z_closure_zid_drop(closure_)
    ccall((:z_closure_zid_drop, libzenohc), Cvoid, (Ptr{z_moved_closure_zid_t},), closure_)
end

struct z_moved_condvar_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_condvar_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_condvar_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_condvar_t, f::Symbol)
    r = Ref{z_moved_condvar_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_condvar_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_condvar_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_condvar_drop(this_)
    ccall((:z_condvar_drop, libzenohc), Cvoid, (Ptr{z_moved_condvar_t},), this_)
end

struct z_moved_config_t
    data::NTuple{1912, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_config_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_config_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_config_t, f::Symbol)
    r = Ref{z_moved_config_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_config_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_config_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_config_drop(this_)
    ccall((:z_config_drop, libzenohc), Cvoid, (Ptr{z_moved_config_t},), this_)
end

struct z_moved_encoding_t
    data::NTuple{48, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_encoding_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_encoding_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_encoding_t, f::Symbol)
    r = Ref{z_moved_encoding_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_encoding_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_encoding_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_encoding_drop(this_)
    ccall((:z_encoding_drop, libzenohc), Cvoid, (Ptr{z_moved_encoding_t},), this_)
end

struct z_moved_fifo_handler_query_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_fifo_handler_query_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_fifo_handler_query_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_fifo_handler_query_t, f::Symbol)
    r = Ref{z_moved_fifo_handler_query_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_fifo_handler_query_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_fifo_handler_query_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_fifo_handler_query_drop(this_)
    ccall((:z_fifo_handler_query_drop, libzenohc), Cvoid, (Ptr{z_moved_fifo_handler_query_t},), this_)
end

struct z_moved_fifo_handler_reply_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_fifo_handler_reply_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_fifo_handler_reply_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_fifo_handler_reply_t, f::Symbol)
    r = Ref{z_moved_fifo_handler_reply_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_fifo_handler_reply_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_fifo_handler_reply_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_fifo_handler_reply_drop(this_)
    ccall((:z_fifo_handler_reply_drop, libzenohc), Cvoid, (Ptr{z_moved_fifo_handler_reply_t},), this_)
end

struct z_moved_fifo_handler_sample_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_fifo_handler_sample_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_fifo_handler_sample_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_fifo_handler_sample_t, f::Symbol)
    r = Ref{z_moved_fifo_handler_sample_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_fifo_handler_sample_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_fifo_handler_sample_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_fifo_handler_sample_drop(this_)
    ccall((:z_fifo_handler_sample_drop, libzenohc), Cvoid, (Ptr{z_moved_fifo_handler_sample_t},), this_)
end

struct z_moved_hello_t
    data::NTuple{48, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_hello_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_hello_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_hello_t, f::Symbol)
    r = Ref{z_moved_hello_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_hello_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_hello_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_hello_drop(this_)
    ccall((:z_hello_drop, libzenohc), Cvoid, (Ptr{z_moved_hello_t},), this_)
end

struct z_moved_keyexpr_t
    data::NTuple{32, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_keyexpr_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_keyexpr_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_keyexpr_t, f::Symbol)
    r = Ref{z_moved_keyexpr_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_keyexpr_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_keyexpr_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_keyexpr_drop(this_)
    ccall((:z_keyexpr_drop, libzenohc), Cvoid, (Ptr{z_moved_keyexpr_t},), this_)
end

struct z_moved_liveliness_token_t
    data::NTuple{16, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_liveliness_token_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_liveliness_token_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_liveliness_token_t, f::Symbol)
    r = Ref{z_moved_liveliness_token_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_liveliness_token_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_liveliness_token_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_liveliness_token_drop(this_)
    ccall((:z_liveliness_token_drop, libzenohc), Cvoid, (Ptr{z_moved_liveliness_token_t},), this_)
end

struct z_moved_mutex_t
    data::NTuple{24, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_mutex_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_mutex_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_mutex_t, f::Symbol)
    r = Ref{z_moved_mutex_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_mutex_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_mutex_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_mutex_drop(this_)
    ccall((:z_mutex_drop, libzenohc), Cvoid, (Ptr{z_moved_mutex_t},), this_)
end

struct z_moved_publisher_t
    data::NTuple{104, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_publisher_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_publisher_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_publisher_t, f::Symbol)
    r = Ref{z_moved_publisher_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_publisher_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_publisher_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_publisher_drop(this_)
    ccall((:z_publisher_drop, libzenohc), Cvoid, (Ptr{z_moved_publisher_t},), this_)
end

struct z_moved_query_t
    data::NTuple{144, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_query_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_query_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_query_t, f::Symbol)
    r = Ref{z_moved_query_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_query_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_query_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_query_drop(this_)
    ccall((:z_query_drop, libzenohc), Cvoid, (Ptr{z_moved_query_t},), this_)
end

struct z_moved_queryable_t
    data::NTuple{16, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_queryable_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_queryable_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_queryable_t, f::Symbol)
    r = Ref{z_moved_queryable_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_queryable_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_queryable_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_queryable_drop(this_)
    ccall((:z_queryable_drop, libzenohc), Cvoid, (Ptr{z_moved_queryable_t},), this_)
end

struct z_moved_reply_t
    data::NTuple{200, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_reply_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_reply_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_reply_t, f::Symbol)
    r = Ref{z_moved_reply_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_reply_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_reply_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_reply_drop(this_)
    ccall((:z_reply_drop, libzenohc), Cvoid, (Ptr{z_moved_reply_t},), this_)
end

struct z_moved_reply_err_t
    data::NTuple{88, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_reply_err_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_reply_err_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_reply_err_t, f::Symbol)
    r = Ref{z_moved_reply_err_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_reply_err_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_reply_err_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_reply_err_drop(this_)
    ccall((:z_reply_err_drop, libzenohc), Cvoid, (Ptr{z_moved_reply_err_t},), this_)
end

struct z_moved_ring_handler_query_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_ring_handler_query_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_ring_handler_query_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_ring_handler_query_t, f::Symbol)
    r = Ref{z_moved_ring_handler_query_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_ring_handler_query_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_ring_handler_query_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_ring_handler_query_drop(this_)
    ccall((:z_ring_handler_query_drop, libzenohc), Cvoid, (Ptr{z_moved_ring_handler_query_t},), this_)
end

struct z_moved_ring_handler_reply_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_ring_handler_reply_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_ring_handler_reply_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_ring_handler_reply_t, f::Symbol)
    r = Ref{z_moved_ring_handler_reply_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_ring_handler_reply_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_ring_handler_reply_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_ring_handler_reply_drop(this_)
    ccall((:z_ring_handler_reply_drop, libzenohc), Cvoid, (Ptr{z_moved_ring_handler_reply_t},), this_)
end

struct z_moved_ring_handler_sample_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_ring_handler_sample_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_ring_handler_sample_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_ring_handler_sample_t, f::Symbol)
    r = Ref{z_moved_ring_handler_sample_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_ring_handler_sample_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_ring_handler_sample_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_ring_handler_sample_drop(this_)
    ccall((:z_ring_handler_sample_drop, libzenohc), Cvoid, (Ptr{z_moved_ring_handler_sample_t},), this_)
end

struct z_moved_sample_t
    data::NTuple{200, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_sample_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_sample_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_sample_t, f::Symbol)
    r = Ref{z_moved_sample_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_sample_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_sample_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_sample_drop(this_)
    ccall((:z_sample_drop, libzenohc), Cvoid, (Ptr{z_moved_sample_t},), this_)
end

struct z_moved_session_t
    data::NTuple{8, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_session_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_session_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_session_t, f::Symbol)
    r = Ref{z_moved_session_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_session_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_session_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_session_drop(this_)
    ccall((:z_session_drop, libzenohc), Cvoid, (Ptr{z_moved_session_t},), this_)
end

struct z_moved_slice_t
    data::NTuple{32, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_slice_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_slice_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_slice_t, f::Symbol)
    r = Ref{z_moved_slice_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_slice_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_slice_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_slice_drop(this_)
    ccall((:z_slice_drop, libzenohc), Cvoid, (Ptr{z_moved_slice_t},), this_)
end

struct z_moved_string_array_t
    data::NTuple{24, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_string_array_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_string_array_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_string_array_t, f::Symbol)
    r = Ref{z_moved_string_array_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_string_array_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_string_array_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_string_array_drop(this_)
    ccall((:z_string_array_drop, libzenohc), Cvoid, (Ptr{z_moved_string_array_t},), this_)
end

struct z_moved_string_t
    data::NTuple{32, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_string_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_string_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_string_t, f::Symbol)
    r = Ref{z_moved_string_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_string_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_string_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_string_drop(this_)
    ccall((:z_string_drop, libzenohc), Cvoid, (Ptr{z_moved_string_t},), this_)
end

struct z_moved_subscriber_t
    data::NTuple{48, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_subscriber_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_subscriber_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_subscriber_t, f::Symbol)
    r = Ref{z_moved_subscriber_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_subscriber_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_subscriber_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_subscriber_drop(this_)
    ccall((:z_subscriber_drop, libzenohc), Cvoid, (Ptr{z_moved_subscriber_t},), this_)
end

struct z_owned_task_t
    data::NTuple{24, UInt8}
end

function Base.getproperty(x::Ptr{z_owned_task_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{24, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_owned_task_t, f::Symbol)
    r = Ref{z_owned_task_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_owned_task_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_owned_task_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_moved_task_t
    data::NTuple{24, UInt8}
end

function Base.getproperty(x::Ptr{z_moved_task_t}, f::Symbol)
    f === :_this && return Ptr{z_owned_task_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_moved_task_t, f::Symbol)
    r = Ref{z_moved_task_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_moved_task_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_moved_task_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_task_drop(this_)
    ccall((:z_task_drop, libzenohc), Cvoid, (Ptr{z_moved_task_t},), this_)
end

struct zc_moved_closure_log_t
    _this::zc_owned_closure_log_t
end

function zc_closure_log_drop(closure_)
    ccall((:zc_closure_log_drop, libzenohc), Cvoid, (Ptr{zc_moved_closure_log_t},), closure_)
end

struct ze_moved_serializer_t
    data::NTuple{64, UInt8}
end

function Base.getproperty(x::Ptr{ze_moved_serializer_t}, f::Symbol)
    f === :_this && return Ptr{ze_owned_serializer_t}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::ze_moved_serializer_t, f::Symbol)
    r = Ref{ze_moved_serializer_t}(x)
    ptr = Base.unsafe_convert(Ptr{ze_moved_serializer_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{ze_moved_serializer_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function ze_serializer_drop(this_)
    ccall((:ze_serializer_drop, libzenohc), Cvoid, (Ptr{ze_moved_serializer_t},), this_)
end

function z_bytes_move(x)
    ccall((:z_bytes_move, libzenohc), Ptr{z_moved_bytes_t}, (Ptr{z_owned_bytes_t},), x)
end

function z_bytes_writer_move(x)
    ccall((:z_bytes_writer_move, libzenohc), Ptr{z_moved_bytes_writer_t}, (Ptr{z_owned_bytes_writer_t},), x)
end

function z_closure_hello_move(x)
    ccall((:z_closure_hello_move, libzenohc), Ptr{z_moved_closure_hello_t}, (Ptr{z_owned_closure_hello_t},), x)
end

function z_closure_query_move(x)
    ccall((:z_closure_query_move, libzenohc), Ptr{z_moved_closure_query_t}, (Ptr{z_owned_closure_query_t},), x)
end

function z_closure_reply_move(x)
    ccall((:z_closure_reply_move, libzenohc), Ptr{z_moved_closure_reply_t}, (Ptr{z_owned_closure_reply_t},), x)
end

function z_closure_sample_move(x)
    ccall((:z_closure_sample_move, libzenohc), Ptr{z_moved_closure_sample_t}, (Ptr{z_owned_closure_sample_t},), x)
end

function z_closure_zid_move(x)
    ccall((:z_closure_zid_move, libzenohc), Ptr{z_moved_closure_zid_t}, (Ptr{z_owned_closure_zid_t},), x)
end

function z_condvar_move(x)
    ccall((:z_condvar_move, libzenohc), Ptr{z_moved_condvar_t}, (Ptr{z_owned_condvar_t},), x)
end

function z_config_move(x)
    ccall((:z_config_move, libzenohc), Ptr{z_moved_config_t}, (Ptr{z_owned_config_t},), x)
end

function z_encoding_move(x)
    ccall((:z_encoding_move, libzenohc), Ptr{z_moved_encoding_t}, (Ptr{z_owned_encoding_t},), x)
end

function z_fifo_handler_query_move(x)
    ccall((:z_fifo_handler_query_move, libzenohc), Ptr{z_moved_fifo_handler_query_t}, (Ptr{z_owned_fifo_handler_query_t},), x)
end

function z_fifo_handler_reply_move(x)
    ccall((:z_fifo_handler_reply_move, libzenohc), Ptr{z_moved_fifo_handler_reply_t}, (Ptr{z_owned_fifo_handler_reply_t},), x)
end

function z_fifo_handler_sample_move(x)
    ccall((:z_fifo_handler_sample_move, libzenohc), Ptr{z_moved_fifo_handler_sample_t}, (Ptr{z_owned_fifo_handler_sample_t},), x)
end

function z_hello_move(x)
    ccall((:z_hello_move, libzenohc), Ptr{z_moved_hello_t}, (Ptr{z_owned_hello_t},), x)
end

function z_keyexpr_move(x)
    ccall((:z_keyexpr_move, libzenohc), Ptr{z_moved_keyexpr_t}, (Ptr{z_owned_keyexpr_t},), x)
end

function z_liveliness_token_move(x)
    ccall((:z_liveliness_token_move, libzenohc), Ptr{z_moved_liveliness_token_t}, (Ptr{z_owned_liveliness_token_t},), x)
end

function z_mutex_move(x)
    ccall((:z_mutex_move, libzenohc), Ptr{z_moved_mutex_t}, (Ptr{z_owned_mutex_t},), x)
end

function z_publisher_move(x)
    ccall((:z_publisher_move, libzenohc), Ptr{z_moved_publisher_t}, (Ptr{z_owned_publisher_t},), x)
end

function z_query_move(x)
    ccall((:z_query_move, libzenohc), Ptr{z_moved_query_t}, (Ptr{z_owned_query_t},), x)
end

function z_queryable_move(x)
    ccall((:z_queryable_move, libzenohc), Ptr{z_moved_queryable_t}, (Ptr{z_owned_queryable_t},), x)
end

function z_reply_move(x)
    ccall((:z_reply_move, libzenohc), Ptr{z_moved_reply_t}, (Ptr{z_owned_reply_t},), x)
end

function z_reply_err_move(x)
    ccall((:z_reply_err_move, libzenohc), Ptr{z_moved_reply_err_t}, (Ptr{z_owned_reply_err_t},), x)
end

function z_ring_handler_query_move(x)
    ccall((:z_ring_handler_query_move, libzenohc), Ptr{z_moved_ring_handler_query_t}, (Ptr{z_owned_ring_handler_query_t},), x)
end

function z_ring_handler_reply_move(x)
    ccall((:z_ring_handler_reply_move, libzenohc), Ptr{z_moved_ring_handler_reply_t}, (Ptr{z_owned_ring_handler_reply_t},), x)
end

function z_ring_handler_sample_move(x)
    ccall((:z_ring_handler_sample_move, libzenohc), Ptr{z_moved_ring_handler_sample_t}, (Ptr{z_owned_ring_handler_sample_t},), x)
end

function z_sample_move(x)
    ccall((:z_sample_move, libzenohc), Ptr{z_moved_sample_t}, (Ptr{z_owned_sample_t},), x)
end

function z_session_move(x)
    ccall((:z_session_move, libzenohc), Ptr{z_moved_session_t}, (Ptr{z_owned_session_t},), x)
end

function z_slice_move(x)
    ccall((:z_slice_move, libzenohc), Ptr{z_moved_slice_t}, (Ptr{z_owned_slice_t},), x)
end

function z_string_array_move(x)
    ccall((:z_string_array_move, libzenohc), Ptr{z_moved_string_array_t}, (Ptr{z_owned_string_array_t},), x)
end

function z_string_move(x)
    ccall((:z_string_move, libzenohc), Ptr{z_moved_string_t}, (Ptr{z_owned_string_t},), x)
end

function z_subscriber_move(x)
    ccall((:z_subscriber_move, libzenohc), Ptr{z_moved_subscriber_t}, (Ptr{z_owned_subscriber_t},), x)
end

function z_task_move(x)
    ccall((:z_task_move, libzenohc), Ptr{z_moved_task_t}, (Ptr{z_owned_task_t},), x)
end

function zc_closure_log_move(x)
    ccall((:zc_closure_log_move, libzenohc), Ptr{zc_moved_closure_log_t}, (Ptr{zc_owned_closure_log_t},), x)
end

function ze_serializer_move(x)
    ccall((:ze_serializer_move, libzenohc), Ptr{ze_moved_serializer_t}, (Ptr{ze_owned_serializer_t},), x)
end

function z_internal_bytes_null(this_)
    ccall((:z_internal_bytes_null, libzenohc), Cvoid, (Ptr{z_owned_bytes_t},), this_)
end

function z_internal_bytes_writer_null(this_)
    ccall((:z_internal_bytes_writer_null, libzenohc), Cvoid, (Ptr{z_owned_bytes_writer_t},), this_)
end

function z_internal_closure_hello_null(this_)
    ccall((:z_internal_closure_hello_null, libzenohc), Cvoid, (Ptr{z_owned_closure_hello_t},), this_)
end

function z_internal_closure_query_null(this_)
    ccall((:z_internal_closure_query_null, libzenohc), Cvoid, (Ptr{z_owned_closure_query_t},), this_)
end

function z_internal_closure_reply_null(this_)
    ccall((:z_internal_closure_reply_null, libzenohc), Cvoid, (Ptr{z_owned_closure_reply_t},), this_)
end

function z_internal_closure_sample_null(this_)
    ccall((:z_internal_closure_sample_null, libzenohc), Cvoid, (Ptr{z_owned_closure_sample_t},), this_)
end

function z_internal_closure_zid_null(this_)
    ccall((:z_internal_closure_zid_null, libzenohc), Cvoid, (Ptr{z_owned_closure_zid_t},), this_)
end

function z_internal_condvar_null(this_)
    ccall((:z_internal_condvar_null, libzenohc), Cvoid, (Ptr{z_owned_condvar_t},), this_)
end

function z_internal_config_null(this_)
    ccall((:z_internal_config_null, libzenohc), Cvoid, (Ptr{z_owned_config_t},), this_)
end

function z_internal_encoding_null(this_)
    ccall((:z_internal_encoding_null, libzenohc), Cvoid, (Ptr{z_owned_encoding_t},), this_)
end

function z_internal_fifo_handler_query_null(this_)
    ccall((:z_internal_fifo_handler_query_null, libzenohc), Cvoid, (Ptr{z_owned_fifo_handler_query_t},), this_)
end

function z_internal_fifo_handler_reply_null(this_)
    ccall((:z_internal_fifo_handler_reply_null, libzenohc), Cvoid, (Ptr{z_owned_fifo_handler_reply_t},), this_)
end

function z_internal_fifo_handler_sample_null(this_)
    ccall((:z_internal_fifo_handler_sample_null, libzenohc), Cvoid, (Ptr{z_owned_fifo_handler_sample_t},), this_)
end

function z_internal_hello_null(this_)
    ccall((:z_internal_hello_null, libzenohc), Cvoid, (Ptr{z_owned_hello_t},), this_)
end

function z_internal_keyexpr_null(this_)
    ccall((:z_internal_keyexpr_null, libzenohc), Cvoid, (Ptr{z_owned_keyexpr_t},), this_)
end

function z_internal_liveliness_token_null(this_)
    ccall((:z_internal_liveliness_token_null, libzenohc), Cvoid, (Ptr{z_owned_liveliness_token_t},), this_)
end

function z_internal_mutex_null(this_)
    ccall((:z_internal_mutex_null, libzenohc), Cvoid, (Ptr{z_owned_mutex_t},), this_)
end

function z_internal_publisher_null(this_)
    ccall((:z_internal_publisher_null, libzenohc), Cvoid, (Ptr{z_owned_publisher_t},), this_)
end

function z_internal_query_null(this_)
    ccall((:z_internal_query_null, libzenohc), Cvoid, (Ptr{z_owned_query_t},), this_)
end

function z_internal_queryable_null(this_)
    ccall((:z_internal_queryable_null, libzenohc), Cvoid, (Ptr{z_owned_queryable_t},), this_)
end

function z_internal_reply_err_null(this_)
    ccall((:z_internal_reply_err_null, libzenohc), Cvoid, (Ptr{z_owned_reply_err_t},), this_)
end

function z_internal_reply_null(this_)
    ccall((:z_internal_reply_null, libzenohc), Cvoid, (Ptr{z_owned_reply_t},), this_)
end

function z_internal_ring_handler_query_null(this_)
    ccall((:z_internal_ring_handler_query_null, libzenohc), Cvoid, (Ptr{z_owned_ring_handler_query_t},), this_)
end

function z_internal_ring_handler_reply_null(this_)
    ccall((:z_internal_ring_handler_reply_null, libzenohc), Cvoid, (Ptr{z_owned_ring_handler_reply_t},), this_)
end

function z_internal_ring_handler_sample_null(this_)
    ccall((:z_internal_ring_handler_sample_null, libzenohc), Cvoid, (Ptr{z_owned_ring_handler_sample_t},), this_)
end

function z_internal_sample_null(this_)
    ccall((:z_internal_sample_null, libzenohc), Cvoid, (Ptr{z_owned_sample_t},), this_)
end

function z_internal_session_null(this_)
    ccall((:z_internal_session_null, libzenohc), Cvoid, (Ptr{z_owned_session_t},), this_)
end

function z_internal_slice_null(this_)
    ccall((:z_internal_slice_null, libzenohc), Cvoid, (Ptr{z_owned_slice_t},), this_)
end

function z_internal_string_array_null(this_)
    ccall((:z_internal_string_array_null, libzenohc), Cvoid, (Ptr{z_owned_string_array_t},), this_)
end

function z_internal_string_null(this_)
    ccall((:z_internal_string_null, libzenohc), Cvoid, (Ptr{z_owned_string_t},), this_)
end

function z_internal_subscriber_null(this_)
    ccall((:z_internal_subscriber_null, libzenohc), Cvoid, (Ptr{z_owned_subscriber_t},), this_)
end

function z_internal_task_null(this_)
    ccall((:z_internal_task_null, libzenohc), Cvoid, (Ptr{z_owned_task_t},), this_)
end

function zc_internal_closure_log_null(this_)
    ccall((:zc_internal_closure_log_null, libzenohc), Cvoid, (Ptr{zc_owned_closure_log_t},), this_)
end

function ze_internal_serializer_null(this_)
    ccall((:ze_internal_serializer_null, libzenohc), Cvoid, (Ptr{ze_owned_serializer_t},), this_)
end

function z_bytes_take(this_, x)
    ccall((:z_bytes_take, libzenohc), Cvoid, (Ptr{z_owned_bytes_t}, Ptr{z_moved_bytes_t}), this_, x)
end

function z_bytes_writer_take(this_, x)
    ccall((:z_bytes_writer_take, libzenohc), Cvoid, (Ptr{z_owned_bytes_writer_t}, Ptr{z_moved_bytes_writer_t}), this_, x)
end

function z_closure_hello_take(this_, x)
    ccall((:z_closure_hello_take, libzenohc), Cvoid, (Ptr{z_owned_closure_hello_t}, Ptr{z_moved_closure_hello_t}), this_, x)
end

function z_closure_query_take(closure_, x)
    ccall((:z_closure_query_take, libzenohc), Cvoid, (Ptr{z_owned_closure_query_t}, Ptr{z_moved_closure_query_t}), closure_, x)
end

function z_closure_reply_take(closure_, x)
    ccall((:z_closure_reply_take, libzenohc), Cvoid, (Ptr{z_owned_closure_reply_t}, Ptr{z_moved_closure_reply_t}), closure_, x)
end

function z_closure_sample_take(closure_, x)
    ccall((:z_closure_sample_take, libzenohc), Cvoid, (Ptr{z_owned_closure_sample_t}, Ptr{z_moved_closure_sample_t}), closure_, x)
end

function z_closure_zid_take(closure_, x)
    ccall((:z_closure_zid_take, libzenohc), Cvoid, (Ptr{z_owned_closure_zid_t}, Ptr{z_moved_closure_zid_t}), closure_, x)
end

function z_condvar_take(this_, x)
    ccall((:z_condvar_take, libzenohc), Cvoid, (Ptr{z_owned_condvar_t}, Ptr{z_moved_condvar_t}), this_, x)
end

function z_config_take(this_, x)
    ccall((:z_config_take, libzenohc), Cvoid, (Ptr{z_owned_config_t}, Ptr{z_moved_config_t}), this_, x)
end

function z_encoding_take(this_, x)
    ccall((:z_encoding_take, libzenohc), Cvoid, (Ptr{z_owned_encoding_t}, Ptr{z_moved_encoding_t}), this_, x)
end

function z_fifo_handler_query_take(this_, x)
    ccall((:z_fifo_handler_query_take, libzenohc), Cvoid, (Ptr{z_owned_fifo_handler_query_t}, Ptr{z_moved_fifo_handler_query_t}), this_, x)
end

function z_fifo_handler_reply_take(this_, x)
    ccall((:z_fifo_handler_reply_take, libzenohc), Cvoid, (Ptr{z_owned_fifo_handler_reply_t}, Ptr{z_moved_fifo_handler_reply_t}), this_, x)
end

function z_fifo_handler_sample_take(this_, x)
    ccall((:z_fifo_handler_sample_take, libzenohc), Cvoid, (Ptr{z_owned_fifo_handler_sample_t}, Ptr{z_moved_fifo_handler_sample_t}), this_, x)
end

function z_hello_take(this_, x)
    ccall((:z_hello_take, libzenohc), Cvoid, (Ptr{z_owned_hello_t}, Ptr{z_moved_hello_t}), this_, x)
end

function z_keyexpr_take(this_, x)
    ccall((:z_keyexpr_take, libzenohc), Cvoid, (Ptr{z_owned_keyexpr_t}, Ptr{z_moved_keyexpr_t}), this_, x)
end

function z_liveliness_token_take(this_, x)
    ccall((:z_liveliness_token_take, libzenohc), Cvoid, (Ptr{z_owned_liveliness_token_t}, Ptr{z_moved_liveliness_token_t}), this_, x)
end

function z_mutex_take(this_, x)
    ccall((:z_mutex_take, libzenohc), Cvoid, (Ptr{z_owned_mutex_t}, Ptr{z_moved_mutex_t}), this_, x)
end

function z_publisher_take(this_, x)
    ccall((:z_publisher_take, libzenohc), Cvoid, (Ptr{z_owned_publisher_t}, Ptr{z_moved_publisher_t}), this_, x)
end

function z_query_take(this_, x)
    ccall((:z_query_take, libzenohc), Cvoid, (Ptr{z_owned_query_t}, Ptr{z_moved_query_t}), this_, x)
end

function z_queryable_take(this_, x)
    ccall((:z_queryable_take, libzenohc), Cvoid, (Ptr{z_owned_queryable_t}, Ptr{z_moved_queryable_t}), this_, x)
end

function z_reply_take(this_, x)
    ccall((:z_reply_take, libzenohc), Cvoid, (Ptr{z_owned_reply_t}, Ptr{z_moved_reply_t}), this_, x)
end

function z_reply_err_take(this_, x)
    ccall((:z_reply_err_take, libzenohc), Cvoid, (Ptr{z_owned_reply_err_t}, Ptr{z_moved_reply_err_t}), this_, x)
end

function z_ring_handler_query_take(this_, x)
    ccall((:z_ring_handler_query_take, libzenohc), Cvoid, (Ptr{z_owned_ring_handler_query_t}, Ptr{z_moved_ring_handler_query_t}), this_, x)
end

function z_ring_handler_reply_take(this_, x)
    ccall((:z_ring_handler_reply_take, libzenohc), Cvoid, (Ptr{z_owned_ring_handler_reply_t}, Ptr{z_moved_ring_handler_reply_t}), this_, x)
end

function z_ring_handler_sample_take(this_, x)
    ccall((:z_ring_handler_sample_take, libzenohc), Cvoid, (Ptr{z_owned_ring_handler_sample_t}, Ptr{z_moved_ring_handler_sample_t}), this_, x)
end

function z_sample_take(this_, x)
    ccall((:z_sample_take, libzenohc), Cvoid, (Ptr{z_owned_sample_t}, Ptr{z_moved_sample_t}), this_, x)
end

function z_session_take(this_, x)
    ccall((:z_session_take, libzenohc), Cvoid, (Ptr{z_owned_session_t}, Ptr{z_moved_session_t}), this_, x)
end

function z_slice_take(this_, x)
    ccall((:z_slice_take, libzenohc), Cvoid, (Ptr{z_owned_slice_t}, Ptr{z_moved_slice_t}), this_, x)
end

function z_string_array_take(this_, x)
    ccall((:z_string_array_take, libzenohc), Cvoid, (Ptr{z_owned_string_array_t}, Ptr{z_moved_string_array_t}), this_, x)
end

function z_string_take(this_, x)
    ccall((:z_string_take, libzenohc), Cvoid, (Ptr{z_owned_string_t}, Ptr{z_moved_string_t}), this_, x)
end

function z_subscriber_take(this_, x)
    ccall((:z_subscriber_take, libzenohc), Cvoid, (Ptr{z_owned_subscriber_t}, Ptr{z_moved_subscriber_t}), this_, x)
end

function z_task_take(this_, x)
    ccall((:z_task_take, libzenohc), Cvoid, (Ptr{z_owned_task_t}, Ptr{z_moved_task_t}), this_, x)
end

function zc_closure_log_take(closure_, x)
    ccall((:zc_closure_log_take, libzenohc), Cvoid, (Ptr{zc_owned_closure_log_t}, Ptr{zc_moved_closure_log_t}), closure_, x)
end

function ze_serializer_take(this_, x)
    ccall((:ze_serializer_take, libzenohc), Cvoid, (Ptr{ze_owned_serializer_t}, Ptr{ze_moved_serializer_t}), this_, x)
end

function z_hello_take_from_loaned(dst, src)
    ccall((:z_hello_take_from_loaned, libzenohc), Cvoid, (Ptr{z_owned_hello_t}, Ptr{z_loaned_hello_t}), dst, src)
end

function z_query_take_from_loaned(dst, src)
    ccall((:z_query_take_from_loaned, libzenohc), Cvoid, (Ptr{z_owned_query_t}, Ptr{z_loaned_query_t}), dst, src)
end

function z_reply_take_from_loaned(dst, src)
    ccall((:z_reply_take_from_loaned, libzenohc), Cvoid, (Ptr{z_owned_reply_t}, Ptr{z_loaned_reply_t}), dst, src)
end

function z_sample_take_from_loaned(dst, src)
    ccall((:z_sample_take_from_loaned, libzenohc), Cvoid, (Ptr{z_owned_sample_t}, Ptr{z_loaned_sample_t}), dst, src)
end

function z_internal_bytes_check(this_)
    ccall((:z_internal_bytes_check, libzenohc), Bool, (Ptr{z_owned_bytes_t},), this_)
end

function z_internal_bytes_writer_check(this_)
    ccall((:z_internal_bytes_writer_check, libzenohc), Bool, (Ptr{z_owned_bytes_writer_t},), this_)
end

function z_internal_closure_hello_check(this_)
    ccall((:z_internal_closure_hello_check, libzenohc), Bool, (Ptr{z_owned_closure_hello_t},), this_)
end

function z_internal_closure_query_check(this_)
    ccall((:z_internal_closure_query_check, libzenohc), Bool, (Ptr{z_owned_closure_query_t},), this_)
end

function z_internal_closure_reply_check(this_)
    ccall((:z_internal_closure_reply_check, libzenohc), Bool, (Ptr{z_owned_closure_reply_t},), this_)
end

function z_internal_closure_sample_check(this_)
    ccall((:z_internal_closure_sample_check, libzenohc), Bool, (Ptr{z_owned_closure_sample_t},), this_)
end

function z_internal_closure_zid_check(this_)
    ccall((:z_internal_closure_zid_check, libzenohc), Bool, (Ptr{z_owned_closure_zid_t},), this_)
end

function z_internal_condvar_check(this_)
    ccall((:z_internal_condvar_check, libzenohc), Bool, (Ptr{z_owned_condvar_t},), this_)
end

function z_internal_config_check(this_)
    ccall((:z_internal_config_check, libzenohc), Bool, (Ptr{z_owned_config_t},), this_)
end

function z_internal_encoding_check(this_)
    ccall((:z_internal_encoding_check, libzenohc), Bool, (Ptr{z_owned_encoding_t},), this_)
end

function z_internal_fifo_handler_query_check(this_)
    ccall((:z_internal_fifo_handler_query_check, libzenohc), Bool, (Ptr{z_owned_fifo_handler_query_t},), this_)
end

function z_internal_fifo_handler_reply_check(this_)
    ccall((:z_internal_fifo_handler_reply_check, libzenohc), Bool, (Ptr{z_owned_fifo_handler_reply_t},), this_)
end

function z_internal_fifo_handler_sample_check(this_)
    ccall((:z_internal_fifo_handler_sample_check, libzenohc), Bool, (Ptr{z_owned_fifo_handler_sample_t},), this_)
end

function z_internal_hello_check(this_)
    ccall((:z_internal_hello_check, libzenohc), Bool, (Ptr{z_owned_hello_t},), this_)
end

function z_internal_keyexpr_check(this_)
    ccall((:z_internal_keyexpr_check, libzenohc), Bool, (Ptr{z_owned_keyexpr_t},), this_)
end

function z_internal_liveliness_token_check(this_)
    ccall((:z_internal_liveliness_token_check, libzenohc), Bool, (Ptr{z_owned_liveliness_token_t},), this_)
end

function z_internal_mutex_check(this_)
    ccall((:z_internal_mutex_check, libzenohc), Bool, (Ptr{z_owned_mutex_t},), this_)
end

function z_internal_publisher_check(this_)
    ccall((:z_internal_publisher_check, libzenohc), Bool, (Ptr{z_owned_publisher_t},), this_)
end

function z_internal_query_check(query)
    ccall((:z_internal_query_check, libzenohc), Bool, (Ptr{z_owned_query_t},), query)
end

function z_internal_queryable_check(this_)
    ccall((:z_internal_queryable_check, libzenohc), Bool, (Ptr{z_owned_queryable_t},), this_)
end

function z_internal_reply_check(this_)
    ccall((:z_internal_reply_check, libzenohc), Bool, (Ptr{z_owned_reply_t},), this_)
end

function z_internal_reply_err_check(this_)
    ccall((:z_internal_reply_err_check, libzenohc), Bool, (Ptr{z_owned_reply_err_t},), this_)
end

function z_internal_ring_handler_query_check(this_)
    ccall((:z_internal_ring_handler_query_check, libzenohc), Bool, (Ptr{z_owned_ring_handler_query_t},), this_)
end

function z_internal_ring_handler_reply_check(this_)
    ccall((:z_internal_ring_handler_reply_check, libzenohc), Bool, (Ptr{z_owned_ring_handler_reply_t},), this_)
end

function z_internal_ring_handler_sample_check(this_)
    ccall((:z_internal_ring_handler_sample_check, libzenohc), Bool, (Ptr{z_owned_ring_handler_sample_t},), this_)
end

function z_internal_sample_check(this_)
    ccall((:z_internal_sample_check, libzenohc), Bool, (Ptr{z_owned_sample_t},), this_)
end

function z_internal_session_check(this_)
    ccall((:z_internal_session_check, libzenohc), Bool, (Ptr{z_owned_session_t},), this_)
end

function z_internal_slice_check(this_)
    ccall((:z_internal_slice_check, libzenohc), Bool, (Ptr{z_owned_slice_t},), this_)
end

function z_internal_string_array_check(this_)
    ccall((:z_internal_string_array_check, libzenohc), Bool, (Ptr{z_owned_string_array_t},), this_)
end

function z_internal_string_check(this_)
    ccall((:z_internal_string_check, libzenohc), Bool, (Ptr{z_owned_string_t},), this_)
end

function z_internal_subscriber_check(this_)
    ccall((:z_internal_subscriber_check, libzenohc), Bool, (Ptr{z_owned_subscriber_t},), this_)
end

function z_internal_task_check(this_)
    ccall((:z_internal_task_check, libzenohc), Bool, (Ptr{z_owned_task_t},), this_)
end

function zc_internal_closure_log_check(this_)
    ccall((:zc_internal_closure_log_check, libzenohc), Bool, (Ptr{zc_owned_closure_log_t},), this_)
end

function ze_internal_serializer_check(this_)
    ccall((:ze_internal_serializer_check, libzenohc), Bool, (Ptr{ze_owned_serializer_t},), this_)
end

function z_closure_hello_call(closure, hello)
    ccall((:z_closure_hello_call, libzenohc), Cvoid, (Ptr{z_loaned_closure_hello_t}, Ptr{z_loaned_hello_t}), closure, hello)
end

function z_closure_query_call(closure, query)
    ccall((:z_closure_query_call, libzenohc), Cvoid, (Ptr{z_loaned_closure_query_t}, Ptr{z_loaned_query_t}), closure, query)
end

function z_closure_reply_call(closure, reply)
    ccall((:z_closure_reply_call, libzenohc), Cvoid, (Ptr{z_loaned_closure_reply_t}, Ptr{z_loaned_reply_t}), closure, reply)
end

function z_closure_sample_call(closure, sample)
    ccall((:z_closure_sample_call, libzenohc), Cvoid, (Ptr{z_loaned_closure_sample_t}, Ptr{z_loaned_sample_t}), closure, sample)
end

struct z_id_t
    data::NTuple{16, UInt8}
end

function Base.getproperty(x::Ptr{z_id_t}, f::Symbol)
    f === :id && return Ptr{NTuple{16, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_id_t, f::Symbol)
    r = Ref{z_id_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_id_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_id_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function z_closure_zid_call(closure, z_id)
    ccall((:z_closure_zid_call, libzenohc), Cvoid, (Ptr{z_loaned_closure_zid_t}, Ptr{z_id_t}), closure, z_id)
end

function z_closure_hello(this_, call, drop, context)
    ccall((:z_closure_hello, libzenohc), Cvoid, (Ptr{z_owned_closure_hello_t}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), this_, call, drop, context)
end

function z_closure_query(this_, call, drop, context)
    ccall((:z_closure_query, libzenohc), Cvoid, (Ptr{z_owned_closure_query_t}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), this_, call, drop, context)
end

function z_closure_reply(this_, call, drop, context)
    ccall((:z_closure_reply, libzenohc), Cvoid, (Ptr{z_owned_closure_reply_t}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), this_, call, drop, context)
end

function z_closure_sample(this_, call, drop, context)
    ccall((:z_closure_sample, libzenohc), Cvoid, (Ptr{z_owned_closure_sample_t}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), this_, call, drop, context)
end

function z_closure_zid(this_, call, drop, context)
    ccall((:z_closure_zid, libzenohc), Cvoid, (Ptr{z_owned_closure_zid_t}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), this_, call, drop, context)
end

function zc_closure_log(this_, call, drop, context)
    ccall((:zc_closure_log, libzenohc), Cvoid, (Ptr{zc_owned_closure_log_t}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), this_, call, drop, context)
end

const z_result_t = Int8

function z_fifo_handler_query_try_recv(this_, query)
    ccall((:z_fifo_handler_query_try_recv, libzenohc), z_result_t, (Ptr{z_loaned_fifo_handler_query_t}, Ptr{z_owned_query_t}), this_, query)
end

function z_fifo_handler_reply_try_recv(this_, reply)
    ccall((:z_fifo_handler_reply_try_recv, libzenohc), z_result_t, (Ptr{z_loaned_fifo_handler_reply_t}, Ptr{z_owned_reply_t}), this_, reply)
end

function z_fifo_handler_sample_try_recv(this_, sample)
    ccall((:z_fifo_handler_sample_try_recv, libzenohc), z_result_t, (Ptr{z_loaned_fifo_handler_sample_t}, Ptr{z_owned_sample_t}), this_, sample)
end

function z_ring_handler_query_try_recv(this_, query)
    ccall((:z_ring_handler_query_try_recv, libzenohc), z_result_t, (Ptr{z_loaned_ring_handler_query_t}, Ptr{z_owned_query_t}), this_, query)
end

function z_ring_handler_reply_try_recv(this_, reply)
    ccall((:z_ring_handler_reply_try_recv, libzenohc), z_result_t, (Ptr{z_loaned_ring_handler_reply_t}, Ptr{z_owned_reply_t}), this_, reply)
end

function z_ring_handler_sample_try_recv(this_, sample)
    ccall((:z_ring_handler_sample_try_recv, libzenohc), z_result_t, (Ptr{z_loaned_ring_handler_sample_t}, Ptr{z_owned_sample_t}), this_, sample)
end

function z_fifo_handler_query_recv(this_, query)
    ccall((:z_fifo_handler_query_recv, libzenohc), z_result_t, (Ptr{z_loaned_fifo_handler_query_t}, Ptr{z_owned_query_t}), this_, query)
end

function z_fifo_handler_reply_recv(this_, reply)
    ccall((:z_fifo_handler_reply_recv, libzenohc), z_result_t, (Ptr{z_loaned_fifo_handler_reply_t}, Ptr{z_owned_reply_t}), this_, reply)
end

function z_fifo_handler_sample_recv(this_, sample)
    ccall((:z_fifo_handler_sample_recv, libzenohc), z_result_t, (Ptr{z_loaned_fifo_handler_sample_t}, Ptr{z_owned_sample_t}), this_, sample)
end

function z_ring_handler_query_recv(this_, query)
    ccall((:z_ring_handler_query_recv, libzenohc), z_result_t, (Ptr{z_loaned_ring_handler_query_t}, Ptr{z_owned_query_t}), this_, query)
end

function z_ring_handler_reply_recv(this_, reply)
    ccall((:z_ring_handler_reply_recv, libzenohc), z_result_t, (Ptr{z_loaned_ring_handler_reply_t}, Ptr{z_owned_reply_t}), this_, reply)
end

function z_ring_handler_sample_recv(this_, sample)
    ccall((:z_ring_handler_sample_recv, libzenohc), z_result_t, (Ptr{z_loaned_ring_handler_sample_t}, Ptr{z_owned_sample_t}), this_, sample)
end

function z_bytes_clone(dst, this_)
    ccall((:z_bytes_clone, libzenohc), Cvoid, (Ptr{z_owned_bytes_t}, Ptr{z_loaned_bytes_t}), dst, this_)
end

function z_config_clone(dst, this_)
    ccall((:z_config_clone, libzenohc), Cvoid, (Ptr{z_owned_config_t}, Ptr{z_loaned_config_t}), dst, this_)
end

function z_encoding_clone(dst, this_)
    ccall((:z_encoding_clone, libzenohc), Cvoid, (Ptr{z_owned_encoding_t}, Ptr{z_loaned_encoding_t}), dst, this_)
end

function z_hello_clone(dst, this_)
    ccall((:z_hello_clone, libzenohc), Cvoid, (Ptr{z_owned_hello_t}, Ptr{z_loaned_hello_t}), dst, this_)
end

function z_keyexpr_clone(dst, this_)
    ccall((:z_keyexpr_clone, libzenohc), Cvoid, (Ptr{z_owned_keyexpr_t}, Ptr{z_loaned_keyexpr_t}), dst, this_)
end

function z_query_clone(dst, this_)
    ccall((:z_query_clone, libzenohc), Cvoid, (Ptr{z_owned_query_t}, Ptr{z_loaned_query_t}), dst, this_)
end

function z_reply_clone(dst, this_)
    ccall((:z_reply_clone, libzenohc), Cvoid, (Ptr{z_owned_reply_t}, Ptr{z_loaned_reply_t}), dst, this_)
end

function z_reply_err_clone(dst, this_)
    ccall((:z_reply_err_clone, libzenohc), Cvoid, (Ptr{z_owned_reply_err_t}, Ptr{z_loaned_reply_err_t}), dst, this_)
end

function z_sample_clone(dst, this_)
    ccall((:z_sample_clone, libzenohc), Cvoid, (Ptr{z_owned_sample_t}, Ptr{z_loaned_sample_t}), dst, this_)
end

function z_slice_clone(dst, this_)
    ccall((:z_slice_clone, libzenohc), Cvoid, (Ptr{z_owned_slice_t}, Ptr{z_loaned_slice_t}), dst, this_)
end

function z_string_array_clone(dst, this_)
    ccall((:z_string_array_clone, libzenohc), Cvoid, (Ptr{z_owned_string_array_t}, Ptr{z_loaned_string_array_t}), dst, this_)
end

function z_string_clone(dst, this_)
    ccall((:z_string_clone, libzenohc), Cvoid, (Ptr{z_owned_string_t}, Ptr{z_loaned_string_t}), dst, this_)
end

struct z_bytes_reader_t
    data::NTuple{24, UInt8}
end

function Base.getproperty(x::Ptr{z_bytes_reader_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{24, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_bytes_reader_t, f::Symbol)
    r = Ref{z_bytes_reader_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_bytes_reader_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_bytes_reader_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_timestamp_t
    data::NTuple{24, UInt8}
end

function Base.getproperty(x::Ptr{z_timestamp_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{24, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_timestamp_t, f::Symbol)
    r = Ref{z_timestamp_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_timestamp_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_timestamp_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct ze_deserializer_t
    data::NTuple{24, UInt8}
end

function Base.getproperty(x::Ptr{ze_deserializer_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{24, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::ze_deserializer_t, f::Symbol)
    r = Ref{ze_deserializer_t}(x)
    ptr = Base.unsafe_convert(Ptr{ze_deserializer_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{ze_deserializer_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

@cenum z_congestion_control_t::UInt32 begin
    Z_CONGESTION_CONTROL_BLOCK = 0
    Z_CONGESTION_CONTROL_DROP = 1
end

@cenum z_consolidation_mode_t::Int32 begin
    Z_CONSOLIDATION_MODE_AUTO = -1
    Z_CONSOLIDATION_MODE_NONE = 0
    Z_CONSOLIDATION_MODE_MONOTONIC = 1
    Z_CONSOLIDATION_MODE_LATEST = 2
end

@cenum z_priority_t::UInt32 begin
    Z_PRIORITY_REAL_TIME = 1
    Z_PRIORITY_INTERACTIVE_HIGH = 2
    Z_PRIORITY_INTERACTIVE_LOW = 3
    Z_PRIORITY_DATA_HIGH = 4
    Z_PRIORITY_DATA = 5
    Z_PRIORITY_DATA_LOW = 6
    Z_PRIORITY_BACKGROUND = 7
end

@cenum z_query_target_t::UInt32 begin
    Z_QUERY_TARGET_BEST_MATCHING = 0
    Z_QUERY_TARGET_ALL = 1
    Z_QUERY_TARGET_ALL_COMPLETE = 2
end

@cenum z_sample_kind_t::UInt32 begin
    Z_SAMPLE_KIND_PUT = 0
    Z_SAMPLE_KIND_DELETE = 1
end

@cenum z_what_t::UInt32 begin
    Z_WHAT_ROUTER = 1
    Z_WHAT_PEER = 2
    Z_WHAT_CLIENT = 4
    Z_WHAT_ROUTER_PEER = 3
    Z_WHAT_ROUTER_CLIENT = 5
    Z_WHAT_PEER_CLIENT = 6
    Z_WHAT_ROUTER_PEER_CLIENT = 7
end

@cenum z_whatami_t::UInt32 begin
    Z_WHATAMI_ROUTER = 1
    Z_WHATAMI_PEER = 2
    Z_WHATAMI_CLIENT = 4
end

@cenum zc_locality_t::UInt32 begin
    ZC_LOCALITY_ANY = 0
    ZC_LOCALITY_SESSION_LOCAL = 1
    ZC_LOCALITY_REMOTE = 2
end

@cenum zc_log_severity_t::UInt32 begin
    ZC_LOG_SEVERITY_TRACE = 0
    ZC_LOG_SEVERITY_DEBUG = 1
    ZC_LOG_SEVERITY_INFO = 2
    ZC_LOG_SEVERITY_WARN = 3
    ZC_LOG_SEVERITY_ERROR = 4
end

struct z_bytes_slice_iterator_t
    data::NTuple{24, UInt8}
end

function Base.getproperty(x::Ptr{z_bytes_slice_iterator_t}, f::Symbol)
    f === :_0 && return Ptr{NTuple{24, UInt8}}(x + 0)
    return getfield(x, f)
end

function Base.getproperty(x::z_bytes_slice_iterator_t, f::Symbol)
    r = Ref{z_bytes_slice_iterator_t}(x)
    ptr = Base.unsafe_convert(Ptr{z_bytes_slice_iterator_t}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{z_bytes_slice_iterator_t}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

struct z_clock_t
    t::UInt64
    t_base::Ptr{Cvoid}
end

struct z_close_options_t
    _dummy::UInt8
end

struct z_queryable_options_t
    complete::Bool
end

struct z_subscriber_options_t
    _0::UInt8
end

struct z_publisher_options_t
    encoding::Ptr{z_moved_encoding_t}
    congestion_control::z_congestion_control_t
    priority::z_priority_t
    is_express::Bool
end

struct z_query_consolidation_t
    mode::z_consolidation_mode_t
end

struct z_delete_options_t
    congestion_control::z_congestion_control_t
    priority::z_priority_t
    is_express::Bool
    timestamp::Ptr{z_timestamp_t}
end

struct z_get_options_t
    target::z_query_target_t
    consolidation::z_query_consolidation_t
    payload::Ptr{z_moved_bytes_t}
    encoding::Ptr{z_moved_encoding_t}
    congestion_control::z_congestion_control_t
    is_express::Bool
    priority::z_priority_t
    attachment::Ptr{z_moved_bytes_t}
    timeout_ms::UInt64
end

struct z_liveliness_subscriber_options_t
    history::Bool
end

struct z_liveliness_token_options_t
    _dummy::UInt8
end

struct z_liveliness_get_options_t
    timeout_ms::UInt64
end

struct z_open_options_t
    _dummy::UInt8
end

struct z_publisher_delete_options_t
    timestamp::Ptr{z_timestamp_t}
end

struct z_publisher_put_options_t
    encoding::Ptr{z_moved_encoding_t}
    timestamp::Ptr{z_timestamp_t}
    attachment::Ptr{z_moved_bytes_t}
end

struct z_put_options_t
    encoding::Ptr{z_moved_encoding_t}
    congestion_control::z_congestion_control_t
    priority::z_priority_t
    is_express::Bool
    timestamp::Ptr{z_timestamp_t}
    attachment::Ptr{z_moved_bytes_t}
end

struct z_query_reply_options_t
    encoding::Ptr{z_moved_encoding_t}
    congestion_control::z_congestion_control_t
    priority::z_priority_t
    is_express::Bool
    timestamp::Ptr{z_timestamp_t}
    attachment::Ptr{z_moved_bytes_t}
end

struct z_query_reply_del_options_t
    congestion_control::z_congestion_control_t
    priority::z_priority_t
    is_express::Bool
    timestamp::Ptr{z_timestamp_t}
    attachment::Ptr{z_moved_bytes_t}
end

struct z_query_reply_err_options_t
    encoding::Ptr{z_moved_encoding_t}
end

struct z_scout_options_t
    timeout_ms::UInt64
    what::z_what_t
end

struct z_task_attr_t
    _0::Csize_t
end

struct z_time_t
    t::UInt64
end

struct zc_internal_encoding_data_t
    id::UInt16
    schema_ptr::Ptr{UInt8}
    schema_len::Csize_t
end

function z_bytes_copy_from_buf(this_, data, len)
    ccall((:z_bytes_copy_from_buf, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, Ptr{UInt8}, Csize_t), this_, data, len)
end

function z_bytes_copy_from_slice(this_, slice)
    ccall((:z_bytes_copy_from_slice, libzenohc), Cvoid, (Ptr{z_owned_bytes_t}, Ptr{z_loaned_slice_t}), this_, slice)
end

function z_bytes_copy_from_str(this_, str)
    ccall((:z_bytes_copy_from_str, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, Ptr{Cchar}), this_, str)
end

function z_bytes_copy_from_string(this_, str)
    ccall((:z_bytes_copy_from_string, libzenohc), Cvoid, (Ptr{z_owned_bytes_t}, Ptr{z_loaned_string_t}), this_, str)
end

function z_bytes_empty(this_)
    ccall((:z_bytes_empty, libzenohc), Cvoid, (Ptr{z_owned_bytes_t},), this_)
end

function z_bytes_from_buf(this_, data, len, deleter, context)
    ccall((:z_bytes_from_buf, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, Ptr{UInt8}, Csize_t, Ptr{Cvoid}, Ptr{Cvoid}), this_, data, len, deleter, context)
end

function z_bytes_from_slice(this_, slice)
    ccall((:z_bytes_from_slice, libzenohc), Cvoid, (Ptr{z_owned_bytes_t}, Ptr{z_moved_slice_t}), this_, slice)
end

function z_bytes_from_static_buf(this_, data, len)
    ccall((:z_bytes_from_static_buf, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, Ptr{UInt8}, Csize_t), this_, data, len)
end

function z_bytes_from_static_str(this_, str)
    ccall((:z_bytes_from_static_str, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, Ptr{Cchar}), this_, str)
end

function z_bytes_from_str(this_, str, deleter, context)
    ccall((:z_bytes_from_str, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, Ptr{Cchar}, Ptr{Cvoid}, Ptr{Cvoid}), this_, str, deleter, context)
end

function z_bytes_from_string(this_, s)
    ccall((:z_bytes_from_string, libzenohc), Cvoid, (Ptr{z_owned_bytes_t}, Ptr{z_moved_string_t}), this_, s)
end

function z_bytes_get_reader(data)
    ccall((:z_bytes_get_reader, libzenohc), z_bytes_reader_t, (Ptr{z_loaned_bytes_t},), data)
end

function z_bytes_get_slice_iterator(this_)
    ccall((:z_bytes_get_slice_iterator, libzenohc), z_bytes_slice_iterator_t, (Ptr{z_loaned_bytes_t},), this_)
end

function z_bytes_is_empty(this_)
    ccall((:z_bytes_is_empty, libzenohc), Bool, (Ptr{z_loaned_bytes_t},), this_)
end

function z_bytes_len(this_)
    ccall((:z_bytes_len, libzenohc), Csize_t, (Ptr{z_loaned_bytes_t},), this_)
end

function z_bytes_reader_read(this_, dst, len)
    ccall((:z_bytes_reader_read, libzenohc), Csize_t, (Ptr{z_bytes_reader_t}, Ptr{UInt8}, Csize_t), this_, dst, len)
end

function z_bytes_reader_remaining(this_)
    ccall((:z_bytes_reader_remaining, libzenohc), Csize_t, (Ptr{z_bytes_reader_t},), this_)
end

function z_bytes_reader_seek(this_, offset, origin)
    ccall((:z_bytes_reader_seek, libzenohc), z_result_t, (Ptr{z_bytes_reader_t}, Int64, Cint), this_, offset, origin)
end

function z_bytes_reader_tell(this_)
    ccall((:z_bytes_reader_tell, libzenohc), Int64, (Ptr{z_bytes_reader_t},), this_)
end

function z_bytes_slice_iterator_next(this_, slice)
    ccall((:z_bytes_slice_iterator_next, libzenohc), Bool, (Ptr{z_bytes_slice_iterator_t}, Ptr{z_view_slice_t}), this_, slice)
end

function z_bytes_to_slice(this_, dst)
    ccall((:z_bytes_to_slice, libzenohc), z_result_t, (Ptr{z_loaned_bytes_t}, Ptr{z_owned_slice_t}), this_, dst)
end

function z_bytes_to_string(this_, dst)
    ccall((:z_bytes_to_string, libzenohc), z_result_t, (Ptr{z_loaned_bytes_t}, Ptr{z_owned_string_t}), this_, dst)
end

function z_bytes_writer_append(this_, bytes)
    ccall((:z_bytes_writer_append, libzenohc), z_result_t, (Ptr{z_loaned_bytes_writer_t}, Ptr{z_moved_bytes_t}), this_, bytes)
end

function z_bytes_writer_empty(this_)
    ccall((:z_bytes_writer_empty, libzenohc), z_result_t, (Ptr{z_owned_bytes_writer_t},), this_)
end

function z_bytes_writer_finish(this_, bytes)
    ccall((:z_bytes_writer_finish, libzenohc), Cvoid, (Ptr{z_moved_bytes_writer_t}, Ptr{z_owned_bytes_t}), this_, bytes)
end

function z_bytes_writer_write_all(this_, src, len)
    ccall((:z_bytes_writer_write_all, libzenohc), z_result_t, (Ptr{z_loaned_bytes_writer_t}, Ptr{UInt8}, Csize_t), this_, src, len)
end

function z_clock_elapsed_ms(time)
    ccall((:z_clock_elapsed_ms, libzenohc), UInt64, (Ptr{z_clock_t},), time)
end

function z_clock_elapsed_s(time)
    ccall((:z_clock_elapsed_s, libzenohc), UInt64, (Ptr{z_clock_t},), time)
end

function z_clock_elapsed_us(time)
    ccall((:z_clock_elapsed_us, libzenohc), UInt64, (Ptr{z_clock_t},), time)
end

function z_clock_now()
    ccall((:z_clock_now, libzenohc), z_clock_t, ())
end

function z_close(session, options)
    ccall((:z_close, libzenohc), z_result_t, (Ptr{z_loaned_session_t}, Ptr{z_close_options_t}), session, options)
end

function z_close_options_default(this_)
    ccall((:z_close_options_default, libzenohc), Cvoid, (Ptr{z_close_options_t},), this_)
end

function z_closure_zid_loan_mut(closure)
    ccall((:z_closure_zid_loan_mut, libzenohc), Ptr{z_loaned_closure_zid_t}, (Ptr{z_owned_closure_zid_t},), closure)
end

function z_condvar_init(this_)
    ccall((:z_condvar_init, libzenohc), Cvoid, (Ptr{z_owned_condvar_t},), this_)
end

function z_condvar_signal(this_)
    ccall((:z_condvar_signal, libzenohc), z_result_t, (Ptr{z_loaned_condvar_t},), this_)
end

function z_condvar_wait(this_, m)
    ccall((:z_condvar_wait, libzenohc), z_result_t, (Ptr{z_loaned_condvar_t}, Ptr{z_loaned_mutex_t}), this_, m)
end

function z_config_default(this_)
    ccall((:z_config_default, libzenohc), z_result_t, (Ptr{z_owned_config_t},), this_)
end

function z_declare_background_queryable(session, key_expr, callback, options)
    ccall((:z_declare_background_queryable, libzenohc), z_result_t, (Ptr{z_loaned_session_t}, Ptr{z_loaned_keyexpr_t}, Ptr{z_moved_closure_query_t}, Ptr{z_queryable_options_t}), session, key_expr, callback, options)
end

function z_declare_background_subscriber(session, key_expr, callback, options)
    ccall((:z_declare_background_subscriber, libzenohc), z_result_t, (Ptr{z_loaned_session_t}, Ptr{z_loaned_keyexpr_t}, Ptr{z_moved_closure_sample_t}, Ptr{z_subscriber_options_t}), session, key_expr, callback, options)
end

function z_declare_keyexpr(session, declared_key_expr, key_expr)
    ccall((:z_declare_keyexpr, libzenohc), z_result_t, (Ptr{z_loaned_session_t}, Ptr{z_owned_keyexpr_t}, Ptr{z_loaned_keyexpr_t}), session, declared_key_expr, key_expr)
end

function z_declare_publisher(session, publisher, key_expr, options)
    ccall((:z_declare_publisher, libzenohc), z_result_t, (Ptr{z_loaned_session_t}, Ptr{z_owned_publisher_t}, Ptr{z_loaned_keyexpr_t}, Ptr{z_publisher_options_t}), session, publisher, key_expr, options)
end

function z_declare_queryable(session, queryable, key_expr, callback, options)
    ccall((:z_declare_queryable, libzenohc), z_result_t, (Ptr{z_loaned_session_t}, Ptr{z_owned_queryable_t}, Ptr{z_loaned_keyexpr_t}, Ptr{z_moved_closure_query_t}, Ptr{z_queryable_options_t}), session, queryable, key_expr, callback, options)
end

function z_declare_subscriber(session, subscriber, key_expr, callback, options)
    ccall((:z_declare_subscriber, libzenohc), z_result_t, (Ptr{z_loaned_session_t}, Ptr{z_owned_subscriber_t}, Ptr{z_loaned_keyexpr_t}, Ptr{z_moved_closure_sample_t}, Ptr{z_subscriber_options_t}), session, subscriber, key_expr, callback, options)
end

function z_delete(session, key_expr, options)
    ccall((:z_delete, libzenohc), z_result_t, (Ptr{z_loaned_session_t}, Ptr{z_loaned_keyexpr_t}, Ptr{z_delete_options_t}), session, key_expr, options)
end

function z_delete_options_default(this_)
    ccall((:z_delete_options_default, libzenohc), Cvoid, (Ptr{z_delete_options_t},), this_)
end

function z_encoding_application_cbor()
    ccall((:z_encoding_application_cbor, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_cdr()
    ccall((:z_encoding_application_cdr, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_coap_payload()
    ccall((:z_encoding_application_coap_payload, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_java_serialized_object()
    ccall((:z_encoding_application_java_serialized_object, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_json()
    ccall((:z_encoding_application_json, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_json_patch_json()
    ccall((:z_encoding_application_json_patch_json, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_json_seq()
    ccall((:z_encoding_application_json_seq, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_jsonpath()
    ccall((:z_encoding_application_jsonpath, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_jwt()
    ccall((:z_encoding_application_jwt, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_mp4()
    ccall((:z_encoding_application_mp4, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_octet_stream()
    ccall((:z_encoding_application_octet_stream, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_openmetrics_text()
    ccall((:z_encoding_application_openmetrics_text, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_protobuf()
    ccall((:z_encoding_application_protobuf, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_python_serialized_object()
    ccall((:z_encoding_application_python_serialized_object, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_soap_xml()
    ccall((:z_encoding_application_soap_xml, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_sql()
    ccall((:z_encoding_application_sql, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_x_www_form_urlencoded()
    ccall((:z_encoding_application_x_www_form_urlencoded, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_xml()
    ccall((:z_encoding_application_xml, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_yaml()
    ccall((:z_encoding_application_yaml, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_application_yang()
    ccall((:z_encoding_application_yang, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_audio_aac()
    ccall((:z_encoding_audio_aac, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_audio_flac()
    ccall((:z_encoding_audio_flac, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_audio_mp4()
    ccall((:z_encoding_audio_mp4, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_audio_ogg()
    ccall((:z_encoding_audio_ogg, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_audio_vorbis()
    ccall((:z_encoding_audio_vorbis, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_equals(this_, other)
    ccall((:z_encoding_equals, libzenohc), Bool, (Ptr{z_loaned_encoding_t}, Ptr{z_loaned_encoding_t}), this_, other)
end

function z_encoding_from_str(this_, s)
    ccall((:z_encoding_from_str, libzenohc), z_result_t, (Ptr{z_owned_encoding_t}, Ptr{Cchar}), this_, s)
end

function z_encoding_from_substr(this_, s, len)
    ccall((:z_encoding_from_substr, libzenohc), z_result_t, (Ptr{z_owned_encoding_t}, Ptr{Cchar}, Csize_t), this_, s, len)
end

function z_encoding_image_bmp()
    ccall((:z_encoding_image_bmp, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_image_gif()
    ccall((:z_encoding_image_gif, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_image_jpeg()
    ccall((:z_encoding_image_jpeg, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_image_png()
    ccall((:z_encoding_image_png, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_image_webp()
    ccall((:z_encoding_image_webp, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_loan_default()
    ccall((:z_encoding_loan_default, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_set_schema_from_str(this_, s)
    ccall((:z_encoding_set_schema_from_str, libzenohc), z_result_t, (Ptr{z_loaned_encoding_t}, Ptr{Cchar}), this_, s)
end

function z_encoding_set_schema_from_substr(this_, s, len)
    ccall((:z_encoding_set_schema_from_substr, libzenohc), z_result_t, (Ptr{z_loaned_encoding_t}, Ptr{Cchar}, Csize_t), this_, s, len)
end

function z_encoding_text_css()
    ccall((:z_encoding_text_css, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_text_csv()
    ccall((:z_encoding_text_csv, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_text_html()
    ccall((:z_encoding_text_html, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_text_javascript()
    ccall((:z_encoding_text_javascript, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_text_json()
    ccall((:z_encoding_text_json, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_text_json5()
    ccall((:z_encoding_text_json5, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_text_markdown()
    ccall((:z_encoding_text_markdown, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_text_plain()
    ccall((:z_encoding_text_plain, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_text_xml()
    ccall((:z_encoding_text_xml, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_text_yaml()
    ccall((:z_encoding_text_yaml, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_to_string(this_, out_str)
    ccall((:z_encoding_to_string, libzenohc), Cvoid, (Ptr{z_loaned_encoding_t}, Ptr{z_owned_string_t}), this_, out_str)
end

function z_encoding_video_h261()
    ccall((:z_encoding_video_h261, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_video_h263()
    ccall((:z_encoding_video_h263, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_video_h264()
    ccall((:z_encoding_video_h264, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_video_h265()
    ccall((:z_encoding_video_h265, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_video_h266()
    ccall((:z_encoding_video_h266, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_video_mp4()
    ccall((:z_encoding_video_mp4, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_video_ogg()
    ccall((:z_encoding_video_ogg, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_video_raw()
    ccall((:z_encoding_video_raw, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_video_vp8()
    ccall((:z_encoding_video_vp8, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_video_vp9()
    ccall((:z_encoding_video_vp9, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_zenoh_bytes()
    ccall((:z_encoding_zenoh_bytes, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_zenoh_serialized()
    ccall((:z_encoding_zenoh_serialized, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_encoding_zenoh_string()
    ccall((:z_encoding_zenoh_string, libzenohc), Ptr{z_loaned_encoding_t}, ())
end

function z_fifo_channel_query_new(callback, handler, capacity)
    ccall((:z_fifo_channel_query_new, libzenohc), Cvoid, (Ptr{z_owned_closure_query_t}, Ptr{z_owned_fifo_handler_query_t}, Csize_t), callback, handler, capacity)
end

function z_fifo_channel_reply_new(callback, handler, capacity)
    ccall((:z_fifo_channel_reply_new, libzenohc), Cvoid, (Ptr{z_owned_closure_reply_t}, Ptr{z_owned_fifo_handler_reply_t}, Csize_t), callback, handler, capacity)
end

function z_fifo_channel_sample_new(callback, handler, capacity)
    ccall((:z_fifo_channel_sample_new, libzenohc), Cvoid, (Ptr{z_owned_closure_sample_t}, Ptr{z_owned_fifo_handler_sample_t}, Csize_t), callback, handler, capacity)
end

function z_get(session, key_expr, parameters, callback, options)
    ccall((:z_get, libzenohc), z_result_t, (Ptr{z_loaned_session_t}, Ptr{z_loaned_keyexpr_t}, Ptr{Cchar}, Ptr{z_moved_closure_reply_t}, Ptr{z_get_options_t}), session, key_expr, parameters, callback, options)
end

function z_get_options_default(this_)
    ccall((:z_get_options_default, libzenohc), Cvoid, (Ptr{z_get_options_t},), this_)
end

function z_hello_locators(this_, locators_out)
    ccall((:z_hello_locators, libzenohc), Cvoid, (Ptr{z_loaned_hello_t}, Ptr{z_owned_string_array_t}), this_, locators_out)
end

function z_hello_whatami(this_)
    ccall((:z_hello_whatami, libzenohc), z_whatami_t, (Ptr{z_loaned_hello_t},), this_)
end

function z_hello_zid(this_)
    ccall((:z_hello_zid, libzenohc), z_id_t, (Ptr{z_loaned_hello_t},), this_)
end

function z_id_to_string(zid, dst)
    ccall((:z_id_to_string, libzenohc), Cvoid, (Ptr{z_id_t}, Ptr{z_owned_string_t}), zid, dst)
end

function z_info_peers_zid(session, callback)
    ccall((:z_info_peers_zid, libzenohc), z_result_t, (Ptr{z_loaned_session_t}, Ptr{z_moved_closure_zid_t}), session, callback)
end

function z_info_routers_zid(session, callback)
    ccall((:z_info_routers_zid, libzenohc), z_result_t, (Ptr{z_loaned_session_t}, Ptr{z_moved_closure_zid_t}), session, callback)
end

function z_info_zid(session)
    ccall((:z_info_zid, libzenohc), z_id_t, (Ptr{z_loaned_session_t},), session)
end

function z_internal_congestion_control_default_push()
    ccall((:z_internal_congestion_control_default_push, libzenohc), z_congestion_control_t, ())
end

function z_internal_congestion_control_default_request()
    ccall((:z_internal_congestion_control_default_request, libzenohc), z_congestion_control_t, ())
end

function z_internal_congestion_control_default_response()
    ccall((:z_internal_congestion_control_default_response, libzenohc), z_congestion_control_t, ())
end

function z_keyexpr_as_view_string(this_, out_string)
    ccall((:z_keyexpr_as_view_string, libzenohc), Cvoid, (Ptr{z_loaned_keyexpr_t}, Ptr{z_view_string_t}), this_, out_string)
end

function z_keyexpr_canonize(start, len)
    ccall((:z_keyexpr_canonize, libzenohc), z_result_t, (Ptr{Cchar}, Ptr{Csize_t}), start, len)
end

function z_keyexpr_canonize_null_terminated(start)
    ccall((:z_keyexpr_canonize_null_terminated, libzenohc), z_result_t, (Ptr{Cchar},), start)
end

function z_keyexpr_concat(this_, left, right_start, right_len)
    ccall((:z_keyexpr_concat, libzenohc), z_result_t, (Ptr{z_owned_keyexpr_t}, Ptr{z_loaned_keyexpr_t}, Ptr{Cchar}, Csize_t), this_, left, right_start, right_len)
end

function z_keyexpr_equals(left, right)
    ccall((:z_keyexpr_equals, libzenohc), Bool, (Ptr{z_loaned_keyexpr_t}, Ptr{z_loaned_keyexpr_t}), left, right)
end

function z_keyexpr_from_str(this_, expr)
    ccall((:z_keyexpr_from_str, libzenohc), z_result_t, (Ptr{z_owned_keyexpr_t}, Ptr{Cchar}), this_, expr)
end

function z_keyexpr_from_str_autocanonize(this_, expr)
    ccall((:z_keyexpr_from_str_autocanonize, libzenohc), z_result_t, (Ptr{z_owned_keyexpr_t}, Ptr{Cchar}), this_, expr)
end

function z_keyexpr_from_substr(this_, expr, len)
    ccall((:z_keyexpr_from_substr, libzenohc), z_result_t, (Ptr{z_owned_keyexpr_t}, Ptr{Cchar}, Csize_t), this_, expr, len)
end

function z_keyexpr_from_substr_autocanonize(this_, start, len)
    ccall((:z_keyexpr_from_substr_autocanonize, libzenohc), z_result_t, (Ptr{z_owned_keyexpr_t}, Ptr{Cchar}, Ptr{Csize_t}), this_, start, len)
end

function z_keyexpr_includes(left, right)
    ccall((:z_keyexpr_includes, libzenohc), Bool, (Ptr{z_loaned_keyexpr_t}, Ptr{z_loaned_keyexpr_t}), left, right)
end

function z_keyexpr_intersects(left, right)
    ccall((:z_keyexpr_intersects, libzenohc), Bool, (Ptr{z_loaned_keyexpr_t}, Ptr{z_loaned_keyexpr_t}), left, right)
end

function z_keyexpr_is_canon(start, len)
    ccall((:z_keyexpr_is_canon, libzenohc), z_result_t, (Ptr{Cchar}, Csize_t), start, len)
end

function z_keyexpr_join(this_, left, right)
    ccall((:z_keyexpr_join, libzenohc), z_result_t, (Ptr{z_owned_keyexpr_t}, Ptr{z_loaned_keyexpr_t}, Ptr{z_loaned_keyexpr_t}), this_, left, right)
end

function z_liveliness_declare_background_subscriber(session, key_expr, callback, options)
    ccall((:z_liveliness_declare_background_subscriber, libzenohc), z_result_t, (Ptr{z_loaned_session_t}, Ptr{z_loaned_keyexpr_t}, Ptr{z_moved_closure_sample_t}, Ptr{z_liveliness_subscriber_options_t}), session, key_expr, callback, options)
end

function z_liveliness_declare_subscriber(session, subscriber, key_expr, callback, options)
    ccall((:z_liveliness_declare_subscriber, libzenohc), z_result_t, (Ptr{z_loaned_session_t}, Ptr{z_owned_subscriber_t}, Ptr{z_loaned_keyexpr_t}, Ptr{z_moved_closure_sample_t}, Ptr{z_liveliness_subscriber_options_t}), session, subscriber, key_expr, callback, options)
end

function z_liveliness_declare_token(session, token, key_expr, _options)
    ccall((:z_liveliness_declare_token, libzenohc), z_result_t, (Ptr{z_loaned_session_t}, Ptr{z_owned_liveliness_token_t}, Ptr{z_loaned_keyexpr_t}, Ptr{z_liveliness_token_options_t}), session, token, key_expr, _options)
end

function z_liveliness_get(session, key_expr, callback, options)
    ccall((:z_liveliness_get, libzenohc), z_result_t, (Ptr{z_loaned_session_t}, Ptr{z_loaned_keyexpr_t}, Ptr{z_moved_closure_reply_t}, Ptr{z_liveliness_get_options_t}), session, key_expr, callback, options)
end

function z_liveliness_get_options_default(this_)
    ccall((:z_liveliness_get_options_default, libzenohc), Cvoid, (Ptr{z_liveliness_get_options_t},), this_)
end

function z_liveliness_subscriber_options_default(this_)
    ccall((:z_liveliness_subscriber_options_default, libzenohc), Cvoid, (Ptr{z_liveliness_subscriber_options_t},), this_)
end

function z_liveliness_token_options_default(this_)
    ccall((:z_liveliness_token_options_default, libzenohc), Cvoid, (Ptr{z_liveliness_token_options_t},), this_)
end

function z_liveliness_undeclare_token(this_)
    ccall((:z_liveliness_undeclare_token, libzenohc), z_result_t, (Ptr{z_moved_liveliness_token_t},), this_)
end

function z_mutex_init(this_)
    ccall((:z_mutex_init, libzenohc), z_result_t, (Ptr{z_owned_mutex_t},), this_)
end

function z_mutex_lock(this_)
    ccall((:z_mutex_lock, libzenohc), z_result_t, (Ptr{z_loaned_mutex_t},), this_)
end

function z_mutex_try_lock(this_)
    ccall((:z_mutex_try_lock, libzenohc), z_result_t, (Ptr{z_loaned_mutex_t},), this_)
end

function z_mutex_unlock(this_)
    ccall((:z_mutex_unlock, libzenohc), z_result_t, (Ptr{z_loaned_mutex_t},), this_)
end

function z_open(this_, config, _options)
    ccall((:z_open, libzenohc), z_result_t, (Ptr{z_owned_session_t}, Ptr{z_moved_config_t}, Ptr{z_open_options_t}), this_, config, _options)
end

function z_open_options_default(this_)
    ccall((:z_open_options_default, libzenohc), Cvoid, (Ptr{z_open_options_t},), this_)
end

function z_priority_default()
    ccall((:z_priority_default, libzenohc), z_priority_t, ())
end

function z_publisher_delete(publisher, options)
    ccall((:z_publisher_delete, libzenohc), z_result_t, (Ptr{z_loaned_publisher_t}, Ptr{z_publisher_delete_options_t}), publisher, options)
end

function z_publisher_delete_options_default(this_)
    ccall((:z_publisher_delete_options_default, libzenohc), Cvoid, (Ptr{z_publisher_delete_options_t},), this_)
end

function z_publisher_keyexpr(publisher)
    ccall((:z_publisher_keyexpr, libzenohc), Ptr{z_loaned_keyexpr_t}, (Ptr{z_loaned_publisher_t},), publisher)
end

function z_publisher_options_default(this_)
    ccall((:z_publisher_options_default, libzenohc), Cvoid, (Ptr{z_publisher_options_t},), this_)
end

function z_publisher_put(this_, payload, options)
    ccall((:z_publisher_put, libzenohc), z_result_t, (Ptr{z_loaned_publisher_t}, Ptr{z_moved_bytes_t}, Ptr{z_publisher_put_options_t}), this_, payload, options)
end

function z_publisher_put_options_default(this_)
    ccall((:z_publisher_put_options_default, libzenohc), Cvoid, (Ptr{z_publisher_put_options_t},), this_)
end

function z_put(session, key_expr, payload, options)
    ccall((:z_put, libzenohc), z_result_t, (Ptr{z_loaned_session_t}, Ptr{z_loaned_keyexpr_t}, Ptr{z_moved_bytes_t}, Ptr{z_put_options_t}), session, key_expr, payload, options)
end

function z_put_options_default(this_)
    ccall((:z_put_options_default, libzenohc), Cvoid, (Ptr{z_put_options_t},), this_)
end

function z_query_attachment(this_)
    ccall((:z_query_attachment, libzenohc), Ptr{z_loaned_bytes_t}, (Ptr{z_loaned_query_t},), this_)
end

function z_query_attachment_mut(this_)
    ccall((:z_query_attachment_mut, libzenohc), Ptr{z_loaned_bytes_t}, (Ptr{z_loaned_query_t},), this_)
end

function z_query_consolidation_auto()
    ccall((:z_query_consolidation_auto, libzenohc), z_query_consolidation_t, ())
end

function z_query_consolidation_default()
    ccall((:z_query_consolidation_default, libzenohc), z_query_consolidation_t, ())
end

function z_query_consolidation_latest()
    ccall((:z_query_consolidation_latest, libzenohc), z_query_consolidation_t, ())
end

function z_query_consolidation_monotonic()
    ccall((:z_query_consolidation_monotonic, libzenohc), z_query_consolidation_t, ())
end

function z_query_consolidation_none()
    ccall((:z_query_consolidation_none, libzenohc), z_query_consolidation_t, ())
end

function z_query_encoding(this_)
    ccall((:z_query_encoding, libzenohc), Ptr{z_loaned_encoding_t}, (Ptr{z_loaned_query_t},), this_)
end

function z_query_keyexpr(this_)
    ccall((:z_query_keyexpr, libzenohc), Ptr{z_loaned_keyexpr_t}, (Ptr{z_loaned_query_t},), this_)
end

function z_query_parameters(this_, parameters)
    ccall((:z_query_parameters, libzenohc), Cvoid, (Ptr{z_loaned_query_t}, Ptr{z_view_string_t}), this_, parameters)
end

function z_query_payload(this_)
    ccall((:z_query_payload, libzenohc), Ptr{z_loaned_bytes_t}, (Ptr{z_loaned_query_t},), this_)
end

function z_query_payload_mut(this_)
    ccall((:z_query_payload_mut, libzenohc), Ptr{z_loaned_bytes_t}, (Ptr{z_loaned_query_t},), this_)
end

function z_query_reply(this_, key_expr, payload, options)
    ccall((:z_query_reply, libzenohc), z_result_t, (Ptr{z_loaned_query_t}, Ptr{z_loaned_keyexpr_t}, Ptr{z_moved_bytes_t}, Ptr{z_query_reply_options_t}), this_, key_expr, payload, options)
end

function z_query_reply_del(this_, key_expr, options)
    ccall((:z_query_reply_del, libzenohc), z_result_t, (Ptr{z_loaned_query_t}, Ptr{z_loaned_keyexpr_t}, Ptr{z_query_reply_del_options_t}), this_, key_expr, options)
end

function z_query_reply_del_options_default(this_)
    ccall((:z_query_reply_del_options_default, libzenohc), Cvoid, (Ptr{z_query_reply_del_options_t},), this_)
end

function z_query_reply_err(this_, payload, options)
    ccall((:z_query_reply_err, libzenohc), z_result_t, (Ptr{z_loaned_query_t}, Ptr{z_moved_bytes_t}, Ptr{z_query_reply_err_options_t}), this_, payload, options)
end

function z_query_reply_err_options_default(this_)
    ccall((:z_query_reply_err_options_default, libzenohc), Cvoid, (Ptr{z_query_reply_err_options_t},), this_)
end

function z_query_reply_options_default(this_)
    ccall((:z_query_reply_options_default, libzenohc), Cvoid, (Ptr{z_query_reply_options_t},), this_)
end

function z_query_target_default()
    ccall((:z_query_target_default, libzenohc), z_query_target_t, ())
end

function z_queryable_options_default(this_)
    ccall((:z_queryable_options_default, libzenohc), Cvoid, (Ptr{z_queryable_options_t},), this_)
end

function z_random_fill(buf, len)
    ccall((:z_random_fill, libzenohc), Cvoid, (Ptr{Cvoid}, Csize_t), buf, len)
end

function z_random_u16()
    ccall((:z_random_u16, libzenohc), UInt16, ())
end

function z_random_u32()
    ccall((:z_random_u32, libzenohc), UInt32, ())
end

function z_random_u64()
    ccall((:z_random_u64, libzenohc), UInt64, ())
end

function z_random_u8()
    ccall((:z_random_u8, libzenohc), UInt8, ())
end

function z_reply_err(this_)
    ccall((:z_reply_err, libzenohc), Ptr{z_loaned_reply_err_t}, (Ptr{z_loaned_reply_t},), this_)
end

function z_reply_err_encoding(this_)
    ccall((:z_reply_err_encoding, libzenohc), Ptr{z_loaned_encoding_t}, (Ptr{z_loaned_reply_err_t},), this_)
end

function z_reply_err_mut(this_)
    ccall((:z_reply_err_mut, libzenohc), Ptr{z_loaned_reply_err_t}, (Ptr{z_loaned_reply_t},), this_)
end

function z_reply_err_payload(this_)
    ccall((:z_reply_err_payload, libzenohc), Ptr{z_loaned_bytes_t}, (Ptr{z_loaned_reply_err_t},), this_)
end

function z_reply_err_payload_mut(this_)
    ccall((:z_reply_err_payload_mut, libzenohc), Ptr{z_loaned_bytes_t}, (Ptr{z_loaned_reply_err_t},), this_)
end

function z_reply_is_ok(this_)
    ccall((:z_reply_is_ok, libzenohc), Bool, (Ptr{z_loaned_reply_t},), this_)
end

function z_reply_ok(this_)
    ccall((:z_reply_ok, libzenohc), Ptr{z_loaned_sample_t}, (Ptr{z_loaned_reply_t},), this_)
end

function z_reply_ok_mut(this_)
    ccall((:z_reply_ok_mut, libzenohc), Ptr{z_loaned_sample_t}, (Ptr{z_loaned_reply_t},), this_)
end

function z_ring_channel_query_new(callback, handler, capacity)
    ccall((:z_ring_channel_query_new, libzenohc), Cvoid, (Ptr{z_owned_closure_query_t}, Ptr{z_owned_ring_handler_query_t}, Csize_t), callback, handler, capacity)
end

function z_ring_channel_reply_new(callback, handler, capacity)
    ccall((:z_ring_channel_reply_new, libzenohc), Cvoid, (Ptr{z_owned_closure_reply_t}, Ptr{z_owned_ring_handler_reply_t}, Csize_t), callback, handler, capacity)
end

function z_ring_channel_sample_new(callback, handler, capacity)
    ccall((:z_ring_channel_sample_new, libzenohc), Cvoid, (Ptr{z_owned_closure_sample_t}, Ptr{z_owned_ring_handler_sample_t}, Csize_t), callback, handler, capacity)
end

function z_sample_attachment(this_)
    ccall((:z_sample_attachment, libzenohc), Ptr{z_loaned_bytes_t}, (Ptr{z_loaned_sample_t},), this_)
end

function z_sample_congestion_control(this_)
    ccall((:z_sample_congestion_control, libzenohc), z_congestion_control_t, (Ptr{z_loaned_sample_t},), this_)
end

function z_sample_encoding(this_)
    ccall((:z_sample_encoding, libzenohc), Ptr{z_loaned_encoding_t}, (Ptr{z_loaned_sample_t},), this_)
end

function z_sample_express(this_)
    ccall((:z_sample_express, libzenohc), Bool, (Ptr{z_loaned_sample_t},), this_)
end

function z_sample_keyexpr(this_)
    ccall((:z_sample_keyexpr, libzenohc), Ptr{z_loaned_keyexpr_t}, (Ptr{z_loaned_sample_t},), this_)
end

function z_sample_kind(this_)
    ccall((:z_sample_kind, libzenohc), z_sample_kind_t, (Ptr{z_loaned_sample_t},), this_)
end

function z_sample_payload(this_)
    ccall((:z_sample_payload, libzenohc), Ptr{z_loaned_bytes_t}, (Ptr{z_loaned_sample_t},), this_)
end

function z_sample_payload_mut(this_)
    ccall((:z_sample_payload_mut, libzenohc), Ptr{z_loaned_bytes_t}, (Ptr{z_loaned_sample_t},), this_)
end

function z_sample_priority(this_)
    ccall((:z_sample_priority, libzenohc), z_priority_t, (Ptr{z_loaned_sample_t},), this_)
end

function z_sample_timestamp(this_)
    ccall((:z_sample_timestamp, libzenohc), Ptr{z_timestamp_t}, (Ptr{z_loaned_sample_t},), this_)
end

function z_scout(config, callback, options)
    ccall((:z_scout, libzenohc), z_result_t, (Ptr{z_moved_config_t}, Ptr{z_moved_closure_hello_t}, Ptr{z_scout_options_t}), config, callback, options)
end

function z_scout_options_default(this_)
    ccall((:z_scout_options_default, libzenohc), Cvoid, (Ptr{z_scout_options_t},), this_)
end

function z_session_is_closed(session)
    ccall((:z_session_is_closed, libzenohc), Bool, (Ptr{z_loaned_session_t},), session)
end

function z_sleep_ms(time)
    ccall((:z_sleep_ms, libzenohc), z_result_t, (Csize_t,), time)
end

function z_sleep_s(time)
    ccall((:z_sleep_s, libzenohc), z_result_t, (Csize_t,), time)
end

function z_sleep_us(time)
    ccall((:z_sleep_us, libzenohc), z_result_t, (Csize_t,), time)
end

function z_slice_copy_from_buf(this_, start, len)
    ccall((:z_slice_copy_from_buf, libzenohc), z_result_t, (Ptr{z_owned_slice_t}, Ptr{UInt8}, Csize_t), this_, start, len)
end

function z_slice_data(this_)
    ccall((:z_slice_data, libzenohc), Ptr{UInt8}, (Ptr{z_loaned_slice_t},), this_)
end

function z_slice_empty(this_)
    ccall((:z_slice_empty, libzenohc), Cvoid, (Ptr{z_owned_slice_t},), this_)
end

function z_slice_from_buf(this_, data, len, drop, context)
    ccall((:z_slice_from_buf, libzenohc), z_result_t, (Ptr{z_owned_slice_t}, Ptr{UInt8}, Csize_t, Ptr{Cvoid}, Ptr{Cvoid}), this_, data, len, drop, context)
end

function z_slice_is_empty(this_)
    ccall((:z_slice_is_empty, libzenohc), Bool, (Ptr{z_loaned_slice_t},), this_)
end

function z_slice_len(this_)
    ccall((:z_slice_len, libzenohc), Csize_t, (Ptr{z_loaned_slice_t},), this_)
end

function z_string_array_get(this_, index)
    ccall((:z_string_array_get, libzenohc), Ptr{z_loaned_string_t}, (Ptr{z_loaned_string_array_t}, Csize_t), this_, index)
end

function z_string_array_is_empty(this_)
    ccall((:z_string_array_is_empty, libzenohc), Bool, (Ptr{z_loaned_string_array_t},), this_)
end

function z_string_array_len(this_)
    ccall((:z_string_array_len, libzenohc), Csize_t, (Ptr{z_loaned_string_array_t},), this_)
end

function z_string_array_new(this_)
    ccall((:z_string_array_new, libzenohc), Cvoid, (Ptr{z_owned_string_array_t},), this_)
end

function z_string_array_push_by_alias(this_, value)
    ccall((:z_string_array_push_by_alias, libzenohc), Csize_t, (Ptr{z_loaned_string_array_t}, Ptr{z_loaned_string_t}), this_, value)
end

function z_string_array_push_by_copy(this_, value)
    ccall((:z_string_array_push_by_copy, libzenohc), Csize_t, (Ptr{z_loaned_string_array_t}, Ptr{z_loaned_string_t}), this_, value)
end

function z_string_as_slice(this_)
    ccall((:z_string_as_slice, libzenohc), Ptr{z_loaned_slice_t}, (Ptr{z_loaned_string_t},), this_)
end

function z_string_copy_from_str(this_, str)
    ccall((:z_string_copy_from_str, libzenohc), z_result_t, (Ptr{z_owned_string_t}, Ptr{Cchar}), this_, str)
end

function z_string_copy_from_substr(this_, str, len)
    ccall((:z_string_copy_from_substr, libzenohc), z_result_t, (Ptr{z_owned_string_t}, Ptr{Cchar}, Csize_t), this_, str, len)
end

function z_string_data(this_)
    ccall((:z_string_data, libzenohc), Ptr{Cchar}, (Ptr{z_loaned_string_t},), this_)
end

function z_string_empty(this_)
    ccall((:z_string_empty, libzenohc), Cvoid, (Ptr{z_owned_string_t},), this_)
end

function z_string_from_str(this_, str, drop, context)
    ccall((:z_string_from_str, libzenohc), z_result_t, (Ptr{z_owned_string_t}, Ptr{Cchar}, Ptr{Cvoid}, Ptr{Cvoid}), this_, str, drop, context)
end

function z_string_is_empty(this_)
    ccall((:z_string_is_empty, libzenohc), Bool, (Ptr{z_loaned_string_t},), this_)
end

function z_string_len(this_)
    ccall((:z_string_len, libzenohc), Csize_t, (Ptr{z_loaned_string_t},), this_)
end

function z_subscriber_keyexpr(subscriber)
    ccall((:z_subscriber_keyexpr, libzenohc), Ptr{z_loaned_keyexpr_t}, (Ptr{z_loaned_subscriber_t},), subscriber)
end

function z_subscriber_options_default(this_)
    ccall((:z_subscriber_options_default, libzenohc), Cvoid, (Ptr{z_subscriber_options_t},), this_)
end

function z_task_detach(this_)
    ccall((:z_task_detach, libzenohc), Cvoid, (Ptr{z_moved_task_t},), this_)
end

function z_task_init(this_, _attr, fun, arg)
    ccall((:z_task_init, libzenohc), z_result_t, (Ptr{z_owned_task_t}, Ptr{z_task_attr_t}, Ptr{Cvoid}, Ptr{Cvoid}), this_, _attr, fun, arg)
end

function z_task_join(this_)
    ccall((:z_task_join, libzenohc), z_result_t, (Ptr{z_moved_task_t},), this_)
end

function z_time_elapsed_ms(time)
    ccall((:z_time_elapsed_ms, libzenohc), UInt64, (Ptr{z_time_t},), time)
end

function z_time_elapsed_s(time)
    ccall((:z_time_elapsed_s, libzenohc), UInt64, (Ptr{z_time_t},), time)
end

function z_time_elapsed_us(time)
    ccall((:z_time_elapsed_us, libzenohc), UInt64, (Ptr{z_time_t},), time)
end

function z_time_now()
    ccall((:z_time_now, libzenohc), z_time_t, ())
end

function z_time_now_as_str(buf, len)
    ccall((:z_time_now_as_str, libzenohc), Ptr{Cchar}, (Ptr{Cchar}, Csize_t), buf, len)
end

function z_timestamp_id(this_)
    ccall((:z_timestamp_id, libzenohc), z_id_t, (Ptr{z_timestamp_t},), this_)
end

function z_timestamp_new(this_, session)
    ccall((:z_timestamp_new, libzenohc), z_result_t, (Ptr{z_timestamp_t}, Ptr{z_loaned_session_t}), this_, session)
end

function z_timestamp_ntp64_time(this_)
    ccall((:z_timestamp_ntp64_time, libzenohc), UInt64, (Ptr{z_timestamp_t},), this_)
end

function z_undeclare_keyexpr(session, key_expr)
    ccall((:z_undeclare_keyexpr, libzenohc), z_result_t, (Ptr{z_loaned_session_t}, Ptr{z_moved_keyexpr_t}), session, key_expr)
end

function z_undeclare_publisher(this_)
    ccall((:z_undeclare_publisher, libzenohc), z_result_t, (Ptr{z_moved_publisher_t},), this_)
end

function z_undeclare_queryable(this_)
    ccall((:z_undeclare_queryable, libzenohc), z_result_t, (Ptr{z_moved_queryable_t},), this_)
end

function z_undeclare_subscriber(this_)
    ccall((:z_undeclare_subscriber, libzenohc), z_result_t, (Ptr{z_moved_subscriber_t},), this_)
end

function z_view_keyexpr_empty(this_)
    ccall((:z_view_keyexpr_empty, libzenohc), Cvoid, (Ptr{z_view_keyexpr_t},), this_)
end

function z_view_keyexpr_from_str(this_, expr)
    ccall((:z_view_keyexpr_from_str, libzenohc), z_result_t, (Ptr{z_view_keyexpr_t}, Ptr{Cchar}), this_, expr)
end

function z_view_keyexpr_from_str_autocanonize(this_, expr)
    ccall((:z_view_keyexpr_from_str_autocanonize, libzenohc), z_result_t, (Ptr{z_view_keyexpr_t}, Ptr{Cchar}), this_, expr)
end

function z_view_keyexpr_from_str_unchecked(this_, s)
    ccall((:z_view_keyexpr_from_str_unchecked, libzenohc), Cvoid, (Ptr{z_view_keyexpr_t}, Ptr{Cchar}), this_, s)
end

function z_view_keyexpr_from_substr(this_, expr, len)
    ccall((:z_view_keyexpr_from_substr, libzenohc), z_result_t, (Ptr{z_view_keyexpr_t}, Ptr{Cchar}, Csize_t), this_, expr, len)
end

function z_view_keyexpr_from_substr_autocanonize(this_, start, len)
    ccall((:z_view_keyexpr_from_substr_autocanonize, libzenohc), z_result_t, (Ptr{z_view_keyexpr_t}, Ptr{Cchar}, Ptr{Csize_t}), this_, start, len)
end

function z_view_keyexpr_from_substr_unchecked(this_, start, len)
    ccall((:z_view_keyexpr_from_substr_unchecked, libzenohc), Cvoid, (Ptr{z_view_keyexpr_t}, Ptr{Cchar}, Csize_t), this_, start, len)
end

function z_view_keyexpr_is_empty(this_)
    ccall((:z_view_keyexpr_is_empty, libzenohc), Bool, (Ptr{z_view_keyexpr_t},), this_)
end

function z_view_slice_empty(this_)
    ccall((:z_view_slice_empty, libzenohc), Cvoid, (Ptr{z_view_slice_t},), this_)
end

function z_view_slice_from_buf(this_, start, len)
    ccall((:z_view_slice_from_buf, libzenohc), z_result_t, (Ptr{z_view_slice_t}, Ptr{UInt8}, Csize_t), this_, start, len)
end

function z_view_slice_is_empty(this_)
    ccall((:z_view_slice_is_empty, libzenohc), Bool, (Ptr{z_view_slice_t},), this_)
end

function z_view_string_empty(this_)
    ccall((:z_view_string_empty, libzenohc), Cvoid, (Ptr{z_view_string_t},), this_)
end

function z_view_string_from_str(this_, str)
    ccall((:z_view_string_from_str, libzenohc), z_result_t, (Ptr{z_view_string_t}, Ptr{Cchar}), this_, str)
end

function z_view_string_from_substr(this_, str, len)
    ccall((:z_view_string_from_substr, libzenohc), z_result_t, (Ptr{z_view_string_t}, Ptr{Cchar}, Csize_t), this_, str, len)
end

function z_view_string_is_empty(this_)
    ccall((:z_view_string_is_empty, libzenohc), Bool, (Ptr{z_view_string_t},), this_)
end

function z_whatami_to_view_string(whatami, str_out)
    ccall((:z_whatami_to_view_string, libzenohc), z_result_t, (z_whatami_t, Ptr{z_view_string_t}), whatami, str_out)
end

function zc_closure_log_call(closure, severity, msg)
    ccall((:zc_closure_log_call, libzenohc), Cvoid, (Ptr{zc_loaned_closure_log_t}, zc_log_severity_t, Ptr{z_loaned_string_t}), closure, severity, msg)
end

function zc_config_from_env(this_)
    ccall((:zc_config_from_env, libzenohc), z_result_t, (Ptr{z_owned_config_t},), this_)
end

function zc_config_from_file(this_, path)
    ccall((:zc_config_from_file, libzenohc), z_result_t, (Ptr{z_owned_config_t}, Ptr{Cchar}), this_, path)
end

function zc_config_from_str(this_, s)
    ccall((:zc_config_from_str, libzenohc), z_result_t, (Ptr{z_owned_config_t}, Ptr{Cchar}), this_, s)
end

function zc_config_get_from_str(this_, key, out_value_string)
    ccall((:zc_config_get_from_str, libzenohc), z_result_t, (Ptr{z_loaned_config_t}, Ptr{Cchar}, Ptr{z_owned_string_t}), this_, key, out_value_string)
end

function zc_config_get_from_substr(this_, key, key_len, out_value_string)
    ccall((:zc_config_get_from_substr, libzenohc), z_result_t, (Ptr{z_loaned_config_t}, Ptr{Cchar}, Csize_t, Ptr{z_owned_string_t}), this_, key, key_len, out_value_string)
end

function zc_config_insert_json5(this_, key, value)
    ccall((:zc_config_insert_json5, libzenohc), z_result_t, (Ptr{z_loaned_config_t}, Ptr{Cchar}, Ptr{Cchar}), this_, key, value)
end

function zc_config_insert_json5_from_substr(this_, key, key_len, value, value_len)
    ccall((:zc_config_insert_json5_from_substr, libzenohc), z_result_t, (Ptr{z_loaned_config_t}, Ptr{Cchar}, Csize_t, Ptr{Cchar}, Csize_t), this_, key, key_len, value, value_len)
end

function zc_config_to_string(config, out_config_string)
    ccall((:zc_config_to_string, libzenohc), z_result_t, (Ptr{z_loaned_config_t}, Ptr{z_owned_string_t}), config, out_config_string)
end

function zc_init_log_from_env_or(fallback_filter)
    ccall((:zc_init_log_from_env_or, libzenohc), z_result_t, (Ptr{Cchar},), fallback_filter)
end

function zc_init_log_with_callback(min_severity, callback)
    ccall((:zc_init_log_with_callback, libzenohc), Cvoid, (zc_log_severity_t, Ptr{zc_moved_closure_log_t}), min_severity, callback)
end

function zc_internal_encoding_from_data(this_, data)
    ccall((:zc_internal_encoding_from_data, libzenohc), Cvoid, (Ptr{z_owned_encoding_t}, zc_internal_encoding_data_t), this_, data)
end

function zc_internal_encoding_get_data(this_)
    ccall((:zc_internal_encoding_get_data, libzenohc), zc_internal_encoding_data_t, (Ptr{z_loaned_encoding_t},), this_)
end

function zc_stop_z_runtime()
    ccall((:zc_stop_z_runtime, libzenohc), Cvoid, ())
end

function zc_try_init_log_from_env()
    ccall((:zc_try_init_log_from_env, libzenohc), Cvoid, ())
end

function ze_deserialize_bool(this_, dst)
    ccall((:ze_deserialize_bool, libzenohc), z_result_t, (Ptr{z_loaned_bytes_t}, Ptr{Bool}), this_, dst)
end

function ze_deserialize_double(this_, dst)
    ccall((:ze_deserialize_double, libzenohc), z_result_t, (Ptr{z_loaned_bytes_t}, Ptr{Cdouble}), this_, dst)
end

function ze_deserialize_float(this_, dst)
    ccall((:ze_deserialize_float, libzenohc), z_result_t, (Ptr{z_loaned_bytes_t}, Ptr{Cfloat}), this_, dst)
end

function ze_deserialize_int16(this_, dst)
    ccall((:ze_deserialize_int16, libzenohc), z_result_t, (Ptr{z_loaned_bytes_t}, Ptr{Int16}), this_, dst)
end

function ze_deserialize_int32(this_, dst)
    ccall((:ze_deserialize_int32, libzenohc), z_result_t, (Ptr{z_loaned_bytes_t}, Ptr{Int32}), this_, dst)
end

function ze_deserialize_int64(this_, dst)
    ccall((:ze_deserialize_int64, libzenohc), z_result_t, (Ptr{z_loaned_bytes_t}, Ptr{Int64}), this_, dst)
end

function ze_deserialize_int8(this_, dst)
    ccall((:ze_deserialize_int8, libzenohc), z_result_t, (Ptr{z_loaned_bytes_t}, Ptr{Int8}), this_, dst)
end

function ze_deserialize_slice(this_, slice)
    ccall((:ze_deserialize_slice, libzenohc), z_result_t, (Ptr{z_loaned_bytes_t}, Ptr{z_owned_slice_t}), this_, slice)
end

function ze_deserialize_string(this_, str)
    ccall((:ze_deserialize_string, libzenohc), z_result_t, (Ptr{z_loaned_bytes_t}, Ptr{z_owned_string_t}), this_, str)
end

function ze_deserialize_uint16(this_, dst)
    ccall((:ze_deserialize_uint16, libzenohc), z_result_t, (Ptr{z_loaned_bytes_t}, Ptr{UInt16}), this_, dst)
end

function ze_deserialize_uint32(this_, dst)
    ccall((:ze_deserialize_uint32, libzenohc), z_result_t, (Ptr{z_loaned_bytes_t}, Ptr{UInt32}), this_, dst)
end

function ze_deserialize_uint64(this_, dst)
    ccall((:ze_deserialize_uint64, libzenohc), z_result_t, (Ptr{z_loaned_bytes_t}, Ptr{UInt64}), this_, dst)
end

function ze_deserialize_uint8(this_, dst)
    ccall((:ze_deserialize_uint8, libzenohc), z_result_t, (Ptr{z_loaned_bytes_t}, Ptr{UInt8}), this_, dst)
end

function ze_deserializer_deserialize_bool(this_, dst)
    ccall((:ze_deserializer_deserialize_bool, libzenohc), z_result_t, (Ptr{ze_deserializer_t}, Ptr{Bool}), this_, dst)
end

function ze_deserializer_deserialize_double(this_, dst)
    ccall((:ze_deserializer_deserialize_double, libzenohc), z_result_t, (Ptr{ze_deserializer_t}, Ptr{Cdouble}), this_, dst)
end

function ze_deserializer_deserialize_float(this_, dst)
    ccall((:ze_deserializer_deserialize_float, libzenohc), z_result_t, (Ptr{ze_deserializer_t}, Ptr{Cfloat}), this_, dst)
end

function ze_deserializer_deserialize_int16(this_, dst)
    ccall((:ze_deserializer_deserialize_int16, libzenohc), z_result_t, (Ptr{ze_deserializer_t}, Ptr{Int16}), this_, dst)
end

function ze_deserializer_deserialize_int32(this_, dst)
    ccall((:ze_deserializer_deserialize_int32, libzenohc), z_result_t, (Ptr{ze_deserializer_t}, Ptr{Int32}), this_, dst)
end

function ze_deserializer_deserialize_int64(this_, dst)
    ccall((:ze_deserializer_deserialize_int64, libzenohc), z_result_t, (Ptr{ze_deserializer_t}, Ptr{Int64}), this_, dst)
end

function ze_deserializer_deserialize_int8(this_, dst)
    ccall((:ze_deserializer_deserialize_int8, libzenohc), z_result_t, (Ptr{ze_deserializer_t}, Ptr{Int8}), this_, dst)
end

function ze_deserializer_deserialize_sequence_length(this_, len)
    ccall((:ze_deserializer_deserialize_sequence_length, libzenohc), z_result_t, (Ptr{ze_deserializer_t}, Ptr{Csize_t}), this_, len)
end

function ze_deserializer_deserialize_slice(this_, slice)
    ccall((:ze_deserializer_deserialize_slice, libzenohc), z_result_t, (Ptr{ze_deserializer_t}, Ptr{z_owned_slice_t}), this_, slice)
end

function ze_deserializer_deserialize_string(this_, str)
    ccall((:ze_deserializer_deserialize_string, libzenohc), z_result_t, (Ptr{ze_deserializer_t}, Ptr{z_owned_string_t}), this_, str)
end

function ze_deserializer_deserialize_uint16(this_, dst)
    ccall((:ze_deserializer_deserialize_uint16, libzenohc), z_result_t, (Ptr{ze_deserializer_t}, Ptr{UInt16}), this_, dst)
end

function ze_deserializer_deserialize_uint32(this_, dst)
    ccall((:ze_deserializer_deserialize_uint32, libzenohc), z_result_t, (Ptr{ze_deserializer_t}, Ptr{UInt32}), this_, dst)
end

function ze_deserializer_deserialize_uint64(this_, dst)
    ccall((:ze_deserializer_deserialize_uint64, libzenohc), z_result_t, (Ptr{ze_deserializer_t}, Ptr{UInt64}), this_, dst)
end

function ze_deserializer_deserialize_uint8(this_, dst)
    ccall((:ze_deserializer_deserialize_uint8, libzenohc), z_result_t, (Ptr{ze_deserializer_t}, Ptr{UInt8}), this_, dst)
end

function ze_deserializer_from_bytes(this_)
    ccall((:ze_deserializer_from_bytes, libzenohc), ze_deserializer_t, (Ptr{z_loaned_bytes_t},), this_)
end

function ze_deserializer_is_done(this_)
    ccall((:ze_deserializer_is_done, libzenohc), Bool, (Ptr{ze_deserializer_t},), this_)
end

function ze_serialize_bool(this_, val)
    ccall((:ze_serialize_bool, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, Bool), this_, val)
end

function ze_serialize_buf(this_, data, len)
    ccall((:ze_serialize_buf, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, Ptr{UInt8}, Csize_t), this_, data, len)
end

function ze_serialize_double(this_, val)
    ccall((:ze_serialize_double, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, Cdouble), this_, val)
end

function ze_serialize_float(this_, val)
    ccall((:ze_serialize_float, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, Cfloat), this_, val)
end

function ze_serialize_int16(this_, val)
    ccall((:ze_serialize_int16, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, Int16), this_, val)
end

function ze_serialize_int32(this_, val)
    ccall((:ze_serialize_int32, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, Int32), this_, val)
end

function ze_serialize_int64(this_, val)
    ccall((:ze_serialize_int64, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, Int64), this_, val)
end

function ze_serialize_int8(this_, val)
    ccall((:ze_serialize_int8, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, Int8), this_, val)
end

function ze_serialize_slice(this_, slice)
    ccall((:ze_serialize_slice, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, Ptr{z_loaned_slice_t}), this_, slice)
end

function ze_serialize_str(this_, str)
    ccall((:ze_serialize_str, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, Ptr{Cchar}), this_, str)
end

function ze_serialize_string(this_, str)
    ccall((:ze_serialize_string, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, Ptr{z_loaned_string_t}), this_, str)
end

function ze_serialize_substr(this_, start, len)
    ccall((:ze_serialize_substr, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, Ptr{Cchar}, Csize_t), this_, start, len)
end

function ze_serialize_uint16(this_, val)
    ccall((:ze_serialize_uint16, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, UInt16), this_, val)
end

function ze_serialize_uint32(this_, val)
    ccall((:ze_serialize_uint32, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, UInt32), this_, val)
end

function ze_serialize_uint64(this_, val)
    ccall((:ze_serialize_uint64, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, UInt64), this_, val)
end

function ze_serialize_uint8(this_, val)
    ccall((:ze_serialize_uint8, libzenohc), z_result_t, (Ptr{z_owned_bytes_t}, UInt8), this_, val)
end

function ze_serializer_empty(this_)
    ccall((:ze_serializer_empty, libzenohc), z_result_t, (Ptr{ze_owned_serializer_t},), this_)
end

function ze_serializer_finish(this_, bytes)
    ccall((:ze_serializer_finish, libzenohc), Cvoid, (Ptr{ze_moved_serializer_t}, Ptr{z_owned_bytes_t}), this_, bytes)
end

function ze_serializer_serialize_bool(this_, val)
    ccall((:ze_serializer_serialize_bool, libzenohc), z_result_t, (Ptr{ze_loaned_serializer_t}, Bool), this_, val)
end

function ze_serializer_serialize_buf(this_, data, len)
    ccall((:ze_serializer_serialize_buf, libzenohc), z_result_t, (Ptr{ze_loaned_serializer_t}, Ptr{UInt8}, Csize_t), this_, data, len)
end

function ze_serializer_serialize_double(this_, val)
    ccall((:ze_serializer_serialize_double, libzenohc), z_result_t, (Ptr{ze_loaned_serializer_t}, Cdouble), this_, val)
end

function ze_serializer_serialize_float(this_, val)
    ccall((:ze_serializer_serialize_float, libzenohc), z_result_t, (Ptr{ze_loaned_serializer_t}, Cfloat), this_, val)
end

function ze_serializer_serialize_int16(this_, val)
    ccall((:ze_serializer_serialize_int16, libzenohc), z_result_t, (Ptr{ze_loaned_serializer_t}, Int16), this_, val)
end

function ze_serializer_serialize_int32(this_, val)
    ccall((:ze_serializer_serialize_int32, libzenohc), z_result_t, (Ptr{ze_loaned_serializer_t}, Int32), this_, val)
end

function ze_serializer_serialize_int64(this_, val)
    ccall((:ze_serializer_serialize_int64, libzenohc), z_result_t, (Ptr{ze_loaned_serializer_t}, Int64), this_, val)
end

function ze_serializer_serialize_int8(this_, val)
    ccall((:ze_serializer_serialize_int8, libzenohc), z_result_t, (Ptr{ze_loaned_serializer_t}, Int8), this_, val)
end

function ze_serializer_serialize_sequence_length(this_, len)
    ccall((:ze_serializer_serialize_sequence_length, libzenohc), z_result_t, (Ptr{ze_loaned_serializer_t}, Csize_t), this_, len)
end

function ze_serializer_serialize_slice(this_, slice)
    ccall((:ze_serializer_serialize_slice, libzenohc), z_result_t, (Ptr{ze_loaned_serializer_t}, Ptr{z_loaned_slice_t}), this_, slice)
end

function ze_serializer_serialize_str(this_, str)
    ccall((:ze_serializer_serialize_str, libzenohc), z_result_t, (Ptr{ze_loaned_serializer_t}, Ptr{Cchar}), this_, str)
end

function ze_serializer_serialize_string(this_, str)
    ccall((:ze_serializer_serialize_string, libzenohc), z_result_t, (Ptr{ze_loaned_serializer_t}, Ptr{z_loaned_string_t}), this_, str)
end

function ze_serializer_serialize_substr(this_, start, len)
    ccall((:ze_serializer_serialize_substr, libzenohc), z_result_t, (Ptr{ze_loaned_serializer_t}, Ptr{Cchar}, Csize_t), this_, start, len)
end

function ze_serializer_serialize_uint16(this_, val)
    ccall((:ze_serializer_serialize_uint16, libzenohc), z_result_t, (Ptr{ze_loaned_serializer_t}, UInt16), this_, val)
end

function ze_serializer_serialize_uint32(this_, val)
    ccall((:ze_serializer_serialize_uint32, libzenohc), z_result_t, (Ptr{ze_loaned_serializer_t}, UInt32), this_, val)
end

function ze_serializer_serialize_uint64(this_, val)
    ccall((:ze_serializer_serialize_uint64, libzenohc), z_result_t, (Ptr{ze_loaned_serializer_t}, UInt64), this_, val)
end

function ze_serializer_serialize_uint8(this_, val)
    ccall((:ze_serializer_serialize_uint8, libzenohc), z_result_t, (Ptr{ze_loaned_serializer_t}, UInt8), this_, val)
end

# typedef void ( * z_closure_drop_callback_t ) ( void * context )
const z_closure_drop_callback_t = Ptr{Cvoid}

# typedef void ( * z_closure_hello_callback_t ) ( z_loaned_hello_t * hello , void * context )
const z_closure_hello_callback_t = Ptr{Cvoid}

# typedef void ( * z_closure_query_callback_t ) ( z_loaned_query_t * query , void * context )
const z_closure_query_callback_t = Ptr{Cvoid}

# typedef void ( * z_closure_reply_callback_t ) ( z_loaned_reply_t * reply , void * context )
const z_closure_reply_callback_t = Ptr{Cvoid}

# typedef void ( * z_closure_sample_callback_t ) ( z_loaned_sample_t * sample , void * context )
const z_closure_sample_callback_t = Ptr{Cvoid}

# typedef void ( * z_closure_zid_callback_t ) ( const z_id_t * z_id , void * context )
const z_closure_zid_callback_t = Ptr{Cvoid}

# typedef void ( * zc_closure_log_callback_t ) ( zc_log_severity_t severity , const z_loaned_string_t * msg , void * context )
const zc_closure_log_callback_t = Ptr{Cvoid}

function z_malloc(size)
    ccall((:z_malloc, libzenohc), Ptr{Cvoid}, (Csize_t,), size)
end

function z_realloc(ptr, size)
    ccall((:z_realloc, libzenohc), Ptr{Cvoid}, (Ptr{Cvoid}, Csize_t), ptr, size)
end

function z_free(ptr)
    ccall((:z_free, libzenohc), Cvoid, (Ptr{Cvoid},), ptr)
end

const ZENOH_C = "1.3.3"

const ZENOH_C_MAJOR = 1

const ZENOH_C_MINOR = 3

const ZENOH_C_PATCH = 3

const DEFAULT_SCOUTING_TIMEOUT = 1000

const Z_CHANNEL_DISCONNECTED = 1

const Z_CHANNEL_NODATA = 2

const Z_OK = 0

const Z_EINVAL = -1

const Z_EPARSE = -2

const Z_EIO = -3

const Z_ENETWORK = -4

const Z_ENULL = -5

const Z_EUNAVAILABLE = -6

const Z_EDESERIALIZE = -7

const Z_ESESSION_CLOSED = -8

const Z_EUTF8 = -9

const Z_EBUSY_MUTEX = -16

const Z_EINVAL_MUTEX = -22

const Z_EAGAIN_MUTEX = -11

const Z_EPOISON_MUTEX = -22

const Z_EGENERIC = INT8_MIN

const Z_CONGESTION_CONTROL_DEFAULT = Z_CONGESTION_CONTROL_DROP

const Z_CONSOLIDATION_MODE_DEFAULT = Z_CONSOLIDATION_MODE_AUTO

const Z_PRIORITY_DEFAULT = Z_PRIORITY_DATA

const Z_QUERY_TARGET_DEFAULT = Z_QUERY_TARGET_BEST_MATCHING

const Z_SAMPLE_KIND_DEFAULT = Z_SAMPLE_KIND_PUT

const Z_CONFIG_MODE_KEY = "mode"

const Z_CONFIG_CONNECT_KEY = "connect/endpoints"

const Z_CONFIG_LISTEN_KEY = "listen/endpoints"

const Z_CONFIG_USER_KEY = "transport/auth/usrpwd/user"

const Z_CONFIG_PASSWORD_KEY = "transport/auth/usrpwd/password"

const Z_CONFIG_MULTICAST_SCOUTING_KEY = "scouting/multicast/enabled"

const Z_CONFIG_MULTICAST_INTERFACE_KEY = "scouting/multicast/interface"

const Z_CONFIG_MULTICAST_IPV4_ADDRESS_KEY = "scouting/multicast/address"

const Z_CONFIG_SCOUTING_DELAY_KEY = "scouting/delay"

const Z_CONFIG_SCOUTING_TIMEOUT_KEY = "scouting/timeout"

const Z_CONFIG_ADD_TIMESTAMP_KEY = "timestamping/enabled"

const Z_CONFIG_SHARED_MEMORY_KEY = "transport/shared_memory/enabled"

# exports
const PREFIXES = ["z_", "zc_", "ze_"]
for name in names(@__MODULE__; all=true), prefix in PREFIXES
    if startswith(string(name), prefix)
        @eval export $name
    end
end

end # module
