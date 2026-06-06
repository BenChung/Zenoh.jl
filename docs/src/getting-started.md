```@meta
CurrentModule = Zenoh
```

# Getting Started

[Zenoh](https://zenoh.io/docs/manual/abstractions/) is a distributed key/value
data space supporting pub/sub, distributed queries, and storage, where `/` is the
hierarchical key separator. Zenoh.jl wraps the C library (`libzenohc`, the
zenoh-c bindings) so a Julia program joins that data space as a full peer:
publish values, subscribe to changes, serve and issue queries.

This page walks the end-to-end flow with verified, runnable examples: build a
[`Config`](@ref) and open a [`Session`](@ref), publish with [`put`](@ref),
subscribe with both the callback and channel forms, query with `get`, then shut
down with `close`. Each section links to the manual page that covers it in
depth.

The examples need a live Zenoh network (a peer or a router) to exchange data, so
they are shown as plain code rather than executed doctests. Start a router with
`zenohd` from a [Zenoh release](https://zenoh.io/docs/getting-started/installation/),
or run two Julia sessions in peer mode against each other.

## The wrapper model in one paragraph

Every Zenoh entity Julia holds — a session, a publisher, a subscriber — is a
resource with two release paths: an explicit `close` that releases it
deterministically on your task, and a GC finalizer that releases it for you if
you forget. `close` is idempotent, so calling it twice is harmless. Operations
run immediately, returning their result or throwing a `ZenohError`. See the
[Zenoh.jl](@ref) home page for the full ownership story.

## Connect: build a config, open a session

A [`Session`](@ref) holds the runtime that connects your node to the Zenoh
network. Open one from a [`Config`](@ref). With no arguments the config uses
Zenoh's built-in defaults (peer mode, multicast scouting on):

```julia
using Zenoh

s = open(Config())   # defaults: peer mode, multicast discovery
```

`Config(; ...)` builds from at most one source — the built-in defaults, the
`ZENOH_CONFIG` environment variable (`from_env=true`), a file (`file="..."`), or
a JSON5 string (`str="..."`):

```julia
cfg = Config(; str = """{ mode: "peer" }""")
cfg["connect/endpoints"] = ["tcp/localhost:7447"]   # JSON5-serialized insert
s = open(cfg)
```

`open` copies the config, so one `Config` opens many sessions. Indexing reads
and writes raw dotted keys. Assigning a `String` inserts it verbatim as
pre-formatted JSON5; assigning any other Julia value serializes it to JSON5
first. The typed [`ZenohConfig`](@ref) builder is the idiomatic way to assemble
a configuration — the [Sessions & Configuration](@ref) page covers both layers
and the indexing trap in full.

Inspect a live session through these free functions — [`zid`](@ref),
[`router_zids`](@ref), and [`peer_zids`](@ref):

```julia
zid(s)          # this session's 16-byte Zenoh ID
to_le_bytes(zid(s))  # that ID as its raw little-endian NTuple{16,UInt8}
router_zids(s)  # IDs of connected routers
peer_zids(s)    # IDs of connected peers
isopen(s)       # true until close
```

[`to_le_bytes`](@ref) returns the ID in the byte order Zenoh hashes and
serializes, which is the reverse of the printed/`show`n string.

## Publish: put a value

[`put`](@ref) associates a payload with a key expression. The one-shot session
form needs no declared publisher and carries per-call QoS:

```julia
put(s, kexpr"demo/example/temp", "21.5"; encoding = "text/plain")
```

`kexpr"..."` builds a [`Keyexpr`](@ref) at parse time; `Keyexpr("demo/...")` is
the plain constructor. For repeated publication on one key, declare a long-lived
[`Publisher`](@ref): its QoS is fixed at declare time, so `put(p, payload; ...)`
takes only per-call `timestamp`/`encoding`/`attachment`.

```julia
pub = Publisher(s, kexpr"demo/example/temp")
put(pub, "22.0"; encoding = "text/plain")
close(pub)   # undeclare; idempotent
```

[Publish & Subscribe](@ref) covers QoS keywords, the QoS singletons, and
`delete!` (publishing a tombstone sample).

## Subscribe: callback form

A subscriber registers interest in every change to keys matching a key
expression and receives a [`Sample`](@ref) per `put`/`delete`. The callback form
runs your function on a dedicated task for each sample:

```julia
sub = open(s, kexpr"demo/example/**") do smpl::Sample
    println(keyexpr(smpl), " => ", String(payload(smpl)))
end

# ... later, when done:
close(sub)   # REQUIRED — a callback subscriber has no GC finalizer
```

A slow callback sees only the most recent message: the handoff is a single
latest-wins cell, so a sample arriving before the previous one is consumed
overwrites it. A callback subscriber must be closed explicitly — it has no GC
finalizer and leaks until `close(sub)`.

## Subscribe: channel form

The channel form returns a buffered handler you iterate or poll for samples:

```julia
buf = open(s, kexpr"demo/example/**"; channel = :ring, capacity = 64)
for smpl in buf
    @show keyexpr(smpl) payload(smpl)
end
close(buf)
```

!!! warning "`:fifo` is drop-oldest, not lossless"
    `channel = :fifo` (the default), `:ring`, and the unnamed default all resolve
    to the same bounded **keep-last-`capacity`** ring: on overflow the *oldest*
    buffered sample is dropped. The producer never blocks. For lossless delivery
    bounded only by memory, use `channel = :keep_all`. See
    [Publish & Subscribe](@ref) for the full delivery-policy table and
    `dropped_count`.

Iterating a `:fifo`/`:ring` handler reuses one buffer per step for zero
per-sample allocation, so a yielded `Sample` is valid only until the next
iteration — do not stash or `collect` it. To hold a sample past the loop step,
choose one:

- `take!` returns an owned sample.
- `recv!(sub, ::SampleHolder)` fills a caller-owned holder for a zero-allocation
  loop (see the [`recv!`](@ref) docstring for the `SampleHolder` pattern).
- `channel = :keep_all` yields owned samples throughout.

## Query: get replies from queryables

`get` issues a query on a key expression and returns a [`GetHandler`](@ref) over
the [`Reply`](@ref) values that matching queryables send back. Iteration ends
once every peer has replied or the timeout elapses, so a `GetHandler` needs no
explicit close:

```julia
gh = get(s, kexpr"demo/example/**", "arg=1"; timeout_ms = 1000)
for r in gh
    if is_ok(r)
        smpl = sample(r)
        println(keyexpr(smpl), " => ", String(payload(smpl)))
    else
        println("ERR: ", String(error_payload(r)))
    end
end
```

`get` is a method of `Base.get`, not a new export, so `get(s, ...)` resolves
through `Base` like any other `get` call. The server side, [`Queryable`](@ref),
and the full set of query options (`target`, `consolidation`, `cancellation`,
and more) live on the [Queries](@ref) page.

## Clean shutdown

`close` shuts a session down gracefully and releases its resources
deterministically on your task. After `close` the session throws on any further
use. Wrap the lifecycle in `try`/`finally` so teardown runs even on error:

```julia
s = open(Config())
try
    put(s, kexpr"demo/example/temp", "21.5")
    # ... declare publishers/subscribers/queryables, do work ...
finally
    close(s)   # idempotent; renders s unusable afterward
end
```

Close declared entities (publishers, subscribers, queryables) on their own;
their lifetime is independent of the session's. The callback `Subscriber` in
particular has no finalizer and must be closed; buffered handlers and publishers
carry a finalizer safety net but `close` remains the deterministic path.

## Mapping to Zenoh, Rust, and C

| Zenoh.jl | Zenoh abstraction | Rust | zenoh-c |
| --- | --- | --- | --- |
| `Config` | [Config](https://docs.rs/zenoh/1.9.0/zenoh/config/index.html) | [`zenoh::config::Config`](https://docs.rs/zenoh/1.9.0/zenoh/struct.Config.html) | `z_owned_config_t` (`z_config_default` / `zc_config_from_env` / `zc_config_from_file` / `zc_config_from_str`) |
| `open(c::Config)` | open a session | [`zenoh::open`](https://docs.rs/zenoh/1.9.0/zenoh/session/index.html) | `z_open` |
| `Session` | [Session](https://docs.rs/zenoh/1.9.0/zenoh/session/index.html) | [`zenoh::session::Session`](https://docs.rs/zenoh/1.9.0/zenoh/struct.Session.html) | `z_owned_session_t` |
| `close(s::Session)` | — | `Session::close` | `z_close` + `z_session_drop` |
| `zid` / `router_zids` / `peer_zids` | ZenohId | `SessionInfo::zid/routers_zid/peers_zid` | `z_info_zid` / `z_info_routers_zid` / `z_info_peers_zid` |
| `to_le_bytes` | ZenohId | [`ZenohId::to_le_bytes`](https://docs.rs/zenoh/1.9.0/zenoh/config/struct.ZenohId.html#method.to_le_bytes) | the raw `z_id_t.data` little-endian bytes |
| `put` | [Publisher](https://zenoh.io/docs/manual/abstractions/#publisher) / put | `Session::put` / `Publisher::put` | `z_put` / `z_publisher_put` |
| `Publisher` | [Publisher](https://zenoh.io/docs/manual/abstractions/#publisher) | [`zenoh::pubsub::Publisher`](https://docs.rs/zenoh/1.9.0/zenoh/pubsub/struct.Publisher.html) | `z_owned_publisher_t` (`z_declare_publisher`) |
| `open(f, s, k)` / `open(s, k; channel)` | [Subscriber](https://zenoh.io/docs/manual/abstractions/#subscriber) | [`zenoh::pubsub::Subscriber`](https://docs.rs/zenoh/1.9.0/zenoh/pubsub/struct.Subscriber.html) | `z_declare_subscriber` + `z_closure_sample` |
| `get` → `GetHandler` | [Queryable](https://zenoh.io/docs/manual/abstractions/#queryable) / get | [`Session::get`](https://docs.rs/zenoh/1.9.0/zenoh/struct.Session.html#method.get) | `z_get` + `z_closure_reply` |

Each Zenoh.jl call is the eagerly-resolved equivalent of the named Rust and C
operation, with these named divergences:

- **No builder/Resolvable layer.** Rust returns
  [`Resolvable`](https://docs.rs/zenoh/1.9.0/zenoh/trait.Resolvable.html) builders
  finished with `.wait()`/`.await`; Zenoh.jl's `open`, `put`, `Publisher(s,k)`,
  and `get` execute immediately and return their result or throw `ZenohError`.
  This matches the already-resolved C API (`z_open`, `z_put`, …).
- **`open` copies the config.** `open(c::Config)` clones the config before
  handing it off, so one `Config` opens many sessions — unlike a raw `z_open`,
  which consumes (moves) it.
- **`close` is explicit and deterministic.** Rust auto-closes when the last
  `Session` clone drops; Zenoh.jl runs `z_close` then `z_session_drop` on your
  task, with the finalizer only as a safety net.
- **No `SessionInfo`.** Rust groups `zid`/`routers_zid`/`peers_zid` under
  `Session::info()`; Zenoh.jl exposes three free functions directly on the
  session.

!!! warning "`channel = :fifo` is keep-last, not Rust's FifoChannel"
    The buffered subscriber's `:fifo`/`:ring` options implement
    [`RingChannel`](https://docs.rs/zenoh/1.9.0/zenoh/handlers/struct.RingChannel.html)
    drop-oldest semantics, not the lossless backpressure of Rust's
    [`FifoChannel`](https://docs.rs/zenoh/1.9.0/zenoh/handlers/struct.FifoChannel.html).
    Delivery runs on a Julia-side ring rather than the native
    `z_fifo_channel_*` / `z_ring_channel_*` handlers. Use `:keep_all` for
    lossless delivery. Details on [Publish & Subscribe](@ref).

The ownership prefixes carry meaning: `z_` is the core API shared with
zenoh-pico, `zc_` is zenoh-c-specific (the config `from_env`/`from_file`/
`from_str`/`to_string` calls), and `ze_` is non-core (zenoh-ext). The
[owned/loaned/moved/view type model](https://zenoh-c.readthedocs.io/en/1.9.0/concepts.html)
and the [zenoh-c API index](https://zenoh-c.readthedocs.io/en/1.9.0/api.html)
describe the C surface Zenoh.jl wraps.