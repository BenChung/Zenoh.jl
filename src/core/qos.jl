# QoS (and Locality) wrappers — strongly typed singleton sum types.
#
# Each bounded libzenoh enum (z_priority_t, z_congestion_control_t,
# z_locality_t, z_reply_keyexpr_t) is mapped to:
#
#   - an abstract supertype (e.g. `Priority`), re-exported at the top
#     level so method signatures can dispatch on it,
#   - a submodule (e.g. `Priorities`) that owns the concrete singleton
#     types and the user-facing instance constants.
#
# Conversion to the underlying `z_*_t` happens through a single
# unexported `_raw(::T)` overload per concrete type. Reverse conversion
# (used by Sample accessors) goes through `_<area>_from_raw(v)`.
#
# Why singletons instead of a wrapped enum?
#   - method signatures (`priority::Union{Nothing, Priority}`) reject
#     bogus values at parse/dispatch time;
#   - identity comparison (`priority(smp) === Priorities.REAL_TIME`)
#     is free — no field unpack;
#   - downstream code can dispatch on each level if desired
#     (`handle(::Priorities.RealTime, msg) = …`).

# ── Locality ────────────────────────────────────────────────────────────

module Localities
    import ..LibZenohC

    abstract type Locality end

    struct Any          <: Locality end
    struct SessionLocal <: Locality end
    struct Remote       <: Locality end

    const ANY           = Any()
    const SESSION_LOCAL = SessionLocal()
    const REMOTE        = Remote()
    # libzenoh: Z_LOCALITY_DEFAULT == Z_LOCALITY_ANY (both 0).
    const DEFAULT       = ANY
end

const Locality = Localities.Locality

_raw(::Localities.Any)          = LibZenohC.Z_LOCALITY_ANY
_raw(::Localities.SessionLocal) = LibZenohC.Z_LOCALITY_SESSION_LOCAL
_raw(::Localities.Remote)       = LibZenohC.Z_LOCALITY_REMOTE

function _locality_from_raw(v::LibZenohC.z_locality_t)
    v == LibZenohC.Z_LOCALITY_ANY           && return Localities.ANY
    v == LibZenohC.Z_LOCALITY_SESSION_LOCAL && return Localities.SESSION_LOCAL
    v == LibZenohC.Z_LOCALITY_REMOTE        && return Localities.REMOTE
    throw(ArgumentError("unknown z_locality_t value: $v"))
end

Base.show(io::IO, ::Localities.Any)          = print(io, "Localities.ANY")
Base.show(io::IO, ::Localities.SessionLocal) = print(io, "Localities.SESSION_LOCAL")
Base.show(io::IO, ::Localities.Remote)       = print(io, "Localities.REMOTE")

# ── Priority ────────────────────────────────────────────────────────────

module Priorities
    import ..LibZenohC

    abstract type Priority end

    struct RealTime        <: Priority end
    struct InteractiveHigh <: Priority end
    struct InteractiveLow  <: Priority end
    struct DataHigh        <: Priority end
    struct Data            <: Priority end
    struct DataLow         <: Priority end
    struct Background      <: Priority end

    const REAL_TIME        = RealTime()
    const INTERACTIVE_HIGH = InteractiveHigh()
    const INTERACTIVE_LOW  = InteractiveLow()
    const DATA_HIGH        = DataHigh()
    const DATA             = Data()
    const DATA_LOW         = DataLow()
    const BACKGROUND       = Background()
    # libzenoh: Z_PRIORITY_DEFAULT == Z_PRIORITY_DATA (both 5).
    const DEFAULT          = DATA
end

const Priority = Priorities.Priority

_raw(::Priorities.RealTime)        = LibZenohC.Z_PRIORITY_REAL_TIME
_raw(::Priorities.InteractiveHigh) = LibZenohC.Z_PRIORITY_INTERACTIVE_HIGH
_raw(::Priorities.InteractiveLow)  = LibZenohC.Z_PRIORITY_INTERACTIVE_LOW
_raw(::Priorities.DataHigh)        = LibZenohC.Z_PRIORITY_DATA_HIGH
_raw(::Priorities.Data)            = LibZenohC.Z_PRIORITY_DATA
_raw(::Priorities.DataLow)         = LibZenohC.Z_PRIORITY_DATA_LOW
_raw(::Priorities.Background)      = LibZenohC.Z_PRIORITY_BACKGROUND

function _priority_from_raw(v::LibZenohC.z_priority_t)
    v == LibZenohC.Z_PRIORITY_REAL_TIME        && return Priorities.REAL_TIME
    v == LibZenohC.Z_PRIORITY_INTERACTIVE_HIGH && return Priorities.INTERACTIVE_HIGH
    v == LibZenohC.Z_PRIORITY_INTERACTIVE_LOW  && return Priorities.INTERACTIVE_LOW
    v == LibZenohC.Z_PRIORITY_DATA_HIGH        && return Priorities.DATA_HIGH
    v == LibZenohC.Z_PRIORITY_DATA             && return Priorities.DATA
    v == LibZenohC.Z_PRIORITY_DATA_LOW         && return Priorities.DATA_LOW
    v == LibZenohC.Z_PRIORITY_BACKGROUND       && return Priorities.BACKGROUND
    throw(ArgumentError("unknown z_priority_t value: $v"))
end

Base.show(io::IO, ::Priorities.RealTime)        = print(io, "Priorities.REAL_TIME")
Base.show(io::IO, ::Priorities.InteractiveHigh) = print(io, "Priorities.INTERACTIVE_HIGH")
Base.show(io::IO, ::Priorities.InteractiveLow)  = print(io, "Priorities.INTERACTIVE_LOW")
Base.show(io::IO, ::Priorities.DataHigh)        = print(io, "Priorities.DATA_HIGH")
Base.show(io::IO, ::Priorities.Data)            = print(io, "Priorities.DATA")
Base.show(io::IO, ::Priorities.DataLow)         = print(io, "Priorities.DATA_LOW")
Base.show(io::IO, ::Priorities.Background)      = print(io, "Priorities.BACKGROUND")

# ── CongestionControl ───────────────────────────────────────────────────

module CongestionControls
    import ..LibZenohC

    abstract type CongestionControl end

    struct Block <: CongestionControl end
    struct Drop  <: CongestionControl end

    const BLOCK = Block()
    const DROP  = Drop()
    # libzenoh: Z_CONGESTION_CONTROL_DEFAULT == Z_CONGESTION_CONTROL_DROP.
    const DEFAULT = DROP
end

const CongestionControl = CongestionControls.CongestionControl

_raw(::CongestionControls.Block) = LibZenohC.Z_CONGESTION_CONTROL_BLOCK
_raw(::CongestionControls.Drop)  = LibZenohC.Z_CONGESTION_CONTROL_DROP

function _congestion_control_from_raw(v::LibZenohC.z_congestion_control_t)
    v == LibZenohC.Z_CONGESTION_CONTROL_BLOCK && return CongestionControls.BLOCK
    v == LibZenohC.Z_CONGESTION_CONTROL_DROP  && return CongestionControls.DROP
    throw(ArgumentError("unknown z_congestion_control_t value: $v"))
end

Base.show(io::IO, ::CongestionControls.Block) = print(io, "CongestionControls.BLOCK")
Base.show(io::IO, ::CongestionControls.Drop)  = print(io, "CongestionControls.DROP")

# ── ReplyKeyexpr ────────────────────────────────────────────────────────

module ReplyKeyexprs
    import ..LibZenohC

    abstract type ReplyKeyexpr end

    struct Any           <: ReplyKeyexpr end
    struct MatchingQuery <: ReplyKeyexpr end

    const ANY            = Any()
    const MATCHING_QUERY = MatchingQuery()
    # libzenoh: Z_REPLY_KEYEXPR_DEFAULT == Z_REPLY_KEYEXPR_MATCHING_QUERY.
    const DEFAULT        = MATCHING_QUERY
end

const ReplyKeyexpr = ReplyKeyexprs.ReplyKeyexpr

_raw(::ReplyKeyexprs.Any)           = LibZenohC.Z_REPLY_KEYEXPR_ANY
_raw(::ReplyKeyexprs.MatchingQuery) = LibZenohC.Z_REPLY_KEYEXPR_MATCHING_QUERY

function _reply_keyexpr_from_raw(v::LibZenohC.z_reply_keyexpr_t)
    v == LibZenohC.Z_REPLY_KEYEXPR_ANY            && return ReplyKeyexprs.ANY
    v == LibZenohC.Z_REPLY_KEYEXPR_MATCHING_QUERY && return ReplyKeyexprs.MATCHING_QUERY
    throw(ArgumentError("unknown z_reply_keyexpr_t value: $v"))
end

Base.show(io::IO, ::ReplyKeyexprs.Any)           = print(io, "ReplyKeyexprs.ANY")
Base.show(io::IO, ::ReplyKeyexprs.MatchingQuery) = print(io, "ReplyKeyexprs.MATCHING_QUERY")
