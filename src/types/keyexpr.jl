# Keyexpr — owned key expression handle plus relations, composition,
# canonicalization, and the `kexpr"…"` string macro.

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
    # Wrap a z_owned_keyexpr_t that a C builder (z_keyexpr_concat/join, …)
    # has already populated; just attach the drop finalizer.
    function Keyexpr(k::Base.RefValue{LibZenohC.z_owned_keyexpr_t}, ::Val{:owned})
        finalizer(k -> LibZenohC.z_keyexpr_drop(_move(k)), k)
        return new(k)
    end
end

_loan(s::Keyexpr) = _loan(s.k)

export Keyexpr, @kexpr_str
export includes, intersects, concat, canonize, is_canon
export relation_to, IntersectionLevel, IntersectionLevels

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

# ── relation_to / IntersectionLevel ─────────────────────────────────────
#
# The full lattice relationship between two keyexprs' key-sets, as a
# typed singleton (same pattern as the QoS enums in qos.jl).
#
# Keyexprs denote *sets* of keys, but zenoh offers no set-valued union or
# intersection — the result generally isn't expressible as a single
# keyexpr. So we expose the *relationship* rather than `∪`/`∩`, and map it
# onto Julia's set-comparison predicates: `a ⊆ b` (`issubset`) and
# `isdisjoint(a, b)`, alongside the existing `includes` (⊇) / `intersects`.

module IntersectionLevels
    import ..LibZenohC

    abstract type IntersectionLevel end

    struct Disjoint   <: IntersectionLevel end
    struct Intersects <: IntersectionLevel end
    struct Includes   <: IntersectionLevel end
    struct Equals     <: IntersectionLevel end

    const DISJOINT   = Disjoint()
    const INTERSECTS = Intersects()
    const INCLUDES   = Includes()
    const EQUALS     = Equals()
end

const IntersectionLevel = IntersectionLevels.IntersectionLevel

_raw(::IntersectionLevels.Disjoint)   = LibZenohC.Z_KEYEXPR_INTERSECTION_LEVEL_DISJOINT
_raw(::IntersectionLevels.Intersects) = LibZenohC.Z_KEYEXPR_INTERSECTION_LEVEL_INTERSECTS
_raw(::IntersectionLevels.Includes)   = LibZenohC.Z_KEYEXPR_INTERSECTION_LEVEL_INCLUDES
_raw(::IntersectionLevels.Equals)     = LibZenohC.Z_KEYEXPR_INTERSECTION_LEVEL_EQUALS

function _intersection_level_from_raw(v::LibZenohC.z_keyexpr_intersection_level_t)
    v == LibZenohC.Z_KEYEXPR_INTERSECTION_LEVEL_DISJOINT   && return IntersectionLevels.DISJOINT
    v == LibZenohC.Z_KEYEXPR_INTERSECTION_LEVEL_INTERSECTS && return IntersectionLevels.INTERSECTS
    v == LibZenohC.Z_KEYEXPR_INTERSECTION_LEVEL_INCLUDES   && return IntersectionLevels.INCLUDES
    v == LibZenohC.Z_KEYEXPR_INTERSECTION_LEVEL_EQUALS     && return IntersectionLevels.EQUALS
    throw(ArgumentError("unknown z_keyexpr_intersection_level_t value: $v"))
end

Base.show(io::IO, ::IntersectionLevels.Disjoint)   = print(io, "IntersectionLevels.DISJOINT")
Base.show(io::IO, ::IntersectionLevels.Intersects) = print(io, "IntersectionLevels.INTERSECTS")
Base.show(io::IO, ::IntersectionLevels.Includes)   = print(io, "IntersectionLevels.INCLUDES")
Base.show(io::IO, ::IntersectionLevels.Equals)     = print(io, "IntersectionLevels.EQUALS")

"""
    relation_to(a::Keyexpr, b::Keyexpr) -> IntersectionLevel

`a`'s key-set relationship to `b`'s, as an [`IntersectionLevel`](@ref):
`DISJOINT` (no shared key), `INTERSECTS` (overlap, neither contains the
other), `INCLUDES` (`a` ⊇ `b`), or `EQUALS` (same key-set). This is the
lattice level behind [`includes`](@ref), [`intersects`](@ref),
[`issubset`](@ref), and [`isdisjoint`](@ref).

Note `EQUALS` is *set* equality, which can differ from `==` (canonical
string equality) — e.g. `a/**` and `a/**/**` are set-equal but not
string-equal.
"""
function relation_to(a::Keyexpr, b::Keyexpr)
    return _intersection_level_from_raw(
        LibZenohC.z_keyexpr_relation_to(_loan(a.k), _loan(b.k)))
end

"""
    issubset(a::Keyexpr, b::Keyexpr) -> Bool

`true` when every key matched by `a` is also matched by `b` (`a ⊆ b`);
the `⊆` operator works too. Dual of [`includes`](@ref) (`a ⊆ b ⟺ b ⊇ a`).
"""
Base.issubset(a::Keyexpr, b::Keyexpr) = includes(b, a)

"""
    isdisjoint(a::Keyexpr, b::Keyexpr) -> Bool

`true` when no key is matched by both — the negation of
[`intersects`](@ref).
"""
Base.isdisjoint(a::Keyexpr, b::Keyexpr) = !intersects(a, b)

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

# ============================================================
# kexpr"…" with $name / $(expr) interpolation
# ============================================================
#
# Naive `Keyexpr("prefix/$(string(x))/suffix")` builds two transient
# Julia Strings per interpolation (the `string(x)` and the spliced
# whole) before handing the bytes to libzenohc, which then copies them
# again into the owned keyexpr. The macro below collapses all of that:
#
#   1. For each piece, get a `(ptr, len, pin)` view. Keyexpr pieces use
#      `z_keyexpr_as_view_string` — a non-owning view over the keyexpr's
#      canonical-storage bytes, no copy. `String`/`AbstractString` pieces
#      hand back their own byte pointer. The `pin` field keeps the
#      source alive while we read it.
#   2. Allocate one `Vector{UInt8}` sized to the total, `unsafe_copyto!`
#      every piece into it.
#   3. Call `z_keyexpr_from_substr{,_autocanonize}` once on that buffer.
#
# Cost per call: 1 buffer + 1 owned-keyexpr ref + N transient view refs
# (~32 B each, freed after expansion). No intermediate Julia Strings.

# Per-piece view used inside the generated code. The returned `pin`
# keeps the source memory alive — for Keyexpr that's the Keyexpr itself
# (the view's data pointer dereferences into its canonical storage),
# for String it's the String. Inlined so the tuple stays in registers.
@inline function _kexpr_view(k::Keyexpr)
    view = Ref{LibZenohC.z_view_string_t}()
    LibZenohC.z_keyexpr_as_view_string(_loan(k.k), view)
    loaned = LibZenohC.z_view_string_loan(view)
    return (Ptr{UInt8}(LibZenohC.z_string_data(loaned)),
            LibZenohC.z_string_len(loaned),
            k)
end

@inline _kexpr_view(s::String) =
    (Base.unsafe_convert(Ptr{UInt8}, s), Csize_t(sizeof(s)), s)

@inline _kexpr_view(s::AbstractString) = _kexpr_view(String(s))

# Split a kexpr"…" template into an alternating list of String (literal)
# and Symbol/Expr (interpolation) pieces. Supports `$name` and `$(expr)`.
function _parse_kexpr_template(s::AbstractString)
    pieces = Any[]
    buf = IOBuffer()
    i = firstindex(s)
    n = lastindex(s)
    while i <= n
        c = s[i]
        if c == '$'
            lit = String(take!(buf))
            isempty(lit) || push!(pieces, lit)
            j = nextind(s, i)
            j > n && throw(ArgumentError("trailing `\$` in kexpr template"))
            if s[j] == '('
                depth = 1
                k = nextind(s, j)
                while k <= n
                    if s[k] == '('
                        depth += 1
                    elseif s[k] == ')'
                        depth -= 1
                        depth == 0 && break
                    end
                    k = nextind(s, k)
                end
                depth == 0 || throw(ArgumentError("unmatched `\$(` in kexpr template"))
                expr_str = s[nextind(s, j):prevind(s, k)]
                push!(pieces, Meta.parse(expr_str))
                i = nextind(s, k)
            elseif Base.is_id_start_char(s[j])
                k = j
                while k <= n && Base.is_id_char(s[k])
                    k = nextind(s, k)
                end
                push!(pieces, Symbol(s[j:prevind(s, k)]))
                i = k
            else
                throw(ArgumentError(
                    "invalid kexpr interpolation: `\$$(s[j])` (use \$name or \$(expr))"))
            end
        else
            print(buf, c)
            i = nextind(s, i)
        end
    end
    lit = String(take!(buf))
    isempty(lit) || push!(pieces, lit)
    return pieces
end

# Emit the inline buffer-assembly code for an interpolated template.
function _kexpr_emit_interp(pieces::Vector, autocanonize::Bool)
    n = length(pieces)
    vs = [gensym(:v) for _ in 1:n]
    total = gensym(:total)
    buf = gensym(:buf)
    offset = gensym(:off)
    out = gensym(:out)

    view_assigns = Expr[]
    for (i, p) in enumerate(pieces)
        rhs = p isa String ? :(_kexpr_view($p)) : :(_kexpr_view($(esc(p))))
        push!(view_assigns, :(local $(vs[i]) = $rhs))
    end

    total_expr = foldl((a, b) -> :($a + $b),
                      [:($(v)[2]) for v in vs])

    copy_block = Expr[:(local $offset = 0)]
    for v in vs
        push!(copy_block,
            :(unsafe_copyto!(pointer($buf, $offset + 1), $(v)[1], $(v)[2])))
        push!(copy_block, :($offset += Int($(v)[2])))
    end

    from_call = if autocanonize
        lr = gensym(:lr)
        quote
            local $lr = Ref{Csize_t}($total)
            _handle_result(LibZenohC.z_keyexpr_from_substr_autocanonize(
                $out, pointer($buf), $lr))
        end
    else
        :(_handle_result(LibZenohC.z_keyexpr_from_substr(
            $out, pointer($buf), $total)))
    end

    return quote
        $(view_assigns...)
        local $total = $total_expr
        local $buf = Vector{UInt8}(undef, $total)
        GC.@preserve $(vs...) begin
            $(copy_block...)
        end
        local $out = Ref{LibZenohC.z_owned_keyexpr_t}()
        GC.@preserve $buf $from_call
        Keyexpr($out, Val(:owned))
    end
end

"""
    kexpr"key/expr"
    kexpr"key//expr"c
    kexpr"prefix/\$inner/suffix"
    kexpr"\$a/\$(b)"c

String macro for [`Keyexpr`](@ref). Supports `\$name` and `\$(expr)`
interpolation of `Keyexpr` or `AbstractString` values.

The interpolating form assembles the result in a single byte buffer
with one `z_keyexpr_from_substr` call — `Keyexpr` pieces are read via
`z_keyexpr_as_view_string` directly out of their canonical-storage
bytes, so no intermediate Julia `String` is constructed per
interpolation.

The `c` flag opts into autocanonicalization (collapses `//`, `**/**`,
…). Without it, the assembled result must already be canonical or the
call throws [`ZenohError`](@ref).
"""
macro kexpr_str(s, flags="")
    autocanonize = false
    for c in flags
        c == 'c' || throw(ArgumentError("unknown kexpr flag '$c'; only 'c' is supported"))
        autocanonize = true
    end
    pieces = _parse_kexpr_template(s)
    has_interp = any(p -> !(p isa String), pieces)
    if !has_interp
        # No-interp fast path — preserves the pre-interpolation behavior.
        return :(Keyexpr($s; autocanonize=$autocanonize))
    end
    return _kexpr_emit_interp(pieces, autocanonize)
end
