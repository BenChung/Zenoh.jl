"""
    Locality(s::Symbol)
    Locality(v::LibZenohC.z_locality_t)

Origin/destination filter for Zenoh operations. Accepts `:any`,
`:session_local`, `:remote`, or `:default`. For well-known values prefer
the named constants in `Zenoh.Localities`, e.g. `Localities.REMOTE`.
"""
struct Locality
    v::LibZenohC.z_locality_t
end

Locality(s::Symbol) = Locality(_locality_sym(Val(s)))
_locality_sym(::Val{:any})           = LibZenohC.Z_LOCALITY_ANY
_locality_sym(::Val{:session_local}) = LibZenohC.Z_LOCALITY_SESSION_LOCAL
_locality_sym(::Val{:remote})        = LibZenohC.Z_LOCALITY_REMOTE
_locality_sym(::Val{:default})       = LibZenohC.z_locality_default()

Base.:(==)(a::Locality, b::Locality) = a.v == b.v
Base.hash(l::Locality, h::UInt) = hash(l.v, hash(:ZenohLocality, h))
function Base.show(io::IO, l::Locality)
    name = l.v == LibZenohC.Z_LOCALITY_ANY           ? :any           :
           l.v == LibZenohC.Z_LOCALITY_SESSION_LOCAL ? :session_local :
           l.v == LibZenohC.Z_LOCALITY_REMOTE        ? :remote        :
           Symbol(l.v)
    print(io, "Locality(:", name, ")")
end

module Localities
    import ..Locality
    import ..LibZenohC
    const ANY           = Locality(LibZenohC.Z_LOCALITY_ANY)
    const SESSION_LOCAL = Locality(LibZenohC.Z_LOCALITY_SESSION_LOCAL)
    const REMOTE        = Locality(LibZenohC.Z_LOCALITY_REMOTE)
end
