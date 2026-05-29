# Structured (de)serialization — a Julia wrapper over zenoh's `ze_*` serializer
# family. This is the portable, framed, cross-language encoding (length-prefixed
# variable data, defined-endian scalars, sequence framing) — NOT a raw isbits
# reinterpret. For zero-copy raw-memory views of isbits payloads use `borrow` /
# `zref` (types/zref.jl); that is a different, non-composable mechanism.
#
# Two cursor handles mirror the `ZBytesWriter` lifecycle (types/bytes.jl):
#   • ZSerializer   — append typed values, then `finish` into a payload.
#   • ZDeserializer — read typed values off a received payload, in order.
#
# The handles deliberately encapsulate `ZBytes`: a deserializer is built from a
# `Sample` (or a `ZBytes`) and yields owned Julia values; a serializer's `finish`
# produces the payload you hand to `put`/`reply`. Normal use never names `ZBytes`.
#
# The handles are NOT `<: IO`. We reuse the `read`/`write` verbs because the API
# is a cursor, but a structured codec is a *typed-value* stream, not a *byte*
# stream: it can't honour the `IO` byte contract (`unsafe_read`/`unsafe_write`),
# and Julia's generic `write(io, x) = unsafe_write(io, Ref(x), sizeof(x))` would
# emit raw bytes instead of the framed encoding. By defining `Base.read`/
# `Base.write` methods directly on our own handle types (not piracy — we own the
# types) only the methods below exist; there is no generic byte-IO fallback.
#
# Extending to new value types is one `write` + one `read` method each (the
# method-table pattern, cf. `_raw`/`_from_raw` in core/qos.jl).

# ── ZSerializer ─────────────────────────────────────────────────────────

"""
    ZSerializer()

A cursor that accumulates typed values in zenoh's structured format. Append with
`write(s, x)`, then `finish(s)` to produce the payload (consumes the serializer),
or `close(s)` to discard an unfinished one. Prefer the do-block
`open(ZSerializer) do s … end`, which finishes on success and closes on error,
or the one-shot [`serialize`](@ref).

Carries no finalizer — same rationale as `ZBytesWriter`; clean up with `finish`
or `close` on the caller's task.
"""
mutable struct ZSerializer
    s::Base.RefValue{LibZenohC.ze_owned_serializer_t}
    done::Bool
    function ZSerializer()
        s = Ref{LibZenohC.ze_owned_serializer_t}()
        _handle_result(LibZenohC.ze_serializer_empty(s))
        return new(s, false)
    end
end

# `ze_serializer_finish` moves the serializer and writes an owned bytes; the
# serializer is dead afterwards (guard via `done`). The owned ZBytes carries no
# finalizer — the caller must move-on-send (`put`/`reply`) or `close` it.
function finish(s::ZSerializer)
    s.done && error("ZSerializer already finished")
    b = Ref{LibZenohC.z_owned_bytes_t}()
    LibZenohC.ze_serializer_finish(_move(s.s), b)
    s.done = true
    return ZBytes(b, Val(:owned))
end

function Base.close(s::ZSerializer)
    s.done && return nothing
    s.done = true
    LibZenohC.ze_serializer_drop(_move(s.s))
    return nothing
end

function Base.open(f::Function, ::Type{ZSerializer})
    s = ZSerializer()
    try
        f(s)
        return finish(s)
    catch
        close(s)
        rethrow()
    end
end

# Loaned serializer pointer for the per-type serialize ops.
@inline _ser_loan(s::ZSerializer) =
    (s.done && error("write to a finished ZSerializer"); _loan_mut(s.s))

# ── ZDeserializer ───────────────────────────────────────────────────────

"""
    ZDeserializer(sample::Sample)
    ZDeserializer(z::ZBytes)

A cursor over a received payload. Read values back in the order they were written
with `read(d, T)`; `is_done(d)` reports whether the payload is exhausted. Prefer
the one-shot [`deserialize`](@ref).

`ze_deserializer_t` is a by-value cursor that borrows from the payload buffer, so
the handle pins its source (`src`) for its whole life — read or copy out before
the originating sample/callback returns.
"""
mutable struct ZDeserializer
    d::Base.RefValue{LibZenohC.ze_deserializer_t}
    src::Any   # pins the payload source (a loaned ZBytes, which pins its Sample)
    function ZDeserializer(z::ZBytes)
        d = Ref(LibZenohC.ze_deserializer_from_bytes(_loaned_bytes(z)))
        return new(d, z)
    end
end
ZDeserializer(s::Sample) = ZDeserializer(payload(s))

@inline _deser_ptr(d::ZDeserializer) =
    Base.unsafe_convert(Ptr{LibZenohC.ze_deserializer_t}, d.d)

"""
    is_done(d::ZDeserializer) -> Bool

`true` once every value has been read off the cursor.
"""
is_done(d::ZDeserializer) = GC.@preserve d LibZenohC.ze_deserializer_is_done(_deser_ptr(d))

# ── Extension point = public API: Base.write / Base.read ─────────────────
#
# New value types add one `write(::ZSerializer, ::T)` and one
# `read(::ZDeserializer, ::Type{T})`. `write` returns nothing.

# Int64
function Base.write(s::ZSerializer, x::Int64)
    _handle_result(LibZenohC.ze_serializer_serialize_int64(_ser_loan(s), x))
    return nothing
end
function Base.read(d::ZDeserializer, ::Type{Int64})
    out = Ref{Int64}()
    GC.@preserve d _handle_result(LibZenohC.ze_deserializer_deserialize_int64(_deser_ptr(d), out))
    return out[]
end

# UInt8 (also the element op behind the fixed-array path)
function Base.write(s::ZSerializer, x::UInt8)
    _handle_result(LibZenohC.ze_serializer_serialize_uint8(_ser_loan(s), x))
    return nothing
end
function Base.read(d::ZDeserializer, ::Type{UInt8})
    out = Ref{UInt8}()
    GC.@preserve d _handle_result(LibZenohC.ze_deserializer_deserialize_uint8(_deser_ptr(d), out))
    return out[]
end

# Vector{UInt8} — length-prefixed byte buffer (zenoh `Vec<u8>` shape).
function Base.write(s::ZSerializer, x::Vector{UInt8})
    lp = _ser_loan(s)
    GC.@preserve x _handle_result(
        LibZenohC.ze_serializer_serialize_buf(lp, pointer(x), Csize_t(length(x))))
    return nothing
end
function Base.read(d::ZDeserializer, ::Type{Vector{UInt8}})
    sl = Ref{LibZenohC.z_owned_slice_t}()
    GC.@preserve d _handle_result(LibZenohC.ze_deserializer_deserialize_slice(_deser_ptr(d), sl))
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

# NTuple{N,UInt8} — fixed-width, no length prefix (zenoh `[u8; N]` shape).
function Base.write(s::ZSerializer, x::NTuple{N,UInt8}) where {N}
    lp = _ser_loan(s)
    for b in x
        _handle_result(LibZenohC.ze_serializer_serialize_uint8(lp, b))
    end
    return nothing
end
function Base.read(d::ZDeserializer, ::Type{NTuple{N,UInt8}}) where {N}
    out = Ref{UInt8}()
    return ntuple(Val(N)) do _
        GC.@preserve d _handle_result(LibZenohC.ze_deserializer_deserialize_uint8(_deser_ptr(d), out))
        out[]
    end
end

# Tuple composite — concatenation of element encodings. NTuple{N,UInt8} is more
# specific than Tuple, so the fixed-array method above wins for it.
function Base.write(s::ZSerializer, x::Tuple)
    for el in x
        write(s, el)
    end
    return nothing
end
function Base.read(d::ZDeserializer, ::Type{T}) where {T<:Tuple}
    return ntuple(i -> read(d, fieldtype(T, i)), Val(fieldcount(T)))
end

# ── One-shot convenience (ZBytes-free at the call site) ──────────────────

"""
    serialize(x) -> payload

Serialize `x` into a payload ready for `put`/`reply` (`serialize` owns the
intermediate buffer — you do not handle it directly). `x` may be a single
supported value or a `Tuple` of them.

    put(pub, Zenoh.serialize((Int64(42), id16)))
"""
serialize(x) = open(ZSerializer) do s
    write(s, x)
end

"""
    deserialize(T, src) -> T::T

Read a `T` back from a received payload `src` (a [`Sample`](@ref) or `ZBytes`),
returning owned Julia values. `T` may be a single supported type or a `Tuple`
type for a composite payload.

    (seq, id) = Zenoh.deserialize(Tuple{Int64,Vector{UInt8}}, sample)
"""
deserialize(::Type{T}, src) where {T} = read(ZDeserializer(src), T)

export ZSerializer, ZDeserializer
