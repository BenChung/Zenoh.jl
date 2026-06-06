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

"""
    Localities

Singleton sum type for message locality, scoping which nodes a publication reaches
or a query accepts: `Localities.ANY` (both session-local and remote),
`Localities.SESSION_LOCAL` (the same session only), or
`Localities.REMOTE` (remote peers only).

Each level is a distinct zero-field type under the abstract supertype
[`Locality`](@ref Zenoh.Locality). Pass the instance constants `Localities.ANY`,
`Localities.SESSION_LOCAL`, or `Localities.REMOTE` as the `allowed_destination=`
keyword on a publisher declaration, session `put`, or `get`. `Localities.DEFAULT`
is `ANY`, mirroring libzenoh's `Z_LOCALITY_DEFAULT == Z_LOCALITY_ANY`.

See also [`Locality`](@ref Zenoh.Locality).
"""
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

"""
    Locality

Abstract supertype for the [`Localities`](@ref) singletons. Method signatures
take `Union{Nothing, Locality}` to dispatch on locality and reject any other
value at parse time. The concrete instances are `Localities.ANY`,
`Localities.SESSION_LOCAL`, and `Localities.REMOTE`.

See also [`Localities`](@ref).
"""
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

"""
    Priorities

Singleton sum type for the seven transmission-queue priority levels, from highest
to lowest: `Priorities.REAL_TIME`,
`Priorities.INTERACTIVE_HIGH`,
`Priorities.INTERACTIVE_LOW`,
`Priorities.DATA_HIGH`, `Priorities.DATA`,
`Priorities.DATA_LOW`, and
`Priorities.BACKGROUND`.

When QoS is enabled in the transport config, zenoh keeps one transmission queue per
priority and services them highest-first. Each level is a distinct zero-field type
under the abstract supertype [`Priority`](@ref Zenoh.Priority); pass an instance constant as the
`priority=` keyword on a publisher declaration or session `put`, and read it back
off an inbound sample with [`priority`](@ref Zenoh.priority). `Priorities.DEFAULT` is `DATA`,
mirroring libzenoh's `Z_PRIORITY_DEFAULT`.

See also [`Priority`](@ref Zenoh.Priority).
"""
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

"""
    Priority

Abstract supertype for the [`Priorities`](@ref) singletons. Method signatures take
`Union{Nothing, Priority}` to dispatch on priority and reject any other value at
parse time. The seven concrete instances run `Priorities.REAL_TIME` (highest)
through `Priorities.BACKGROUND` (lowest).

See also [`Priorities`](@ref), [`priority`](@ref).
"""
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

"""
    CongestionControls

Singleton sum type for the strategy applied when a message hits a full transmission
queue: `CongestionControls.BLOCK` waits for the queue to drain, while
`CongestionControls.DROP` discards the message.

Each level is a distinct zero-field type under the abstract supertype
[`CongestionControl`](@ref Zenoh.CongestionControl). Pass an instance constant as the `congestion_control=`
keyword on a publisher declaration or session `put`, and read it back off an inbound
sample with [`congestion_control`](@ref Zenoh.congestion_control). `CongestionControls.DEFAULT` is `DROP`,
mirroring libzenoh's `Z_CONGESTION_CONTROL_DEFAULT`.

See also [`CongestionControl`](@ref Zenoh.CongestionControl).
"""
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

"""
    CongestionControl

Abstract supertype for the [`CongestionControls`](@ref) singletons. Method
signatures take `Union{Nothing, CongestionControl}` to dispatch on the strategy and
reject any other value at parse time. The concrete instances are
`CongestionControls.BLOCK` and `CongestionControls.DROP`.

See also [`CongestionControls`](@ref), [`congestion_control`](@ref).
"""
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

# ── Reliability ─────────────────────────────────────────────────────────
#
# Writer-side QoS: whether the network layer retransmits lost messages.
# Fixed on the sender — set at `Publisher` declare time or per session
# `put`, and reported back on each inbound `Sample` via `reliability(::Sample)`.
# (A publisher's reliability can't be overridden per-`put`: zenoh's
# `z_publisher_put_options_t` carries no reliability field.)

"""
    Reliabilities

Singleton sum type for writer-side delivery reliability:
`Reliabilities.RELIABLE` has the network layer retransmit lost
messages, while `Reliabilities.BEST_EFFORT` tolerates loss.

Each level is a distinct zero-field type under the abstract supertype
[`Reliability`](@ref Zenoh.Reliability). Set it as the `reliability=` keyword at publisher declare time
or per session `put`; it is fixed on the sender, so a `Publisher` has no per-`put`
override. The chosen value is reported back on each inbound sample via
[`reliability`](@ref Zenoh.reliability). The same singletons also drop into static
`PublicationRule`/`QosOverwriteValues` config sections, emitting the zenoh config
tokens `"reliable"` / `"best_effort"`. `Reliabilities.DEFAULT` is `RELIABLE`,
mirroring libzenoh's `Z_RELIABILITY_DEFAULT`.

See also [`Reliability`](@ref Zenoh.Reliability).
"""
module Reliabilities
    import ..LibZenohC

    abstract type Reliability end

    struct BestEffort <: Reliability end
    struct Reliable   <: Reliability end

    const BEST_EFFORT = BestEffort()
    const RELIABLE    = Reliable()
    # libzenoh: Z_RELIABILITY_DEFAULT == Z_RELIABILITY_RELIABLE.
    const DEFAULT     = RELIABLE
end

"""
    Reliability

Abstract supertype for the [`Reliabilities`](@ref) singletons. Method signatures
take `Union{Nothing, Reliability}` to dispatch on reliability and reject any other
value at parse time. The concrete instances are `Reliabilities.RELIABLE` and
`Reliabilities.BEST_EFFORT`.

See also [`Reliabilities`](@ref), [`reliability`](@ref).
"""
const Reliability = Reliabilities.Reliability

_raw(::Reliabilities.BestEffort) = LibZenohC.Z_RELIABILITY_BEST_EFFORT
_raw(::Reliabilities.Reliable)   = LibZenohC.Z_RELIABILITY_RELIABLE

function _reliability_from_raw(v::LibZenohC.z_reliability_t)
    v == LibZenohC.Z_RELIABILITY_BEST_EFFORT && return Reliabilities.BEST_EFFORT
    v == LibZenohC.Z_RELIABILITY_RELIABLE    && return Reliabilities.RELIABLE
    throw(ArgumentError("unknown z_reliability_t value: $v"))
end

Base.show(io::IO, ::Reliabilities.BestEffort) = print(io, "Reliabilities.BEST_EFFORT")
Base.show(io::IO, ::Reliabilities.Reliable)   = print(io, "Reliabilities.RELIABLE")

# Config-builder bridge: let the same singletons drop into a typed
# `ConfigSection` field (`PublicationRule`/`QosOverwriteValues`), emitting
# the zenoh config token rather than requiring a raw `:reliable` symbol.
_to_json5(::Reliabilities.Reliable)   = _to_json5("reliable")
_to_json5(::Reliabilities.BestEffort) = _to_json5("best_effort")

# ── ReplyKeyexpr ────────────────────────────────────────────────────────

"""
    ReplyKeyexprs

Singleton sum type controlling which key expressions a query accepts on its replies:
`ReplyKeyexprs.MATCHING_QUERY` requires each reply to match
the query key expression, while `ReplyKeyexprs.ANY` admits replies under
any key.

Each level is a distinct zero-field type under the abstract supertype
[`ReplyKeyexpr`](@ref Zenoh.ReplyKeyexpr). Pass an instance constant as the `accept_replies=` keyword on
a `get`. `ReplyKeyexprs.DEFAULT` is `MATCHING_QUERY`, mirroring libzenoh's
`Z_REPLY_KEYEXPR_DEFAULT`.

See also [`ReplyKeyexpr`](@ref Zenoh.ReplyKeyexpr).
"""
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

"""
    ReplyKeyexpr

Abstract supertype for the [`ReplyKeyexprs`](@ref) singletons. Method signatures
take `Union{Nothing, ReplyKeyexpr}` to dispatch on the policy and reject any other
value at parse time. The concrete instances are `ReplyKeyexprs.ANY` and
`ReplyKeyexprs.MATCHING_QUERY`.

See also [`ReplyKeyexprs`](@ref).
"""
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

# ── QueryTarget ─────────────────────────────────────────────────────────
#
# Which matching queryables a `get` / `Querier` reaches. Same singleton
# pattern as the QoS enums above so `target=` takes the same kind of
# value everywhere (`QueryTargets.ALL`); a `Symbol` shorthand (`:all`)
# is also accepted at the call sites via `_as_query_target`.

"""
    QueryTargets

Singleton sum type selecting which matching queryables a `get` or `Querier` reaches:
`QueryTargets.BEST_MATCHING` follows the routing strategy,
`QueryTargets.ALL` reaches every matching queryable, and
`QueryTargets.ALL_COMPLETE` reaches every queryable declared
complete.

Each level is a distinct zero-field type under the abstract supertype
[`QueryTarget`](@ref Zenoh.QueryTarget). Pass an instance constant as the `target=` keyword on a `get`
or `Querier`; the matching `Symbol` shorthand (`:best_matching`, `:all`,
`:all_complete`) is accepted there too. `QueryTargets.DEFAULT` is `BEST_MATCHING`,
mirroring libzenoh's `Z_QUERY_TARGET_DEFAULT`.

See also [`QueryTarget`](@ref Zenoh.QueryTarget).
"""
module QueryTargets
    import ..LibZenohC

    abstract type QueryTarget end

    struct BestMatching <: QueryTarget end
    struct All          <: QueryTarget end
    struct AllComplete  <: QueryTarget end

    const BEST_MATCHING = BestMatching()
    const ALL           = All()
    const ALL_COMPLETE  = AllComplete()
    # libzenoh: Z_QUERY_TARGET_DEFAULT == Z_QUERY_TARGET_BEST_MATCHING.
    const DEFAULT       = BEST_MATCHING
end

"""
    QueryTarget

Abstract supertype for the [`QueryTargets`](@ref) singletons. Method signatures take
`Union{Nothing, QueryTarget}` to dispatch on the target and reject any other value at
parse time. The concrete instances are `QueryTargets.BEST_MATCHING`,
`QueryTargets.ALL`, and `QueryTargets.ALL_COMPLETE`.

See also [`QueryTargets`](@ref).
"""
const QueryTarget = QueryTargets.QueryTarget

_raw(::QueryTargets.BestMatching) = LibZenohC.Z_QUERY_TARGET_BEST_MATCHING
_raw(::QueryTargets.All)          = LibZenohC.Z_QUERY_TARGET_ALL
_raw(::QueryTargets.AllComplete)  = LibZenohC.Z_QUERY_TARGET_ALL_COMPLETE

Base.show(io::IO, ::QueryTargets.BestMatching) = print(io, "QueryTargets.BEST_MATCHING")
Base.show(io::IO, ::QueryTargets.All)          = print(io, "QueryTargets.ALL")
Base.show(io::IO, ::QueryTargets.AllComplete)  = print(io, "QueryTargets.ALL_COMPLETE")

# ── QueryConsolidation ──────────────────────────────────────────────────
#
# Reply de-duplication strategy. `_raw` yields the libzenoh
# `z_query_consolidation_t` value (a struct built by the C helpers), so
# these singletons drop straight into the options builders. As with
# QueryTarget, a `Symbol` shorthand (`:none`, …) is accepted too.

"""
    QueryConsolidations

Singleton sum type for the reply de-duplication strategy applied to a `get` or
`Querier`: `QueryConsolidations.AUTO` defers to the queryable's
preferences, `QueryConsolidations.NONE` forwards every sample,
`QueryConsolidations.MONOTONIC` forwards immediately unless a
same-or-newer timestamp was already sent for the key, and
`QueryConsolidations.LATEST` holds back samples to send only the
highest-timestamp set per key.

Each level is a distinct zero-field type under the abstract supertype
[`QueryConsolidation`](@ref Zenoh.QueryConsolidation); `_raw` builds the libzenoh `z_query_consolidation_t`
struct directly via the matching constructor function. Pass an instance constant as
the `consolidation=` keyword on a `get` or `Querier`; the matching `Symbol` shorthand
(`:auto`, `:none`, `:monotonic`, `:latest`) is accepted there too.
`QueryConsolidations.DEFAULT` is `AUTO`.

See also [`QueryConsolidation`](@ref Zenoh.QueryConsolidation).
"""
module QueryConsolidations
    import ..LibZenohC

    abstract type QueryConsolidation end

    struct Auto      <: QueryConsolidation end
    struct None      <: QueryConsolidation end
    struct Monotonic <: QueryConsolidation end
    struct Latest    <: QueryConsolidation end

    const AUTO      = Auto()
    const NONE      = None()
    const MONOTONIC = Monotonic()
    const LATEST    = Latest()
    const DEFAULT   = AUTO
end

"""
    QueryConsolidation

Abstract supertype for the [`QueryConsolidations`](@ref) singletons. Method
signatures take `Union{Nothing, QueryConsolidation}` to dispatch on the strategy and
reject any other value at parse time. The concrete instances are
`QueryConsolidations.AUTO`, `QueryConsolidations.NONE`,
`QueryConsolidations.MONOTONIC`, and `QueryConsolidations.LATEST`.

See also [`QueryConsolidations`](@ref).
"""
const QueryConsolidation = QueryConsolidations.QueryConsolidation

_raw(::QueryConsolidations.Auto)      = LibZenohC.z_query_consolidation_auto()
_raw(::QueryConsolidations.None)      = LibZenohC.z_query_consolidation_none()
_raw(::QueryConsolidations.Monotonic) = LibZenohC.z_query_consolidation_monotonic()
_raw(::QueryConsolidations.Latest)    = LibZenohC.z_query_consolidation_latest()

Base.show(io::IO, ::QueryConsolidations.Auto)      = print(io, "QueryConsolidations.AUTO")
Base.show(io::IO, ::QueryConsolidations.None)      = print(io, "QueryConsolidations.NONE")
Base.show(io::IO, ::QueryConsolidations.Monotonic) = print(io, "QueryConsolidations.MONOTONIC")
Base.show(io::IO, ::QueryConsolidations.Latest)    = print(io, "QueryConsolidations.LATEST")

# ── SampleKind ──────────────────────────────────────────────────────────
#
# Whether a Sample carries a value (PUT) or signals a key deletion
# (DELETE). Read off an inbound Sample via `kind(::Sample)`.

"""
    SampleKinds

Singleton sum type recording how a sample was produced:
`SampleKinds.PUT` carries a value, while
`SampleKinds.DELETE` signals a key deletion.

Each level is a distinct zero-field type under the abstract supertype
[`SampleKind`](@ref Zenoh.SampleKind). Read it off an inbound sample with [`kind`](@ref Zenoh.kind).
`SampleKinds.DEFAULT` is `PUT`, mirroring libzenoh's `Z_SAMPLE_KIND_DEFAULT`.

See also [`SampleKind`](@ref Zenoh.SampleKind).
"""
module SampleKinds
    import ..LibZenohC

    abstract type SampleKind end

    struct Put    <: SampleKind end
    struct Delete <: SampleKind end

    const PUT     = Put()
    const DELETE  = Delete()
    # libzenoh: Z_SAMPLE_KIND_DEFAULT == Z_SAMPLE_KIND_PUT.
    const DEFAULT = PUT
end

"""
    SampleKind

Abstract supertype for the [`SampleKinds`](@ref) singletons. The concrete instances
are `SampleKinds.PUT` and `SampleKinds.DELETE`, recovered from an inbound sample by
[`kind`](@ref).

See also [`SampleKinds`](@ref).
"""
const SampleKind = SampleKinds.SampleKind

_raw(::SampleKinds.Put)    = LibZenohC.Z_SAMPLE_KIND_PUT
_raw(::SampleKinds.Delete) = LibZenohC.Z_SAMPLE_KIND_DELETE

function _sample_kind_from_raw(v::LibZenohC.z_sample_kind_t)
    v == LibZenohC.Z_SAMPLE_KIND_PUT    && return SampleKinds.PUT
    v == LibZenohC.Z_SAMPLE_KIND_DELETE && return SampleKinds.DELETE
    throw(ArgumentError("unknown z_sample_kind_t value: $v"))
end

Base.show(io::IO, ::SampleKinds.Put)    = print(io, "SampleKinds.PUT")
Base.show(io::IO, ::SampleKinds.Delete) = print(io, "SampleKinds.DELETE")

# ── WhatAmI ─────────────────────────────────────────────────────────────
#
# The role a discovered node announces in a scouting `Hello`.

"""
    WhatAmIs

Singleton sum type for the role a node announces during discovery:
`WhatAmIs.ROUTER`, `WhatAmIs.PEER`, or
`WhatAmIs.CLIENT`.

Each role is a distinct zero-field type under the abstract supertype
[`WhatAmI`](@ref Zenoh.WhatAmI). It surfaces on the [`Hello`](@ref Zenoh.Hello) messages delivered by
[`scout`](@ref Zenoh.scout). Discovery roles carry no settable default, so this submodule
defines no `DEFAULT` constant.

See also [`WhatAmI`](@ref Zenoh.WhatAmI).
"""
module WhatAmIs
    import ..LibZenohC

    abstract type WhatAmI end

    struct Router <: WhatAmI end
    struct Peer   <: WhatAmI end
    struct Client <: WhatAmI end

    const ROUTER = Router()
    const PEER   = Peer()
    const CLIENT = Client()
end

"""
    WhatAmI

Abstract supertype for the [`WhatAmIs`](@ref) singletons. The concrete instances are
`WhatAmIs.ROUTER`, `WhatAmIs.PEER`, and `WhatAmIs.CLIENT`, read off the
[`Hello`](@ref) messages produced by [`scout`](@ref).

See also [`WhatAmIs`](@ref).
"""
const WhatAmI = WhatAmIs.WhatAmI

_raw(::WhatAmIs.Router) = LibZenohC.Z_WHATAMI_ROUTER
_raw(::WhatAmIs.Peer)   = LibZenohC.Z_WHATAMI_PEER
_raw(::WhatAmIs.Client) = LibZenohC.Z_WHATAMI_CLIENT

function _whatami_from_raw(v::LibZenohC.z_whatami_t)
    v == LibZenohC.Z_WHATAMI_ROUTER && return WhatAmIs.ROUTER
    v == LibZenohC.Z_WHATAMI_PEER   && return WhatAmIs.PEER
    v == LibZenohC.Z_WHATAMI_CLIENT && return WhatAmIs.CLIENT
    throw(ArgumentError("unknown z_whatami_t value: $v"))
end

Base.show(io::IO, ::WhatAmIs.Router) = print(io, "WhatAmIs.ROUTER")
Base.show(io::IO, ::WhatAmIs.Peer)   = print(io, "WhatAmIs.PEER")
Base.show(io::IO, ::WhatAmIs.Client) = print(io, "WhatAmIs.CLIENT")

export Locality, Localities, Priority, Priorities,
    CongestionControl, CongestionControls, Reliability, Reliabilities,
    ReplyKeyexpr, ReplyKeyexprs,
    QueryTarget, QueryTargets, QueryConsolidation, QueryConsolidations,
    SampleKind, SampleKinds, WhatAmI, WhatAmIs
