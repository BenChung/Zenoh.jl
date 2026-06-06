```@meta
CurrentModule = Zenoh
```

# Zenoh.jl

[Zenoh](https://zenoh.io) is a pub/sub/query protocol that unifies data in motion, data at rest, and computation over one location-transparent key/value space. Applications talk to keys arranged in a `/`-separated hierarchy; the network routes a [`put`](@ref) toward every matching [Subscriber](https://zenoh.io/docs/manual/abstractions/#subscriber), serves a [`get`](@ref) from every matching [Queryable](https://zenoh.io/docs/manual/abstractions/#queryable) or storage, and discovers peers and routers automatically. See the [Zenoh abstractions manual](https://zenoh.io/docs/manual/abstractions/) for the full vocabulary — [keys](https://zenoh.io/docs/manual/abstractions/#key), [key expressions](https://zenoh.io/docs/manual/abstractions/#key-expression), [selectors](https://zenoh.io/docs/manual/abstractions/#selector), [values](https://zenoh.io/docs/manual/abstractions/#value), [publishers](https://zenoh.io/docs/manual/abstractions/#publisher), and the rest.

Zenoh.jl is a typed Julia wrapper over [zenoh-c](https://zenoh-c.readthedocs.io/en/1.9.0/), the official C binding for the [Rust Zenoh implementation](https://docs.rs/zenoh/1.9.0/zenoh/). Each Zenoh entity — a [`Session`](@ref), a [`Publisher`](@ref), a [`Keyexpr`](@ref), a [`Queryable`](@ref) — is a Julia struct with Julia-native ergonomics: GC-managed lifetimes, errors raised as exceptions, and eager operations that return a value or throw. The current surface spans publication and subscription, queries and queryables, liveliness, queriers, matching, [advanced pub/sub](manual/advanced-pubsub.md), shared memory, and scouting.

## Installation

Zenoh.jl is hosted on GitHub and bundles its native dependency through a JLL, so no separate Zenoh install is required:

```julia
using Pkg
Pkg.add(url = "https://github.com/BenChung/Zenoh.jl.git")
```

```julia
using Zenoh
```

The first run compiles the package and loads `libzenohc`. To talk to other Zenoh applications you need either peer connectivity or a running [`zenohd`](https://zenoh.io/docs/getting-started/installation/) router; the examples throughout this manual assume one is reachable.

## A first session

```julia
using Zenoh

# Build a config: defaults, or from a JSON5 string / file / the ZENOH_CONFIG env var.
cfg = Config(; str = """{mode: "peer"}""")
cfg["connect/endpoints"] = ["tcp/localhost:7447"]   # JSON5-serialized insert

s = open(cfg)                 # eager: returns a Session or throws ZenohError
try
    @show isopen(s)
    @show zid(s)              # this session's 16-byte Zenoh ID
    @show router_zids(s)      # IDs of connected routers

    k = kexpr"demo/example"   # a Keyexpr via the string macro
    put(s, k, "hello")        # eager publish; throws on failure
finally
    close(s)                  # deterministic teardown; idempotent
end
```

The [Getting Started](getting-started.md) page walks through this end to end; [Sessions & Configuration](manual/sessions-and-configuration.md) covers the full configuration surface.

## The wrapper model

Four conventions hold across every page of this manual, so each feature page can assume them.

### GC-managed lifetimes

Every Zenoh entity is garbage-collected. An unreferenced [`Session`](@ref), [`Publisher`](@ref), or [`Config`](@ref) frees its resources on its own, with no explicit teardown required.

### Deterministic close alongside GC

For resources whose teardown order matters, [`close`](@ref) (or `undeclare` for declared entities) tears the resource down immediately on the calling task. A [`Session`](@ref) shuts down gracefully and drains its background runtime on that task, where teardown order is predictable, rather than leaving it to the garbage collector. Closing the same entity again is a no-op, and GC remains a safety net for entities never closed explicitly.

!!! warning "A closed session throws on use"
    Any operation on a closed [`Session`](@ref) raises an `ArgumentError`. [`close`](@ref) is idempotent, but operations are not retryable after it.

### Errors as exceptions

Every operation either returns its result or throws a [`ZenohError`](@ref). A successful call returns the wrapped object or `nothing`; there is no status code to inspect.

### Eager operations, no builder layer

Every Zenoh.jl operation runs immediately. [`open`](@ref), [`put`](@ref), `Publisher(s, k)`, [`get`](@ref), and their siblings perform the operation on the spot and return the result or throw — there is no separate builder or resolve step.

Some features ([advanced pub/sub](manual/advanced-pubsub.md), the structured serializer) come from the zenoh-ext extension rather than the core protocol; each such page flags this where it applies.

## Manual map

Each page anchors a Zenoh domain and links its counterparts in the three official doc sets.

| Page | Zenoh domain | Rust (docs.rs) | zenoh-c |
| --- | --- | --- | --- |
| [Sessions & Configuration](manual/sessions-and-configuration.md) | the network entity and its [config](https://zenoh.io/docs/manual/configuration/) | [`session`](https://docs.rs/zenoh/1.9.0/zenoh/session/struct.Session.html), [`config`](https://docs.rs/zenoh/1.9.0/zenoh/config/index.html) | [`z_open`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [Key Expressions](manual/key-expressions.md) | [key expression](https://zenoh.io/docs/manual/abstractions/#key-expression) | [`key_expr`](https://docs.rs/zenoh/1.9.0/zenoh/key_expr/index.html) | [keyexpr](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [Publish & Subscribe](manual/publish-subscribe.md) | [publisher](https://zenoh.io/docs/manual/abstractions/#publisher), [subscriber](https://zenoh.io/docs/manual/abstractions/#subscriber) | [`pubsub`](https://docs.rs/zenoh/1.9.0/zenoh/pubsub/index.html) | [pub/sub](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [Samples](manual/samples.md) | [sample / value](https://zenoh.io/docs/manual/abstractions/#value) | [`sample`](https://docs.rs/zenoh/1.9.0/zenoh/sample/index.html) | [sample](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [Payloads & Serialization](manual/payloads-and-serialization.md) | [value](https://zenoh.io/docs/manual/abstractions/#value) | [`bytes`](https://docs.rs/zenoh/1.9.0/zenoh/bytes/index.html) | [bytes / serializer](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [Encoding](manual/encoding.md) | [encoding](https://zenoh.io/docs/manual/abstractions/#encoding) | [`bytes::Encoding`](https://docs.rs/zenoh/1.9.0/zenoh/bytes/struct.Encoding.html) | [encoding](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [Queries](manual/queries.md) | [queryable](https://zenoh.io/docs/manual/abstractions/#queryable), [selector](https://zenoh.io/docs/manual/abstractions/#selector) | [`query`](https://docs.rs/zenoh/1.9.0/zenoh/query/index.html) | [query](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [Quality of Service](manual/quality-of-service.md) | [QoS / priorities](https://zenoh.io/docs/manual/abstractions/) | [`qos`](https://docs.rs/zenoh/1.9.0/zenoh/qos/index.html) | [QoS](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [Liveliness](manual/liveliness.md) | liveliness tokens | [`liveliness`](https://docs.rs/zenoh/1.9.0/zenoh/liveliness/index.html) | [liveliness](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [Matching](manual/matching.md) | matching status | [`matching`](https://docs.rs/zenoh/1.9.0/zenoh/matching/index.html) | [matching](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [Scouting](manual/scouting.md) | scouting / discovery | [`scouting`](https://docs.rs/zenoh/1.9.0/zenoh/scouting/index.html) | [scout](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [Advanced Pub/Sub](manual/advanced-pubsub.md) | zenoh-ext advanced pub/sub | [zenoh-ext](https://docs.rs/zenoh-ext/1.9.0/zenoh_ext/) | [`ze_` advanced](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [Shared Memory](manual/shared-memory.md) | shared-memory transport | [`shm`](https://docs.rs/zenoh/1.9.0/zenoh/shm/index.html) | [SHM](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [Logging](manual/logging.md) | runtime logging | [`init_log_from_env_or`](https://docs.rs/zenoh/1.9.0/zenoh/fn.init_log_from_env_or.html) | [logging](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |

The [API Reference](reference.md) lists every exported symbol in one place.

## Implementation notes

The conventions above are the user-facing contract; this section records how the wrapper realizes them over zenoh-c, and where it diverges from the Rust API. Each manual page carries its own "Mapping to Zenoh, Rust, and C" section for its domain.

| Zenoh.jl | Rust | zenoh-c |
| --- | --- | --- |
| [`Session`](@ref) | [`zenoh::Session`](https://docs.rs/zenoh/1.9.0/zenoh/session/struct.Session.html) | `z_owned_session_t`, `z_open` |
| [`Config`](@ref) | [`zenoh::config`](https://docs.rs/zenoh/1.9.0/zenoh/config/index.html) | `z_owned_config_t`, `zc_config_from_*` |
| [`open`](@ref)`(::Config)` | [`Session::open`](https://docs.rs/zenoh/1.9.0/zenoh/session/struct.Session.html) (a `Resolvable`) | `z_open` |
| [`close`](@ref)`(::Session)` | `Session::close` (a builder) | `z_close` + `z_session_drop` |
| [`ZenohError`](@ref) | [`zenoh::Error` / `Result`](https://docs.rs/zenoh/1.9.0/zenoh/) | `z_result_t` + `Z_OK` |

### Ownership categories

zenoh-c splits its types into four [categories](https://zenoh-c.readthedocs.io/en/1.9.0/concepts.html): owned (`z_owned_*_t`, holding a resource that must be dropped), loaned (`z_loaned_*_t`, a borrow), moved (`z_moved_*_t`, consumed by the callee), and view (`z_view_*_t`, a pointer into external data). Every owned C handle is wrapped in a Julia struct holding a `Base.RefValue`, with a finalizer that drops it on garbage collection — RAII reaching Julia. `src/core/ownership.jl` generates the lifecycle verbs at module load: it scans `LibZenohC` for every `z_owned_*_t`, finds the matching moved and loaned types, and `dlsym`s the corresponding C functions to emit the applicable `_loan`/`_loan_mut`/`_move`/`_take`/`_drop` verbs — only those whose C symbols exist. View types own nothing, so they need no verbs and are never dropped.

### Close and error mechanics

A [`Session`](@ref) carries a `closed` flag and cached SHM state in mutable `Ref` cells beyond the bare `z_owned_session_t`, and every declare/put/get checks that flag before calling into C. [`close`](@ref) calls `z_close` then drops the handle (`z_session_drop`) — both on the caller's task, so Zenoh's runtime drains where ordering is predictable rather than on the finalizer thread. Fallible C calls return a `z_result_t` code; the wrapper throws [`ZenohError`](@ref) on any non-`Z_OK` result. The Rust API defers operations through a [`Resolvable`](https://docs.rs/zenoh/1.9.0/zenoh/trait.Resolvable.html) builder finished with `.wait()`/`.await`; the pre-resolved C API (`z_open`, `z_put`, `z_declare_publisher`) and Zenoh.jl run on the spot.

### Prefix taxonomy

The wrapped C symbols carry one of three prefixes:

- `z_` — the core API, shared with zenoh-pico (`z_open`, `z_put`, `z_declare_subscriber`).
- `zc_` — zenoh-c specific (`zc_config_from_env`, `zc_config_to_string`).
- `ze_` — zenoh-ext, outside the core protocol.

!!! warning "Not core Zenoh"
    Some features sit outside the core protocol. [Advanced Pub/Sub](manual/advanced-pubsub.md) wraps [zenoh-ext](https://docs.rs/zenoh-ext/1.9.0/zenoh_ext/) (`ze_*` symbols), as does the structured serializer on [Payloads & Serialization](manual/payloads-and-serialization.md).

!!! note "ZRef has no Zenoh counterpart"
    [`ZRef`](@ref) — a typed, transport-agnostic payload handle — is a Zenoh.jl construct with no direct Zenoh, Rust, or C equivalent.
