# DeclaredKeyexpr — a key expression registered with the session via
# `z_declare_keyexpr` (the upstream Zenoh API for a router-negotiated numeric id).
#
# !!! API-parity stub — no measured performance benefit in this libzenohc.
# Profiling (docs/design/declared-keyexpr.md) showed session-level `z_put`/`z_get`
# do NOT use a declared keyexpr's id — the full key string goes on the wire on
# every call, single- and multi-hop. A pure-C repro
# (docs/design/declared-keyexpr-libzenohc-repro.c) reproduces it against
# libzenohc directly, so it is a libzenohc/zenoh-core behavior, not a binding
# bug. A `Publisher` (`z_declare_publisher`) *does* optimize its key on the wire,
# so **prefer `Publisher`/`Querier` for repeated ops on a stable key**. This type
# exists for API parity with upstream Zenoh; it is correct and round-trips, but
# adds no wire optimization here.
#
# Design + rationale + measurements: docs/design/declared-keyexpr.md.

"""
    DeclaredKeyexpr <: AbstractKeyexpr

A key expression registered with the session via `z_declare_keyexpr`. Construct
with [`declare_keyexpr`](@ref); use it like any [`Keyexpr`](@ref) (it loans the
same way). Call [`close`](@ref) (or use the scoped `declare_keyexpr(f, s, k)`
form) to undeclare it; a finalizer is the GC safety net.

!!! warning "No performance benefit in this libzenohc"
    Session-level `put`/`get` do **not** use a declared keyexpr's numeric id on
    the wire (verified by profiling and a pure-C repro — a libzenohc/zenoh-core
    behavior, see `docs/design/declared-keyexpr.md`). For repeated operations on
    a fixed key, use a [`Publisher`](@ref) or [`Querier`](@ref), which *do*
    optimize their key. This type is provided for API parity only.
"""
mutable struct DeclaredKeyexpr <: AbstractKeyexpr
    k::Base.RefValue{LibZenohC.z_owned_keyexpr_t}  # owned handle holding the id
    session::Session                               # strong ref: outlives this, and undeclares it
    source::Keyexpr                                # GC pin for the source keyexpr
    closed::Bool
end

function _loan(d::DeclaredKeyexpr)
    d.closed && throw(ArgumentError("declared keyexpr is closed"))
    return _loan(d.k)
end

# Explicit `close` teardown, on the caller's task:
# - session open: undeclare the session-side mapping, surfacing the result.
# - session closed: free only the local owned handle; its mappings are already gone.
function _undeclare_keyexpr!(d::DeclaredKeyexpr)
    d.closed && return nothing
    d.closed = true
    if d.session.closed[]
        LibZenohC.z_keyexpr_drop(_move(d.k))
    else
        _handle_result(LibZenohC.z_undeclare_keyexpr(_loan(d.session), _move(d.k)))
    end
    return nothing
end

# GC safety net: free only the local owned keyexpr, never touch the session.
# The session may be closing or mid-drop (cross-object finalizer order is
# unspecified), and `z_undeclare_keyexpr` is a network op the repo keeps off the
# finalizer thread (see the NOTE in types/bytes.jl). The session-side declaration
# dies with the session, so this leaf drop suffices; use `close(d)` while the
# session is open for a full undeclare.
function _finalize_declared_keyexpr!(d::DeclaredKeyexpr)
    d.closed && return nothing
    d.closed = true
    LibZenohC.z_keyexpr_drop(_move(d.k))
    return nothing
end

"""
    close(d::DeclaredKeyexpr)

Undeclare the key expression, releasing its session id. Idempotent.
"""
Base.close(d::DeclaredKeyexpr) = _undeclare_keyexpr!(d)

Base.show(io::IO, d::DeclaredKeyexpr) =
    print(io, "DeclaredKeyexpr(\"", _as_view_string(d), "\")")

"""
    declare_keyexpr(s::Session, k::AbstractKeyexpr) -> DeclaredKeyexpr
    declare_keyexpr(s::Session, k::AbstractString; autocanonize=false) -> DeclaredKeyexpr

Register `k` with the session (`z_declare_keyexpr`) and return a
[`DeclaredKeyexpr`](@ref). Release with [`close`](@ref).

!!! warning "No performance benefit in this libzenohc"
    Session-level `put`/`get` do not use the declared id on the wire (see
    [`DeclaredKeyexpr`](@ref)). For repeated operations on a fixed key, use a
    [`Publisher`](@ref) or [`Querier`](@ref) instead — they optimize their key.
"""
function declare_keyexpr(s::Session, k::AbstractKeyexpr)
    declared = Ref{LibZenohC.z_owned_keyexpr_t}()
    GC.@preserve k _handle_result(
        LibZenohC.z_declare_keyexpr(_loan(s), declared, _loan(k)))
    src = k isa Keyexpr ? k : Keyexpr(String(k))
    d = DeclaredKeyexpr(declared, s, src, false)
    finalizer(_finalize_declared_keyexpr!, d)
    return d
end

declare_keyexpr(s::Session, k::AbstractString; autocanonize=false) =
    declare_keyexpr(s, Keyexpr(String(k); autocanonize))

"""
    declare_keyexpr(f::Function, s::Session, k; …)

Scoped form: declare `k`, call `f(d::DeclaredKeyexpr)`, and undeclare on exit
(even if `f` throws).
"""
function declare_keyexpr(f::Function, s::Session, k; kwargs...)
    d = declare_keyexpr(s, k; kwargs...)
    try
        return f(d)
    finally
        close(d)
    end
end

export DeclaredKeyexpr, declare_keyexpr

# Session-level operations on the declared id. These forward to the
# `Session`-keyed methods (widened to accept `AbstractKeyexpr`), so they share
# every per-call option those forms accept.
put(d::DeclaredKeyexpr, payload; kwargs...) = put(d.session, d, payload; kwargs...)
Base.delete!(d::DeclaredKeyexpr; kwargs...) = delete!(d.session, d; kwargs...)
Base.get(d::DeclaredKeyexpr, parameters::AbstractString=""; kwargs...) =
    get(d.session, d, parameters; kwargs...)
Base.get(f::Function, d::DeclaredKeyexpr, parameters::AbstractString=""; kwargs...) =
    get(f, d.session, d, parameters; kwargs...)
