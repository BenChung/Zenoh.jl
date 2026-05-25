# Keyexpr utilities — relations, composition, canonicalization.
#
# The Keyexpr struct (and its from-string constructors) lives in
# Zenoh.jl. This file layers user-facing operations on top.

function _as_view_string(k::Keyexpr)
    view = Ref{LibZenohC.z_view_string_t}()
    LibZenohC.z_keyexpr_as_view_string(_loan(k.k), view)
    loaned = LibZenohC.z_view_string_loan(view)
    return unsafe_string(LibZenohC.z_string_data(loaned),
                        LibZenohC.z_string_len(loaned))
end

Base.String(k::Keyexpr) = _as_view_string(k)
Base.string(k::Keyexpr) = _as_view_string(k)
Base.print(io::IO, k::Keyexpr) = print(io, _as_view_string(k))
Base.show(io::IO, k::Keyexpr) = print(io, "Keyexpr(\"", _as_view_string(k), "\")")

function Base.:(==)(a::Keyexpr, b::Keyexpr)
    return LibZenohC.z_keyexpr_equals(_loan(a.k), _loan(b.k))
end

Base.hash(k::Keyexpr, h::UInt) = hash(_as_view_string(k), hash(:Keyexpr, h))

"""
    includes(a::Keyexpr, b::Keyexpr) -> Bool

`true` when every key matched by `b` is also matched by `a` — i.e. `a` is
a superset (or equal). Wildcard `**` includes any concrete key under it.
"""
function includes(a::Keyexpr, b::Keyexpr)
    return LibZenohC.z_keyexpr_includes(_loan(a.k), _loan(b.k))
end

"""
    intersects(a::Keyexpr, b::Keyexpr) -> Bool

`true` when at least one key is matched by both.
"""
function intersects(a::Keyexpr, b::Keyexpr)
    return LibZenohC.z_keyexpr_intersects(_loan(a.k), _loan(b.k))
end

"""
    concat(a::Keyexpr, suffix::AbstractString) -> Keyexpr

Append a raw string suffix to `a`. The suffix is concatenated verbatim —
no `/` is inserted. Use [`join`](@ref Base.join) to join two keyexprs
with a separator.
"""
function concat(a::Keyexpr, suffix::AbstractString)
    bytes = Base.codeunits(String(suffix))
    out = Ref{LibZenohC.z_owned_keyexpr_t}()
    rtc = LibZenohC.z_keyexpr_concat(out, _loan(a.k),
        pointer(bytes), Csize_t(sizeof(bytes)))
    _handle_result(rtc)
    return Keyexpr(out, Val(:owned))
end

"""
    join(a::Keyexpr, b::Keyexpr) -> Keyexpr

Join two keyexprs with a `/` separator.
"""
function Base.join(a::Keyexpr, b::Keyexpr)
    out = Ref{LibZenohC.z_owned_keyexpr_t}()
    rtc = LibZenohC.z_keyexpr_join(out, _loan(a.k), _loan(b.k))
    _handle_result(rtc)
    return Keyexpr(out, Val(:owned))
end

"""
    canonize(s::AbstractString) -> String

Return the canonical form of keyexpr string `s` (collapses `//`, `**/**`,
etc.). Throws [`ZenohError`](@ref) if `s` is not a valid key expression.
"""
function canonize(s::AbstractString)
    buf = Vector{UInt8}(codeunits(String(s)))
    len = Ref{Csize_t}(length(buf))
    rtc = LibZenohC.z_keyexpr_canonize(pointer(buf), len)
    _handle_result(rtc)
    return unsafe_string(pointer(buf), len[])
end

"""
    is_canon(s::AbstractString) -> Bool

`true` if `s` is already in canonical form.
"""
function is_canon(s::AbstractString)
    bytes = codeunits(String(s))
    rtc = LibZenohC.z_keyexpr_is_canon(pointer(bytes), Csize_t(sizeof(bytes)))
    return rtc == LibZenohC.Z_OK
end
