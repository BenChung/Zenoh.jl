```@meta
CurrentModule = Zenoh
```

# Matching

Matching answers one question about a [`Publisher`](@ref) or [`Querier`](@ref): is there anyone on the other side of my key expression right now? Zenoh calls this the [matching status](https://docs.rs/zenoh/1.9.0/zenoh/matching/): whether any entity whose key expression overlaps yours currently exists. For a publisher the matching set is the subscribers whose key expressions overlap its own; for a querier it is the queryables that match its key expression and target. Matching lets a producer skip work, log a warning, or pause until a consumer is present.

Zenoh.jl exposes exactly two operations, both boolean-valued. [`matching_status`](@ref) takes a one-shot snapshot. [`MatchingListener`](@ref) declares a foreground listener whose callback fires on every transition between an empty and a non-empty matching set. Both work uniformly across `Publisher`, `Querier`, and [`AdvancedPublisher`](@ref).

## One-shot poll

[`matching_status`](@ref) reads the current state and returns a `Bool`. `true` means at least one matching peer exists at the moment of the call.

```julia
using Zenoh

session = Zenoh.open(Config())
pub = Publisher(session, Keyexpr("demo/example/**"))

if matching_status(pub)
    @info "at least one subscriber is listening"
else
    @info "no subscribers yet"
end
```

For a [`Querier`](@ref) the same call reports matching queryables instead of subscribers:

```julia
q = Querier(session, Keyexpr("demo/example/**"))
matching_status(q)   # Bool: does any queryable match this querier's key expression and target?
```

## Reacting to changes

[`MatchingListener`](@ref) declares a foreground listener and runs your callback `f(::Bool)` on a dedicated Julia task. The callback is edge-triggered: it fires when the matching set crosses the empty/non-empty boundary, once per crossing regardless of how many peers cross it.

- `f(true)` — a matching peer now exists where there were none.
- `f(false)` — the last matching peer departed.

```julia
ml = MatchingListener(pub) do matching::Bool
    @info matching ? "a subscriber is now listening" : "all subscribers left"
end

# ... publish while reacting to matching changes ...

close(ml)   # undeclare the listener
```

For a [`Querier`](@ref), the transitions track queryables; the API is otherwise identical:

```julia
ml = MatchingListener(q) do matching::Bool
    @info "matching queryables present" matching
end
```

### Delivery is single-slot, latest-wins

Delivery is single-slot, latest-wins: each new status overwrites any undelivered one, so a slow callback always sees the current state (the same single-slot model as [`Subscriber`](@ref)). For matching status this is the right trade — transitions are infrequent and each notification is idempotent, so collapsing a rapid empty→non-empty→empty burst to its endpoint leaves you with exactly the state you need to act on.

### Lifecycle

For deterministic teardown, call [`close`](@ref) on the listener: it tears the listener down promptly, drains any in-flight callback, and stops the consumer task. `close` is idempotent. GC finalization tears the listener down as a safety net, on no fixed schedule.

By default a callback that throws tears its own listener task down; pass `should_close_on_error=false` to keep the task alive and log each error instead.

## Advanced publishers

[`AdvancedPublisher`](@ref) supports the same two operations with identical semantics (matching subscribers):

```julia
ap = AdvancedPublisher(session, Keyexpr("demo/example/**"); cache=CacheOptions(max_samples=10))
matching_status(ap)                       # Bool
ml = MatchingListener(ap) do m; @info m; end
close(ml)
```

See [Advanced Pub/Sub](@ref) for the publisher itself.

## API

```@docs
matching_status
MatchingListener
```

## Mapping to Zenoh, Rust, and C

C symbols printed as plain code spans (`z_undeclare_matching_listener`, `ze_advanced_publisher_*`) exist in zenoh-c but are not surfaced in the rendered 1.9.0 API index; search the index for the name. The published teardown entry for a listener handle is `z_matching_listener_drop`.

| Zenoh.jl | Zenoh abstraction | Rust | zenoh-c |
| --- | --- | --- | --- |
| [`matching_status`](@ref)`(::Publisher)` | [matching status](https://docs.rs/zenoh/1.9.0/zenoh/matching/) snapshot | [`Publisher::matching_status`](https://docs.rs/zenoh/1.9.0/zenoh/pubsub/struct.Publisher.html#method.matching_status) | [`z_publisher_get_matching_status`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html#_CPPv431z_publisher_get_matching_statusPK20z_loaned_publisher_tP19z_matching_status_t) |
| [`matching_status`](@ref)`(::Querier)` | matching status snapshot | [`Querier::matching_status`](https://docs.rs/zenoh/1.9.0/zenoh/query/struct.Querier.html) | [`z_querier_get_matching_status`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html#_CPPv429z_querier_get_matching_statusPK18z_loaned_querier_tP19z_matching_status_t) |
| [`matching_status`](@ref)`(::AdvancedPublisher)` | matching status snapshot | (zenoh-ext) | `ze_advanced_publisher_get_matching_status` |
| [`MatchingListener`](@ref)`(f, ::Publisher)` | [`MatchingListener`](https://docs.rs/zenoh/1.9.0/zenoh/matching/struct.MatchingListener.html) | [`Publisher::matching_listener`](https://docs.rs/zenoh/1.9.0/zenoh/pubsub/struct.Publisher.html#method.matching_listener) | [`z_publisher_declare_matching_listener`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html#_CPPv437z_publisher_declare_matching_listenerPK20z_loaned_publisher_tP27z_owned_matching_listener_tP33z_moved_closure_matching_status_t) |
| [`MatchingListener`](@ref)`(f, ::Querier)` | `MatchingListener` | [`Querier::matching_listener`](https://docs.rs/zenoh/1.9.0/zenoh/query/struct.Querier.html) | [`z_querier_declare_matching_listener`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html#_CPPv435z_querier_declare_matching_listenerPK18z_loaned_querier_tP27z_owned_matching_listener_tP33z_moved_closure_matching_status_t) |
| [`MatchingListener`](@ref)`(f, ::AdvancedPublisher)` | `MatchingListener` | (zenoh-ext) | `ze_advanced_publisher_declare_matching_listener` |
| `f(::Bool)` argument | [`MatchingStatus`](https://docs.rs/zenoh/1.9.0/zenoh/matching/struct.MatchingStatus.html) | `MatchingStatus::matching() -> bool` | [`z_matching_status_t`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html#_CPPv419z_matching_status_t) |
| [`close`](@ref)`(::MatchingListener)` | listener undeclaration | `MatchingListener::undeclare` / RAII drop | `z_undeclare_matching_listener` |

[`matching_status`](@ref) returns the same boolean as Rust's [`MatchingStatus::matching()`](https://docs.rs/zenoh/1.9.0/zenoh/matching/struct.MatchingStatus.html): `true` when matching subscribers (publisher) or queryables (querier) exist. The notification semantics of [`MatchingListener`](@ref) match the [`zenoh::matching`](https://docs.rs/zenoh/1.9.0/zenoh/matching/index.html) module exactly — a notification fires "when the first matching subscriber or queryable appears, or when the last one disappears." The points below describe Zenoh.jl's design choices at this boundary; the behavior matches Rust.

!!! note "No MatchingStatus value"
    Rust's [`MatchingStatus`](https://docs.rs/zenoh/1.9.0/zenoh/matching/struct.MatchingStatus.html) and C's `z_matching_status_t` are both structs, but each carries a single boolean field. Zenoh.jl unwraps that field at the boundary, so [`matching_status`](@ref) and the listener callback both deal in plain `Bool`.

!!! note "No builder — eager constructor"
    Rust declares a listener through `Publisher::matching_listener()`, which returns a `MatchingListenerBuilder` you configure and resolve. Zenoh.jl folds declaration into the eager constructor [`MatchingListener`](@ref)`(f, target)`, which takes the callback directly. Declaration, callback installation, and resolution all happen in that one call.

!!! note "Callback-only, single-slot delivery"
    The matching API provides callback-form listeners with single-slot latest-wins delivery; unlike [`Subscriber`](@ref) and [`Querier`](@ref) replies, it has no handler-buffered (FIFO/ring) variant.

!!! warning "Foreground listeners only"
    The background C entrypoints `z_publisher_declare_background_matching_listener`, `z_querier_declare_background_matching_listener`, and `ze_advanced_publisher_declare_background_matching_listener` exist in the bindings but are deliberately left unwrapped: they return no handle, so the closure lifetime would have to be pinned to the target or session. Only foreground listeners — those returning a [`MatchingListener`](@ref) you [`close`](@ref) explicitly — are available, across publisher, querier, and advanced publisher.

!!! note "Unified z_/ze_ surface"
    C splits matching across the core `z_` prefix and the zenoh-ext `ze_` prefix: the advanced-publisher path calls `ze_advanced_publisher_declare_matching_listener` / `ze_advanced_publisher_get_matching_status`. Zenoh.jl exposes all three targets through the same [`MatchingListener`](@ref) type and [`matching_status`](@ref) generic, reusing the `z_`-prefixed `z_owned_matching_listener_t` and `z_undeclare_matching_listener` for teardown.

!!! note "Explicit lifecycle"
    Rust relies on RAII drop (or an explicit `undeclare()`). Zenoh.jl uses an explicit, foreground-task lifecycle: call [`close`](@ref) for prompt teardown, with GC finalization as a safety net. The Julia-only `should_close_on_error` keyword (default `true`) governs whether a throwing callback tears down its consumer task.