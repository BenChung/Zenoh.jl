```@meta
CurrentModule = Zenoh
```

# Sessions & Configuration

A [`Session`](@ref) is the main component of Zenoh: it holds the Zenoh runtime and maintains the node's connection state to the rest of the network ([Zenoh `Session` docs](https://docs.rs/zenoh/1.9.0/zenoh/session/index.html)). Every publisher, subscriber, querier, and queryable is declared on a session, and every [`put`](@ref), [`get`](@ref), and [`delete!`](@ref) routes through one. You obtain a session by calling `open` on a [`Config`](@ref).

A [`Config`](@ref) holds all the parameters that shape a session: the node's role, the endpoints it connects to and listens on, scouting and transport tuning, QoS rules, and more ([Zenoh `Config` docs](https://docs.rs/zenoh/1.9.0/zenoh/config/index.html)). Zenoh treats the config's fields as unstable, so you mutate and read it only through JSON5, addressing values by dotted key. Zenoh.jl exposes that raw surface directly through `Config` and layers a typed, idiomatic builder — [`ZenohConfig`](@ref) and the [`ConfigSection`](@ref) family — on top of it.

## Configuring a session

Configuration comes in two layers. The lower layer is [`Config`](@ref): a thin wrapper over Zenoh's own config object, where every value flows through Zenoh's JSON5 parser. The upper layer is [`ZenohConfig`](@ref): typed Julia structs whose field names mirror Zenoh's config keys, flattened to dotted key paths and applied on top of a base config. Reach for the typed layer for everything you commonly set, and drop to raw keys for anything it does not model.

### The typed builder

[`ZenohConfig`](@ref) describes a configuration with named, nested structs. Only the fields you set are applied; everything else keeps Zenoh's defaults. Build a [`Config`](@ref) from it by passing it to the `Config` constructor:

```julia
using Zenoh

cfg = Config(ZenohConfig(
    mode      = :peer,
    connect   = Connect(endpoints = ["tcp/localhost:7447"]),
    scouting  = Scouting(multicast = Multicast(enabled = true)),
    transport = Transport(shared_memory = SharedMemory(enabled = true)),
    overrides = Dict("transport/link/tx/threads" => 4),  # escape hatch for unmodeled keys
))
```

`mode` is the node's role in the network — `:peer`, `:router`, or `:client` ([Zenoh `WhatAmI`](https://docs.rs/zenoh/1.9.0/zenoh/config/enum.WhatAmI.html)). Symbols are validated against those three values; an unknown symbol throws immediately.

Each section maps to a Zenoh config block. [`Connect`](@ref) and [`Listen`](@ref) hold endpoint lists (`tcp/localhost:7447` and the like); [`Scouting`](@ref) nests [`Multicast`](@ref) and [`Gossip`](@ref) discovery; [`Transport`](@ref) nests [`Unicast`](@ref), [`TransportMulticast`](@ref), [`Link`](@ref), [`SharedMemory`](@ref), and [`Auth`](@ref); [`Qos`](@ref) carries rule lists. See [`ZenohConfig`](@ref) and the individual section docstrings for the full set.

The `overrides` field is the escape hatch: a dict mapping raw dotted keys to values, applied last so it wins over the typed fields. It reaches any key the typed sections do not model.

Apply more settings to a config you already built with [`configure!`](@ref):

```julia
cfg = Config()                                   # built-in defaults
configure!(cfg, ZenohConfig(mode = :client))     # mutate in place, returns cfg
```

!!! warning "The `open` section serializes to `open/return_conditions`"
    [`Open`](@ref) is the one section whose dotted path differs from its field name: `Open(connect_scouted = true)` writes to `open/return_conditions/connect_scouted`, matching Zenoh's config layout. Every other section's path is its field name.

### The raw config layer

[`Config`](@ref) constructs from one of four sources, selected by mutually exclusive keywords:

```julia
Config()                          # Zenoh's built-in defaults
Config(from_env = true)           # parse the file named by the ZENOH_CONFIG env var
Config(file = "zenoh.json5")      # load a JSON5 file
Config(str = "{ mode: 'peer' }")  # parse a JSON5 string
```

Read and write individual keys by dotted path. `getindex` returns the JSON-serialized value; `setindex!` inserts a value at a key:

```julia
cfg["mode"]                       # => "null" on a default config; "\"peer\"" once mode is set
cfg["connect/endpoints"] = ["tcp/localhost:7447"]   # serialized to JSON5, then inserted
```

!!! warning "`setindex!` inserts `String` values verbatim as JSON5"
    A `String` value is inserted **verbatim** as pre-formatted JSON5, so it must already be valid JSON5. Every other value type is serialized first. So `cfg["mode"] = "peer"` inserts the bareword `peer`, which Zenoh rejects. Write `cfg["mode"] = :peer` (a Symbol is serialized to the quoted string `"peer"`) or hand-quote it as `cfg["mode"] = "\"peer\""`. The typed builder serializes every value through `_to_json5`, so a symbol or string always reaches Zenoh correctly quoted.

Every value round-trips through Zenoh's own JSON5 parser on insert, which validates and canonicalizes it. So a `Config` holds no parsed state and needs no JSON dependency.

## Opening and closing a session

[`open`](@ref open(::Zenoh.Config)) takes a [`Config`](@ref) and returns a live [`Session`](@ref). It **copies the config** before opening, so the same `Config` stays valid and reusable across multiple `open` calls.

[`close`](@ref close(::Zenoh.Session)) gracefully shuts the session down and frees its handle, deterministically on the calling task. It is idempotent: a second `close` is a no-op. After `close` the session is unusable and any operation on it throws. Pair `open` with `close` in a `try`/`finally`:

```julia
s = open(cfg)                     # copies cfg; cfg stays reusable
try
    @assert isopen(s)
    # declare publishers/subscribers, put/get here
finally
    close(s)                      # graceful shutdown + free; idempotent
end
```

Call `close` explicitly: the graceful shutdown drains Zenoh's async runtime, work that should run on your task where ordering is predictable. A GC finalizer frees an unclosed session as a safety net, and skips a session you closed yourself.

## Session identity and connectivity

Every session has a globally unique 16-byte Zenoh ID. [`zid`](@ref) returns this session's ID. A valid session always yields a non-zero ID; an all-zero 16-byte array signals an invalid session. [`router_zids`](@ref) and [`peer_zids`](@ref) return the IDs of the routers and peers this session is currently connected to.

```julia
id = zid(s)                       # this session's Zenoh ID
to_le_bytes(id)                   # raw 16-byte little-endian tuple (NTuple{16,UInt8})
router_zids(s)                    # IDs of connected routers
peer_zids(s)                      # IDs of connected peers
```

!!! warning "`to_le_bytes` and the printed string have opposite byte order"
    [`to_le_bytes`](@ref) returns the ID's raw little-endian bytes — the form Zenoh hashes and serializes. The `show` representation renders those same bytes reversed (most-significant first) with leading zero bytes elided. Use `to_le_bytes` whenever you need the canonical byte order; use the string only for display.

## Shared memory

[`open`](@ref open(::Zenoh.Config)) accepts a `shm_clients` keyword (plus `on_shm_alloc_error`, `wait_for_shm`, and `shm_wait_timeout`) to open the session with shared-memory transport support. These are a Zenoh.jl-specific layer over Zenoh's SHM support; see [Shared Memory](@ref) for the full story, including `default_shm_clients`, [`shm_state`](@ref), and [`shm_ready`](@ref).

## The admin space

Setting the [`AdminSpace`](@ref) section enables Zenoh's admin space — the key space dedicated to administering a router and its plugins, accessible under `@/router/<router-id>` ([admin space docs](https://zenoh.io/docs/manual/abstractions/#admin-space)). Zenoh.jl exposes the config switch that turns it on; querying it afterward is ordinary [`get`](@ref) and [`put`](@ref) against those key expressions, not a dedicated API.

## Sessions API

```@docs
Session
open(::Zenoh.Config)
close(::Zenoh.Session)
isopen(::Zenoh.Session)
zid
router_zids
peer_zids
to_le_bytes
ZenohError
```

## Configuration API

```@docs
Config
configure!
ZenohConfig
ConfigSection
Connect
Listen
Scouting
Multicast
Gossip
Open
Timestamping
Transport
Unicast
TransportMulticast
Link
LinkTx
LinkRx
SharedMemory
Auth
UsrPwd
Qos
PublicationRule
QosOverwrite
QosOverwriteValues
Aggregation
AdminSpace
Permissions
```

## Mapping to Zenoh, Rust, and C

| Zenoh.jl | Zenoh abstraction | Rust | zenoh-c |
| --- | --- | --- | --- |
| [`Session`](@ref) | [Session](https://docs.rs/zenoh/1.9.0/zenoh/session/index.html) | [`zenoh::session::Session`](https://docs.rs/zenoh/1.9.0/zenoh/struct.Session.html) | `z_owned_session_t` |
| [`open(::Config)`](@ref open(::Zenoh.Config)) | open a session | [`zenoh::open`](https://docs.rs/zenoh/1.9.0/zenoh/fn.open.html) | `z_open` (`z_open_with_custom_shm_clients` with `shm_clients`) |
| [`close`](@ref close(::Zenoh.Session)) | close a session | `Session::close` | `z_close` + `z_session_drop` |
| [`isopen`](@ref isopen(::Zenoh.Session)) | session liveness | `!Session::is_closed` | `!z_session_is_closed` |
| [`zid`](@ref) | session Zenoh ID | `SessionInfo::zid` | `z_info_zid` |
| [`router_zids`](@ref) / [`peer_zids`](@ref) | connected routers/peers | `SessionInfo::routers_zid` / `peers_zid` | `z_info_routers_zid` / `z_info_peers_zid` |
| [`to_le_bytes`](@ref) | Zenoh ID bytes | [`ZenohId::to_le_bytes`](https://docs.rs/zenoh/1.9.0/zenoh/config/struct.ZenohId.html) | `z_id_t.data` |
| [`Config`](@ref) | [Config](https://docs.rs/zenoh/1.9.0/zenoh/config/index.html) | [`zenoh::config::Config`](https://docs.rs/zenoh/1.9.0/zenoh/struct.Config.html) | `z_owned_config_t` |
| `Config(; from_env, file, str)` | config sources | `Config::default` / `from_env` / `from_file` / `from_json5` | `z_config_default` / `zc_config_from_env` / `zc_config_from_file` / `zc_config_from_str` |
| `cfg[key]` | read a config value | `Config::get_json` | `zc_config_get_from_str` |
| `cfg[key] = value` | write a config value | `Config::insert_json5` | `zc_config_insert_json5` |
| `cfg.mode` / `ZenohConfig.mode` | node role | [`WhatAmI`](https://docs.rs/zenoh/1.9.0/zenoh/config/enum.WhatAmI.html) | `mode` JSON5 key |
| [`AdminSpace`](@ref) | [admin space](https://zenoh.io/docs/manual/abstractions/#admin-space) | `adminspace` config | `adminspace` JSON5 key |
| [`ZenohConfig`](@ref) / [`ConfigSection`](@ref) family | (none) | [zenoh-config serde structs](https://github.com/eclipse-zenoh/zenoh/blob/main/commons/zenoh-config/src/lib.rs) | (none) |

[`Session`](@ref) is a thin owner of zenoh-c's `z_owned_session_t`, equivalent to Rust's `zenoh::session::Session`, with extra cells tracking close-state and discovered SHM capability. [`open`](@ref open(::Zenoh.Config)) corresponds to `zenoh::open` / `z_open`. [`zid`](@ref), [`router_zids`](@ref), and [`peer_zids`](@ref) cover the same ground as Rust's `SessionInfo::zid`/`routers_zid`/`peers_zid` (`z_info_zid`/`z_info_routers_zid`/`z_info_peers_zid`). The raw [`Config`](@ref) mirrors Rust's `zenoh::config::Config` exactly: fields are unstable, so JSON5 round-tripping is the only surface on both sides.

Several divergences are worth naming precisely:

- **No `SessionInfo` type.** Rust groups `zid`/`routers_zid`/`peers_zid` under `Session::info() -> SessionInfo`. Zenoh.jl flattens them into three free functions on [`Session`](@ref); there is no `info()` and no `SessionInfo` struct.
- **`open` returns a live session directly.** Rust's `zenoh::open` returns an awaitable `OpenBuilder` that yields a `Session` once awaited. Zenoh.jl's [`open`](@ref open(::Zenoh.Config)) returns the live [`Session`](@ref) directly.
- **`close` is explicit and deterministic.** Rust auto-closes when the last `Session` clone drops. Zenoh.jl's [`close`](@ref close(::Zenoh.Session)) performs `z_close` then `z_session_drop` on the calling task; the GC finalizer is only a safety net that skips already-closed sessions.
- **`open` copies the config.** A raw `z_open` moves and consumes the config. Zenoh.jl's [`open`](@ref open(::Zenoh.Config)) clones it first (`z_config_clone`) and moves the copy, so the caller's [`Config`](@ref) stays usable across multiple `open` calls.
- **SHM `open` keywords are Zenoh.jl-only.** `on_shm_alloc_error`, `wait_for_shm`, and `shm_wait_timeout` have no zenoh-c counterpart; only `shm_clients` maps to a C function (`z_open_with_custom_shm_clients`). See [Shared Memory](@ref).

!!! note "Zenoh.jl extension: the typed config builder"
    [`ZenohConfig`](@ref) and the [`ConfigSection`](@ref) family are a pure Julia layer with no Zenoh equivalent. Zenoh exposes config only as JSON5; these typed `@kwdef` structs track the [zenoh-config serde key names](https://github.com/eclipse-zenoh/zenoh/blob/main/commons/zenoh-config/src/lib.rs) by hand and flatten to dotted keys on apply. Upstream renames to those keys would silently break the typed layer, so the `overrides` escape hatch always reaches the raw keys directly.
