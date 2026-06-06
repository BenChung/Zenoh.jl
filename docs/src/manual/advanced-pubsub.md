```@meta
CurrentModule = Zenoh
```

# Advanced Pub/Sub

Advanced Pub/Sub layers reliability onto plain [Publish & Subscribe](@ref). A
publisher caches recent samples and stamps each with a per-source sequence
number. A subscriber replays that cache on join, recovers gaps by querying for
retransmission, and reports any gap it cannot recover. These features build on
the core [Publisher](https://zenoh.io/docs/manual/abstractions/#publisher) ("an
entity declaring that it will be updating the key/value with keys matching a
given key expression") and [Subscriber](https://zenoh.io/docs/manual/abstractions/#subscriber)
("an entity registering interest for any change ... to a value associated with a
key matching the specified key expression") abstractions.

It is an unstable extension whose availability varies across Zenoh
implementations. Zenoh.jl exposes it through the concrete [`AdvancedPublisher`](@ref) and
[`AdvancedSubscriber`](@ref) types. Both kinds share `AbstractPublisher` /
`AbstractCallbackSubscriber` / `AbstractSubscriberHandler` with the plain types.
[`put`](@ref), `delete!`, `close`, iteration, [`MatchingListener`](@ref), and
[`matching_status`](@ref) therefore work uniformly across both.

!!! note "Timestamping is required"
    Cache and miss detection stamp every sample, so the session must have
    timestamping enabled. Open it with
    `Zenoh.open(Zenoh.Config(; str="{timestamping:{enabled:true}}"))` (or deploy
    behind a router that timestamps). Without it, declaring an advanced
    publisher with `cache` or `miss_detection` raises an error.

## Declaring advanced endpoints

Two paths construct an advanced endpoint, and both return a type-stable concrete
value:

1. **Routing.** [`Publisher`](@ref) and [`open`](@ref open) return an advanced
   type when any advanced keyword is present. Each advanced keyword carries its
   own options value, and presence of the keyword is the opt-in. Shared QoS
   keywords (`priority`, `reliability`, ...) never route.
2. **Direct construction.** [`AdvancedPublisher`](@ref) and
   [`AdvancedSubscriber`](@ref) always return the concrete advanced type,
   regardless of which keywords you pass.

The publisher keywords are `cache`, `miss_detection`, and `detection`; the
subscriber keywords are `history`, `recovery`, `query_timeout_ms`, and
`detection`.

```julia
using Zenoh

# Cache and miss detection stamp samples, so timestamping must be enabled.
s = Zenoh.open(Zenoh.Config(; str = "{timestamping:{enabled:true}}"))
key = Zenoh.Keyexpr("demo/advanced")

# Routes to an AdvancedPublisher because `cache` is present.
ap = Zenoh.Publisher(s, key;
        cache = CacheOptions(max_samples = 64),
        miss_detection = MissDetectionOptions(heartbeat = :periodic, period_ms = 100),
        priority = Zenoh.Priorities.REAL_TIME)
@assert isadvanced(ap)

Zenoh.put(ap, "hello")
```

### Holding an advanced endpoint in a struct

Routing means `Publisher(s, k; cache=...)` returns an `AdvancedPublisher`, not a
`Publisher`. Type such a field by the shared supertype, because a field typed as
the concrete `Publisher` rejects an `AdvancedPublisher` with a `MethodError` on
`convert`:

```julia
struct Sensor{P<:Zenoh.AbstractPublisher}
    pub::P
end
```

Use [`isadvanced`](@ref) when generic code must branch on which kind a routing
constructor returned.

## Publisher cache and miss detection

The publisher side carries two reliability features, each configured by an
options struct:

- [`CacheOptions`](@ref) retains the last `max_samples` samples and serves them
  to late-joining or recovering subscribers. `cache = 64` is shorthand for
  `cache = CacheOptions(max_samples = 64)`.
- [`MissDetectionOptions`](@ref) stamps samples with per-source sequence numbers
  so subscribers can detect gaps, and selects a heartbeat that advertises the
  latest sequence number. `heartbeat` is `:none`, `:periodic`, or `:sporadic`;
  `period_ms` tunes the periodic heartbeat. `miss_detection = :periodic` is
  shorthand for `miss_detection = MissDetectionOptions(heartbeat = :periodic)`.

```julia
# Cache 64 samples; emit a periodic heartbeat every 100 ms.
ap = Zenoh.AdvancedPublisher(s, key;
        cache = 64,
        miss_detection = MissDetectionOptions(heartbeat = :periodic, period_ms = 100))
```

An advanced publisher publishes and tombstones exactly like a plain one:

```julia
Zenoh.put(ap, "value")
Zenoh.delete!(ap)            # DELETE-kind sample on the keyexpr
```

It also supports matching introspection — [`matching_status`](@ref) polls once
for a matching subscriber, and [`MatchingListener`](@ref) notifies on each
transition (see [Matching](@ref)).

## Subscriber history and recovery

The subscriber side mirrors the publisher's two features:

- [`HistoryOptions`](@ref) queries matching advanced publishers on declaration
  and replays their cached samples. `max_samples` and `max_age_ms` bound the
  replay window (`0` means unbounded); `detect_late_publishers` also back-fills
  from publishers that appear after the subscriber.
- [`RecoveryOptions`](@ref) recovers gaps in one of two modes. The default
  `RecoveryOptions()` recovers from the publisher heartbeat and sequence numbers
  alone; a positive `periodic_queries_period_ms` additionally polls for missed
  last samples at that interval. Both modes need a publisher with
  `miss_detection`; query-based recovery also needs the publisher's `cache`.

The `query_timeout_ms` keyword bounds the per-query timeout (milliseconds) for
history replay and query-based recovery.

```julia
# Late-joining subscriber: replay up to 64 cached samples, then recover gaps.
asub = Zenoh.AdvancedSubscriber(s, key;
        history  = HistoryOptions(max_samples = 64, detect_late_publishers = true),
        recovery = RecoveryOptions(periodic_queries_period_ms = 1000)) do sample
    @info "got" payload = String(Zenoh.payload(sample))
end
```

The callback form runs `f(::Sample)` on a dedicated task with a latest-wins
single slot, exactly like the plain [`Subscriber`](@ref). The no-callback form
returns a buffered [`AdvancedSubscriberHandler`](@ref) that you iterate or poll
with `take!` / `tryrecv!`:

```julia
h = Zenoh.AdvancedSubscriber(s, key; channel = :fifo, capacity = 16,
                             history = HistoryOptions())
sample = Zenoh.tryrecv!(h)   # nothing if the buffer is empty
```

`channel` selects the same History policy as a plain
[`SubscriberHandler`](@ref): `:fifo` / `:ring` is a drop-oldest bounded ring,
and `:keep_all` is a heap-backed unbounded buffer.

## Reacting to unrecoverable gaps

When a gap cannot be recovered, an [`AdvancedSubscriber`](@ref) surfaces it as a
[`SampleMiss`](@ref): `source` is the publishing endpoint's entity id and `count`
is the number of missed samples. [`SampleMissListener`](@ref) runs
`f(::SampleMiss)` on a dedicated task for each one; `close` undeclares it.

```julia
ml = Zenoh.SampleMissListener(asub) do miss::SampleMiss
    @warn "missed samples" source = miss.source count = miss.count
end

# ...

close(ml)
```

`SampleMissListener` is declared on the concrete `AdvancedSubscriber` type, which
alone carries miss detection.

## Liveliness-based endpoint detection

Pass `detection = DetectionOptions()` on either side to advertise the endpoint
for liveliness-based discovery. On the publisher it lets matching subscribers
discover it; on the subscriber it lets `HistoryOptions(detect_late_publishers =
true)` find publishers that join later. Back-filling from late publishers
therefore requires the publisher to enable both `detection` and `cache`.

```julia
ap = Zenoh.AdvancedPublisher(s, key;
        cache = 64, detection = DetectionOptions())
asub = Zenoh.AdvancedSubscriber(s, key;
        detection = DetectionOptions(),
        history = HistoryOptions(detect_late_publishers = true)) do sample
    # ...
end
```

## API

```@docs
AdvancedPublisher
AdvancedSubscriber
AdvancedSubscriberHandler
CacheOptions
MissDetectionOptions
HistoryOptions
RecoveryOptions
DetectionOptions
SampleMiss
SampleMissListener
isadvanced
put(::AdvancedPublisher, ::Any)
MatchingListener(::Function, ::AdvancedPublisher)
matching_status(::AdvancedPublisher)
```

## Mapping to Zenoh, Rust, and C

| Zenoh.jl | Zenoh abstraction | Rust (`zenoh-ext`) | zenoh-c (`ze_`) |
| --- | --- | --- | --- |
| [`AdvancedPublisher`](@ref) | Publisher extension | [`AdvancedPublisher`](https://docs.rs/zenoh-ext/latest/zenoh_ext/struct.AdvancedPublisher.html) / [`AdvancedPublisherBuilder`](https://docs.rs/zenoh-ext/latest/zenoh_ext/struct.AdvancedPublisherBuilder.html) | `ze_declare_advanced_publisher` |
| [`AdvancedSubscriber`](@ref) / [`AdvancedSubscriberHandler`](@ref) | Subscriber extension | [`AdvancedSubscriber`](https://docs.rs/zenoh-ext/latest/zenoh_ext/struct.AdvancedSubscriber.html) / [`AdvancedSubscriberBuilder`](https://docs.rs/zenoh-ext/latest/zenoh_ext/struct.AdvancedSubscriberBuilder.html) | `ze_declare_advanced_subscriber` |
| [`CacheOptions`](@ref) | publisher cache | [`CacheConfig`](https://docs.rs/zenoh-ext/latest/zenoh_ext/struct.CacheConfig.html) | `ze_advanced_publisher_cache_options_t` |
| [`MissDetectionOptions`](@ref) | sample-miss detection | [`MissDetectionConfig`](https://docs.rs/zenoh-ext/latest/zenoh_ext/struct.MissDetectionConfig.html) | `ze_advanced_publisher_sample_miss_detection_options_t` |
| [`HistoryOptions`](@ref) | history replay | [`HistoryConfig`](https://docs.rs/zenoh-ext/latest/zenoh_ext/struct.HistoryConfig.html) | `ze_advanced_subscriber_history_options_t` |
| [`RecoveryOptions`](@ref) | gap recovery | [`RecoveryConfig`](https://docs.rs/zenoh-ext/latest/zenoh_ext/struct.RecoveryConfig.html) | `ze_advanced_subscriber_recovery_options_t` |
| [`DetectionOptions`](@ref) | liveliness detection | `publisher_detection()` / `subscriber_detection()` | `publisher_detection` / `subscriber_detection` field |
| [`SampleMiss`](@ref) | missed-sample record | [`Miss`](https://docs.rs/zenoh-ext/latest/zenoh_ext/struct.Miss.html) | `ze_miss_t` |
| [`SampleMissListener`](@ref) | miss listener | [`SampleMissListener`](https://docs.rs/zenoh-ext/latest/zenoh_ext/struct.SampleMissListener.html) | `ze_advanced_subscriber_declare_sample_miss_listener` + `ze_closure_miss` |
| [`put`](@ref) / `delete!` | publish / tombstone | `AdvancedPublisher::put` / `::delete` | `ze_advanced_publisher_put` / `ze_advanced_publisher_delete` |
| [`MatchingListener`](@ref) / [`matching_status`](@ref) | matching status | matching status (shared) | `ze_advanced_publisher_declare_matching_listener` / `ze_advanced_publisher_get_matching_status` |
| [`isadvanced`](@ref) | — | — | — |

The option structs map onto the C nested option structs field-for-field:
`CacheOptions` onto `ze_advanced_publisher_cache_options_t`,
`MissDetectionOptions` onto `ze_advanced_publisher_sample_miss_detection_options_t`,
`HistoryOptions` onto `ze_advanced_subscriber_history_options_t`, and
`RecoveryOptions` onto `ze_advanced_subscriber_recovery_options_t`. Presence of
the corresponding keyword forces the struct's `is_enabled` flag true. The
prefixes follow the [zenoh-c naming convention](https://zenoh-c.readthedocs.io/en/1.9.0/concepts.html):
`z_` is the core Zenoh API, `zc_` is zenoh-c-specific, and `ze_` is API outside
the core with no cross-implementation guarantee — Advanced Pub/Sub is entirely
`ze_`. The advanced data path reuses the core `z_closure_sample` callback; only
miss notifications use a dedicated `ze_closure_miss`.

!!! warning "Not a core Zenoh abstraction"
    Advanced Pub/Sub is absent from the [Zenoh abstractions page](https://zenoh.io/docs/manual/abstractions/).
    It is an unstable `zenoh-ext` / `ze_` extension layered on the Publisher and
    Subscriber abstractions, with no guarantee that it is available across Zenoh
    implementations.

Several Zenoh.jl shapes diverge from the Rust API and must be stated precisely:

- **Routing has no Rust or C analogue.** Folding advanced and plain endpoints
  under shared abstract types and routing `Publisher(s, k; ...)` /
  `open(s, k; ...)` to an advanced type by keyword presence is a Zenoh.jl
  feature. Rust uses distinct builder types
  ([`AdvancedPublisherBuilder`](https://docs.rs/zenoh-ext/latest/zenoh_ext/struct.AdvancedPublisherBuilder.html)),
  and C uses separate `ze_declare_*` entrypoints; neither routes on values.
- **`detection` is a presence marker.** Opting in passes
  `detection = DetectionOptions()`, the analogue of Rust's
  `publisher_detection()` / `subscriber_detection()` builder calls; there is no
  `detection = true/false` form. The detection-metadata keyexpr
  (`publisher_detection_metadata` in Rust/C) is not yet exposed.
- **`MissDetectionOptions` collapses two Rust methods.** Rust's
  [`MissDetectionConfig`](https://docs.rs/zenoh-ext/latest/zenoh_ext/struct.MissDetectionConfig.html)
  has separate `heartbeat(Duration)` and `sporadic_heartbeat(Duration)` methods;
  Zenoh.jl uses a single `heartbeat::Symbol` (`:none` / `:periodic` /
  `:sporadic`) plus `period_ms`, mirroring the C `ze_advanced_publisher_heartbeat_mode_t`
  enum.
- **`CacheOptions` flattens reply QoS.** Rust's
  [`CacheConfig`](https://docs.rs/zenoh-ext/latest/zenoh_ext/struct.CacheConfig.html)
  configures reply QoS through a nested `replies_config(RepliesConfig)`;
  `CacheOptions` exposes `congestion_control` / `priority` / `express` as flat
  fields, matching the flat C `ze_advanced_publisher_cache_options_t`.
- **`RecoveryOptions` is narrower than Rust.** Rust's
  [`RecoveryConfig`](https://docs.rs/zenoh-ext/latest/zenoh_ext/struct.RecoveryConfig.html)
  has distinct `heartbeat()` and `periodic_queries(Duration)` modes. Zenoh.jl
  exposes only `periodic_queries_period_ms`: a positive value enables periodic
  queries, and `0` (the default) recovers from the heartbeat and sequence
  numbers alone — the C analogue of Rust's `RecoveryConfig::heartbeat()`.
- **Time units are milliseconds.** `max_age_ms`, `period_ms`, and
  `periodic_queries_period_ms` are `UInt64` milliseconds, matching the C
  `*_ms` fields. Rust's `HistoryConfig::max_age` takes `f64` seconds and its
  heartbeat/query methods take a `Duration`, so a ported Rust example must
  convert.

!!! note "Zenoh.jl extension"
    [`isadvanced`](@ref) is a Julia-only trait with no Zenoh, Rust, or C
    counterpart. Rust and C yield a distinct advanced type by construction.