# Idiomatic, typed construction of a Zenoh `Config`.
#
# The Zenoh config is a deep nested structure (see
# https://github.com/eclipse-zenoh/zenoh/blob/main/commons/zenoh-config/src/lib.rs).
# Rather than mirror all of it, we model the commonly-used sections as typed
# `@kwdef` structs whose field names match the serde key names. A `ZenohConfig`
# is applied onto a base `Config` by flattening the struct tree into dotted key
# paths and inserting each set field via `setindex!` (→ `zc_config_insert_json5`).
# Zenoh itself parses/validates/canonicalizes every inserted value, so we never
# hold a parsed config in Julia and need no JSON dependency.
#
# Every field defaults to `nothing`, meaning "leave Zenoh's default untouched".
# Anything not modeled here is reachable through the `overrides` escape hatch.

"""
    ConfigSection

Internal marker supertype for every typed config section. The apply machinery
dispatches on it: a bare `ConfigSection` is *recursed into* (flattened to dotted
leaf paths), while a `Vector{<:ConfigSection}` is a leaf inserted whole as a
JSON array-of-objects.
"""
abstract type ConfigSection end

# A typed section appearing as a *value* (e.g. inside a rule list) serializes to
# a JSON object of its non-`nothing` fields, keyed by field name.
function _to_json5(x::ConfigSection)
    parts = String[]
    for f in fieldnames(typeof(x))
        v = getfield(x, f)
        v === nothing && continue
        push!(parts, _to_json5(string(f)) * ":" * _to_json5(v))
    end
    return "{" * join(parts, ",") * "}"
end

# ── connect / listen ─────────────────────────────────────────────────

"""
    Connect(; endpoints, timeout_ms, exit_on_failure, retry)

Endpoints to actively connect to (`connect/…`). `endpoints` is a vector of
locator strings, e.g. `["tcp/localhost:7447"]`.
"""
Base.@kwdef struct Connect <: ConfigSection
    endpoints::Union{Nothing,Vector{String}} = nothing
    timeout_ms = nothing
    exit_on_failure = nothing
    retry = nothing
end

"""
    Listen(; endpoints, timeout_ms, exit_on_failure, retry)

Endpoints to listen on (`listen/…`). Same shape as [`Connect`](@ref).
"""
Base.@kwdef struct Listen <: ConfigSection
    endpoints::Union{Nothing,Vector{String}} = nothing
    timeout_ms = nothing
    exit_on_failure = nothing
    retry = nothing
end

# ── scouting ─────────────────────────────────────────────────────────

"""
    Multicast(; enabled, address, interface, ttl)

UDP multicast discovery settings (`scouting/multicast/…`).
"""
Base.@kwdef struct Multicast <: ConfigSection
    enabled = nothing
    address = nothing
    interface = nothing
    ttl = nothing
end

"""
    Gossip(; enabled, multihop)

Gossip-based discovery settings (`scouting/gossip/…`).
"""
Base.@kwdef struct Gossip <: ConfigSection
    enabled = nothing
    multihop = nothing
end

"""
    Scouting(; timeout, delay, multicast, gossip)

Peer/router discovery (`scouting/…`).
"""
Base.@kwdef struct Scouting <: ConfigSection
    timeout = nothing
    delay = nothing
    multicast::Union{Nothing,Multicast} = nothing
    gossip::Union{Nothing,Gossip} = nothing
end

# ── open / timestamping ──────────────────────────────────────────────

"""
    Open(; connect_scouted, declares)

Conditions controlling when `open` returns (`open/return_conditions/…`):
`connect_scouted` waits for scouted peers, `declares` waits for initial
declarations.
"""
Base.@kwdef struct Open <: ConfigSection
    connect_scouted = nothing
    declares = nothing
end

"""
    Timestamping(; enabled, drop_future_timestamp)

Data message timestamp management (`timestamping/…`).
"""
Base.@kwdef struct Timestamping <: ConfigSection
    enabled = nothing
    drop_future_timestamp = nothing
end

# ── transport ────────────────────────────────────────────────────────

"""
    SharedMemory(; enabled)

Shared-memory transport optimization (`transport/shared_memory/…`).
"""
Base.@kwdef struct SharedMemory <: ConfigSection
    enabled = nothing
end

"""
    UsrPwd(; user, password, dictionary_file)

Username/password authentication (`transport/auth/usrpwd/…`).
"""
Base.@kwdef struct UsrPwd <: ConfigSection
    user = nothing
    password = nothing
    dictionary_file = nothing
end

"""
    Auth(; usrpwd)

Transport authentication (`transport/auth/…`).
"""
Base.@kwdef struct Auth <: ConfigSection
    usrpwd::Union{Nothing,UsrPwd} = nothing
end

"""
    Unicast(; open_timeout, accept_timeout, max_sessions, max_links, lowlatency)

Unicast transport settings (`transport/unicast/…`).
"""
Base.@kwdef struct Unicast <: ConfigSection
    open_timeout = nothing
    accept_timeout = nothing
    max_sessions = nothing
    max_links = nothing
    lowlatency = nothing
end

"""
    TransportMulticast(; join_interval, max_sessions)

Multicast transport settings (`transport/multicast/…`). Distinct from scouting's
[`Multicast`](@ref).
"""
Base.@kwdef struct TransportMulticast <: ConfigSection
    join_interval = nothing
    max_sessions = nothing
end

"""
    LinkTx(; threads, batch_size, lease, keep_alive, sequence_number_resolution)

Link transmission settings (`transport/link/tx/…`).
"""
Base.@kwdef struct LinkTx <: ConfigSection
    threads = nothing
    batch_size = nothing
    lease = nothing
    keep_alive = nothing
    sequence_number_resolution = nothing
end

"""
    LinkRx(; buffer_size, max_message_size)

Link reception settings (`transport/link/rx/…`).
"""
Base.@kwdef struct LinkRx <: ConfigSection
    buffer_size = nothing
    max_message_size = nothing
end

"""
    Link(; protocols, tx, rx)

Link-layer settings (`transport/link/…`).
"""
Base.@kwdef struct Link <: ConfigSection
    protocols::Union{Nothing,Vector{String}} = nothing
    tx::Union{Nothing,LinkTx} = nothing
    rx::Union{Nothing,LinkRx} = nothing
end

"""
    Transport(; unicast, multicast, link, shared_memory, auth)

Transport-layer configuration (`transport/…`).
"""
Base.@kwdef struct Transport <: ConfigSection
    unicast::Union{Nothing,Unicast} = nothing
    multicast::Union{Nothing,TransportMulticast} = nothing
    link::Union{Nothing,Link} = nothing
    shared_memory::Union{Nothing,SharedMemory} = nothing
    auth::Union{Nothing,Auth} = nothing
end

# ── qos (rule lists) ─────────────────────────────────────────────────

"""
    PublicationRule(; key_exprs, congestion_control, priority, express, reliability, allowed_origin)

A single per-keyexpr publication QoS rule (an entry in `qos/publication`).
"""
Base.@kwdef struct PublicationRule <: ConfigSection
    key_exprs::Union{Nothing,Vector{String}} = nothing
    congestion_control = nothing
    priority = nothing
    express = nothing
    reliability = nothing
    allowed_origin = nothing
end

"""
    QosOverwriteValues(; congestion_control, priority, express, reliability)

The QoS values applied by a [`QosOverwrite`](@ref) rule (its `overwrite` field).
"""
Base.@kwdef struct QosOverwriteValues <: ConfigSection
    congestion_control = nothing
    priority = nothing
    express = nothing
    reliability = nothing
end

"""
    QosOverwrite(; messages, key_exprs, flows, overwrite)

A single network QoS overwrite rule (an entry in `qos/network`).
"""
Base.@kwdef struct QosOverwrite <: ConfigSection
    messages::Union{Nothing,Vector{String}} = nothing
    key_exprs::Union{Nothing,Vector{String}} = nothing
    flows::Union{Nothing,Vector{String}} = nothing
    overwrite::Union{Nothing,QosOverwriteValues} = nothing
end

"""
    Qos(; publication, network)

QoS message overwrite rules (`qos/…`). Each field is a vector of rule structs.
"""
Base.@kwdef struct Qos <: ConfigSection
    publication::Union{Nothing,Vector{PublicationRule}} = nothing
    network::Union{Nothing,Vector{QosOverwrite}} = nothing
end

# ── aggregation / adminspace ─────────────────────────────────────────

"""
    Aggregation(; subscribers, publishers)

Declaration aggregation strategy (`aggregation/…`). Each field is a vector of
key expression strings.
"""
Base.@kwdef struct Aggregation <: ConfigSection
    subscribers::Union{Nothing,Vector{String}} = nothing
    publishers::Union{Nothing,Vector{String}} = nothing
end

"""
    Permissions(; read, write)

Admin space permissions (`adminspace/permissions/…`).
"""
Base.@kwdef struct Permissions <: ConfigSection
    read = nothing
    write = nothing
end

"""
    AdminSpace(; enabled, permissions)

Admin space configuration (`adminspace/…`).
"""
Base.@kwdef struct AdminSpace <: ConfigSection
    enabled = nothing
    permissions::Union{Nothing,Permissions} = nothing
end

# ── top-level builder ────────────────────────────────────────────────

"""
    ZenohConfig(; mode, connect, listen, scouting, transport, qos, …, overrides)

Idiomatic, typed description of a Zenoh configuration. Only the fields you set
are applied; everything else keeps Zenoh's defaults. Apply it by constructing a
[`Config`](@ref) from it:

```julia
c = Config(ZenohConfig(
    mode = :peer,
    connect = Connect(endpoints = ["tcp/localhost:7447"]),
    scouting = Scouting(multicast = Multicast(enabled = true)),
    overrides = Dict("transport/link/tx/threads" => 4),
))
```

`mode` accepts `:peer`, `:router`, `:client` (or the equivalent strings).
`overrides` is an escape hatch mapping raw dotted config keys to values, applied
last (so they win over the typed fields); it reaches anything not modeled as a
typed section.
"""
Base.@kwdef struct ZenohConfig
    mode = nothing
    id = nothing
    namespace = nothing
    metadata = nothing
    connect::Union{Nothing,Connect} = nothing
    listen::Union{Nothing,Listen} = nothing
    scouting::Union{Nothing,Scouting} = nothing
    open::Union{Nothing,Open} = nothing
    timestamping::Union{Nothing,Timestamping} = nothing
    queries_default_timeout = nothing
    transport::Union{Nothing,Transport} = nothing
    qos::Union{Nothing,Qos} = nothing
    aggregation::Union{Nothing,Aggregation} = nothing
    adminspace::Union{Nothing,AdminSpace} = nothing
    overrides::AbstractDict = Dict{String,Any}()
end

# ── apply machinery ──────────────────────────────────────────────────

const _VALID_MODES = (:peer, :router, :client)

# Validate a `mode` value, returning it unchanged (a Symbol or string) for the
# leaf machinery to quote. Symbols are checked against the known node roles.
_mode_value(m::AbstractString) = m
function _mode_value(m::Symbol)
    m in _VALID_MODES ||
        throw(ArgumentError("invalid mode $(repr(m)); expected one of $(_VALID_MODES)"))
    return m
end

# The dotted-path prefix a section contributes. Defaults to the accumulated
# prefix; sections whose real path is not just their field name override it.
_section_path(prefix, ::ConfigSection) = prefix
_section_path(::Any, ::Open) = "open/return_conditions"

_apply!(c::Config, prefix, ::Nothing) = nothing
function _apply!(c::Config, prefix, x::ConfigSection)
    base = _section_path(prefix, x)
    for f in fieldnames(typeof(x))
        v = getfield(x, f)
        v === nothing && continue
        _apply!(c, isempty(base) ? String(f) : "$base/$f", v)
    end
    return nothing
end
# Leaf: scalar, Vector, Dict, … → serialize then insert. We serialize explicitly
# (rather than letting `setindex!` dispatch) so that *string* leaves are quoted —
# unlike the public `setindex!(::AbstractString)`, which treats its value as
# pre-formatted raw JSON5. Typed-section fields are always plain Julia values.
_apply!(c::Config, key, v) = (c[String(key)] = _to_json5(v); nothing)

"""
    configure!(c::Config, zc::ZenohConfig) -> Config

Apply every set field of `zc` onto the existing config `c` (in place), then
apply `zc.overrides` last. Returns `c`.
"""
function configure!(c::Config, zc::ZenohConfig)
    for f in fieldnames(ZenohConfig)
        f === :overrides && continue
        v = getfield(zc, f)
        v === nothing && continue
        if f === :mode
            _apply!(c, "mode", _mode_value(v))   # validate, then serialize+insert
        else
            _apply!(c, String(f), v)
        end
    end
    for (k, v) in zc.overrides
        c[String(k)] = v
    end
    return c
end

"""
    Config(zc::ZenohConfig; from_env=false, file=nothing, str=nothing)

Build a `Config` from a typed [`ZenohConfig`](@ref). Starts from a base config
(default, or `from_env`/`file`/`str` as in the keyword constructor) and applies
the typed fields on top via [`configure!`](@ref).
"""
function Config(zc::ZenohConfig; from_env=false, file=nothing, str=nothing)
    c = Config(; from_env, file, str)
    configure!(c, zc)
    return c
end

export ZenohConfig, Connect, Listen, Scouting, Multicast, Gossip, Open,
    Timestamping, Transport, Unicast, TransportMulticast, Link, LinkTx, LinkRx,
    SharedMemory, Auth, UsrPwd, Qos, PublicationRule, QosOverwrite,
    QosOverwriteValues, Aggregation, AdminSpace, Permissions, configure!
