```@meta
CurrentModule = Zenoh
```

# Publish & Subscribe

Publish/subscribe is Zenoh's primary data-flow primitive. A [publisher](https://zenoh.io/docs/manual/abstractions/#publisher) declares intent to update values under a key expression and moves data with `put` (an update) or `delete!` (a tombstone); every matching [subscriber](https://zenoh.io/docs/manual/abstractions/#subscriber) receives one [`Sample`](@ref) per call. In Zenoh's own words a publisher is "an entity declaring that it will be updating the key/value with keys matching a given key expression," and a subscriber is "an entity registering interest for any change (put or delete) to a value associated with a key matching the specified key expression."

Every option is a keyword argument on [`Publisher`](@ref), `put`, `open`, or `get`. The two routing factories [`Publisher`](@ref)`(s, k; …)` and `open(s, k; …)` declare the long-lived endpoints; [`put`](@ref)`(s, k, payload)` and `delete!(s, k)` give a one-shot path that skips declaration entirely. Subscribers come in two delivery models: a callback on a dedicated task, and a buffered handler you iterate or poll.

## Publishing

A [`Publisher`](@ref) is a long-lived handle declared once and reused for many `put`/`delete!` calls. Its quality-of-service is fixed at declare time, so each `put` carries only `timestamp`, `encoding`, and `attachment`.

```julia
using Zenoh

s = Zenoh.open(Config())                       # a Session — see [Sessions & Configuration](@ref)

pub = Publisher(s, kexpr"demo/temp";
                congestion_control = CongestionControls.BLOCK,
                priority           = Priorities.REAL_TIME)

put(pub, "21.5"; encoding = "text/plain")       # an update sample
delete!(pub)                                    # a tombstone on demo/temp
close(pub)                                      # undeclare
```

The QoS keywords (`congestion_control`, `priority`, `express`, `reliability`, `allowed_destination`) accept the typed singletons from [Quality of Service](@ref) and are baked into the publisher at declare time. `put(pub, …)` cannot override them — see the divergence below.

### Session one-shot publish

When you publish to a key expression only once, [`put`](@ref)`(s, k, payload)` and `delete!(s, k)` send a single sample without declaring a publisher. The session forms carry QoS inline on each call, since there is no long-lived publisher to hold it:

```julia
put(s, kexpr"demo/temp", "22.0";
    priority           = Priorities.DATA,
    congestion_control = CongestionControls.DROP)
delete!(s, kexpr"demo/temp")
```

Reach for a declared [`Publisher`](@ref) when you publish repeatedly on one key (it amortizes route resolution); reach for the session form for occasional or one-off updates.

## Subscribing

`open(s, k; …)` registers interest in every `put`/`delete!` matching key expression `k`. Two delivery models are available, chosen by call shape.

### Callback subscriber

`open(f, s, k)` runs `f(::Sample)` on a dedicated Julia task. Delivery is **latest-wins through a single inline cell**: the Zenoh I/O thread stashes each sample in a capacity-1 slot and wakes the task; a sample arriving while the previous one is unconsumed overwrites it. A slow callback therefore sees only the most recent message, and older ones are dropped silently.

```julia
sub = open(s, kexpr"demo/**") do smpl::Sample
    println(keyexpr(smpl), " = ", payload(smpl))
end

# ... later, REQUIRED:
close(sub)
```

Always pair `open(f, …)` with `close(sub)`: a callback [`Subscriber`](@ref) has no automatic cleanup, so it and its consume task leak until you close it explicitly.

### Buffered subscriber

`open(s, k; channel=…, capacity=N)` returns a handler you drive yourself — iterate it, or pull with [`take!`](@ref take!), [`tryrecv!`](@ref), or [`recv!`](@ref). The `channel` keyword selects the buffering policy:

- `:fifo` / `:ring` (the default) — a bounded, **drop-oldest** ring of `capacity` slots: ROS2 KEEP_LAST(capacity). Returns a [`SubscriberHandler`](@ref). `dropped_count(sub)` reports evictions.
- `:keep_all` — a consume task drains into an unbounded, heap-backed buffer: ROS2 KEEP_ALL, bounded only by memory. Returns a [`KeepAllSubscriber`](@ref). Here `capacity` is a floor on the internal handoff ring, not a bound on the backlog.

```julia
buf = open(s, kexpr"demo/**"; channel = :ring, capacity = 64)
for smpl in buf                 # valid only until the next iteration
    @show keyexpr(smpl) payload(smpl)
end
@show dropped_count(buf)
close(buf)
```

Neither model blocks the Zenoh I/O thread: all buffered delivery is a Julia-side ring filled on the I/O thread and drained on a Julia task. Closing undeclares the subscriber; iteration ends once the buffer drains.

!!! warning "`channel=:fifo` is drop-oldest, not lossless backpressure"
    Despite the name, `:fifo` (like `:ring` and the default) keeps the last `capacity` samples and drops the oldest on overflow; it never blocks the producer. A reader who picks `:fifo` expecting no data loss loses data silently under a slow consumer. For lossless delivery use `channel=:keep_all`, which trades memory for losslessness and OOMs (rather than deadlocks) under sustained overload.

### Iteration sample lifetime

`for s in sub` and the in-place receives recycle their storage for zero per-sample allocation, so a yielded [`Sample`](@ref) is valid **only until the next iteration**. Stashing it across iterations or `collect`ing the handler is a use-after-free.

To hold a sample beyond the current step, use [`take!`](@ref take!) (returns a [`Sample`](@ref) you can keep) or a `:keep_all` subscriber (yields samples you can keep). For an allocation-free receive loop, reuse one [`SampleHolder`](@ref) with [`recv!`](@ref):

```julia
h = SampleHolder()
while (smpl = recv!(buf, h)) !== nothing
    process(smpl)               # valid only until the next recv!; don't stash it
end
```

[`take!`](@ref take!) blocks for the next sample; [`tryrecv!`](@ref) is the non-blocking variant, returning `nothing` when the buffer is empty or the subscriber is closed.

## Locality filtering

`allowed_origin` on a subscriber and `allowed_destination` on a publisher (or session `put`/`get`) restrict which peers participate, using the `Localities` singletons from [Quality of Service](@ref):

```julia
local_only = open(s, kexpr"demo/**"; allowed_origin = Localities.SESSION_LOCAL) do smpl
    handle(smpl)
end
```

## Routing constructors and advanced features

[`Publisher`](@ref)`(s, k; …)` and `open(…)` are routing factories: passing an advanced feature keyword changes the returned type to the corresponding `Advanced*` variant. For publishers the advanced keywords are `cache`, `miss_detection`, and `detection`; for subscribers they are `history`, `recovery`, `query_timeout_ms`, and `detection`. Routing keys on keyword *presence* (a type-level property), so the return type stays inference-stable. A caller needing a guaranteed concrete return type should construct the `Advanced*` type directly. History replay and sample-miss recovery are covered in [Advanced Pub/Sub](@ref).

## Queries share the delivery machinery

`get`, [`Reply`](@ref), and [`GetHandler`](@ref) reuse the buffered subscriber's callback-ring delivery, so the reply types share the machinery on this page even though queries are a distinct abstraction documented in [Queries](@ref). A query returns a [`GetHandler`](@ref) over [`Reply`](@ref) values; discriminate each with [`is_ok`](@ref), then read [`sample`](@ref) on the ok branch or [`error_payload`](@ref) / [`error_encoding`](@ref) on the error branch. See [Queries](@ref) for the full query semantics.

```julia
for rep in get(s, kexpr"demo/**")
    if is_ok(rep)
        @show payload(sample(rep))
    else
        @show error_payload(rep)
    end
end
```

## API

### Publishers

```@docs
AbstractPublisher
Publisher
Zenoh.put
Zenoh.delete!
```

### Subscribers

```@docs
Subscriber
SubscriberHandler
KeepAllSubscriber
take!(::Zenoh.AbstractSubscriberHandler)
Zenoh.recv!
tryrecv!(::Zenoh.AbstractSubscriberHandler)
```

## Mapping to Zenoh, Rust, and C

| Zenoh.jl | Zenoh abstraction | Rust | zenoh-c |
| --- | --- | --- | --- |
| `Publisher(s, k; …)` / `close(p)` | [Publisher](https://zenoh.io/docs/manual/abstractions/#publisher) | [`Session::declare_publisher`](https://docs.rs/zenoh/1.9.0/zenoh/pubsub/struct.PublisherBuilder.html) | `z_declare_publisher` / `z_undeclare_publisher` |
| `put(p, payload; …)` | [put](https://zenoh.io/docs/manual/abstractions/) | [`Publisher::put`](https://docs.rs/zenoh/1.9.0/zenoh/pubsub/struct.Publisher.html) | `z_publisher_put` |
| `put(s, k, payload; …)` | [put](https://zenoh.io/docs/manual/abstractions/) | `Session::put` | `z_put` |
| `delete!(p)` / `delete!(s, k)` | [delete](https://zenoh.io/docs/manual/abstractions/) | `Publisher::delete` / `Session::delete` | `z_publisher_delete` / `z_delete` |
| `open(f, s, k)` → `Subscriber` | [Subscriber](https://zenoh.io/docs/manual/abstractions/#subscriber) | [`SubscriberBuilder`](https://docs.rs/zenoh/1.9.0/zenoh/pubsub/struct.SubscriberBuilder.html) + [`Callback`](https://docs.rs/zenoh/1.9.0/zenoh/handlers/index.html) handler | `z_declare_subscriber` + `z_closure_sample` |
| `open(s, k; channel=:fifo\|:ring)` → `SubscriberHandler` | Subscriber | [`handlers::RingChannel`](https://docs.rs/zenoh/1.9.0/zenoh/handlers/struct.RingChannel.html) | `z_declare_subscriber` (Julia-side ring) |
| `open(s, k; channel=:keep_all)` → `KeepAllSubscriber` | Subscriber | (no native handler) | (composed in Julia) |
| `Sample` / `SampleHolder` | [Sample](https://zenoh.io/docs/manual/abstractions/) | `Sample` | `z_loaned_sample_t` / `z_owned_sample_t` |
| `get(…)` → `GetHandler`; `Reply` | (query side) | [`Session::get`](https://docs.rs/zenoh/1.9.0/zenoh/struct.Session.html#method.get) + [`Reply`](https://docs.rs/zenoh/1.9.0/zenoh/query/struct.Reply.html) | `z_get` + `z_closure_reply` + `z_reply_*` |
| `allowed_origin` / `allowed_destination` | Locality | `Locality` | `z_subscriber_options_t` / `*_put_options_t` |

Zenoh.jl's keyword options fold down Rust's fluent builders: each keyword on [`Publisher`](@ref), `put`, `open`, or `get` sets a field the Rust builder methods would set. Declaring a publisher maps to `z_declare_publisher` (Rust `Session::declare_publisher`, returning a [`PublisherBuilder`](https://docs.rs/zenoh/1.9.0/zenoh/pubsub/struct.PublisherBuilder.html)); `close(p)` maps to `z_undeclare_publisher`, with a finalizer calling `z_publisher_drop` as a GC safety net. `put(p, payload)` maps to `z_publisher_put` and `put(s, k, payload)` to `z_put`; `delete!` publishes a delete-kind sample via `z_publisher_delete` or `z_delete`. The callback subscriber installs a `z_closure_sample` closure, corresponding to Rust's `Callback` handler; the buffered handler implements `RingChannel` (keep-last-N / drop-oldest) semantics. The query side (`get`, `Reply`, `GetHandler`) maps to Rust's `zenoh::query` module and `Session::get`, distinct from `zenoh::pubsub`. Locality filtering maps directly onto Rust's `Locality` on the respective options structs.

Several divergences from core Zenoh are deliberate and load-bearing:

!!! warning "`:fifo` is not Rust's FifoChannel"
    The buffered `:fifo`/`:ring`/default subscriber implements [`RingChannel`](https://docs.rs/zenoh/1.9.0/zenoh/handlers/struct.RingChannel.html) (drop-oldest keep-last-N), not Rust's [`FifoChannel`](https://docs.rs/zenoh/1.9.0/zenoh/handlers/struct.FifoChannel.html) (which blocks the producer for losslessness). The native C handlers (`z_fifo_channel_sample_new`, `z_ring_channel_sample_new`, and the reply variants) exist in the bindings but no buffered endpoint routes to them by default. All buffered delivery runs through a Julia-side ring filled on the I/O thread, chosen because the native FIFO handler exposes no push notification to drive a slot-free drain and to avoid exhausting the `@threadcall` restrictor. Lossless backpressure awaits a Rust-side notifying FIFO handler; until then, use `:keep_all`.

!!! warning "Callback delivery is latest-wins single-slot"
    `open(f, s, k)` uses a capacity-1 inline cell: a sample arriving while the previous is unconsumed overwrites it, so a slow callback sees only the latest message. This is a Zenoh.jl delivery policy — Rust's `Callback` handler invokes the callback for every sample. The callback `Subscriber` also carries no GC finalizer and **leaks until `close()` is called**: its FFI context and consume task form a reference cycle, and teardown must `wait` the task — work a finalizer cannot do. The buffered handlers on this page carry a finalizer, and Rust's drop auto-undeclares.

!!! note "KEEP_ALL has no native equivalent"
    `channel=:keep_all` is composed in Julia: a consume task drains the bounded ring into an unbounded `Channel{Sample}`. There is no single Rust or C handler that provides this. Under sustained overload it OOMs rather than deadlocks (ROS2 KEEP_ALL semantics).

Two further contracts to honor. Publisher QoS is declare-time-only: `put(p, …)` accepts only `timestamp`/`encoding`/`attachment` because `z_publisher_put_options_t` carries no QoS fields — `congestion_control`/`priority`/`express`/`reliability`/`allowed_destination` are fixed when the [`Publisher`](@ref) is declared, and only the session-level `put(s, k, …)` accepts them per call. And under iteration a yielded `Sample` is valid only until the next step (the loop reuses one owned box); use [`take!`](@ref take!), `:keep_all`, or [`recv!`](@ref)`(sub, holder)` to retain a sample. This zero-allocation box reuse is a Zenoh.jl contract with no Rust analogue, since Rust handlers yield owned samples.

The Zenoh.jl [ownership model](https://zenoh-c.readthedocs.io/en/1.9.0/concepts.html) mirrors zenoh-c: `_move` transfers an owned value to the callee (`put` moves the payload `ZBytes` and any owned encoding/attachment), `_loan` borrows, and `_drop` releases. The C symbols above are confirmed present in the generated [LibZenohC bindings](https://zenoh-c.readthedocs.io/en/1.9.0/api.html).

See also: [Samples](@ref), [Key Expressions](@ref), [Quality of Service](@ref), [Queries](@ref), [Advanced Pub/Sub](@ref), [Matching](@ref).
