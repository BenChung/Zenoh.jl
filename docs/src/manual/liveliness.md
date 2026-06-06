```@meta
CurrentModule = Zenoh
```

# Liveliness

Liveliness is Zenoh's dedicated presence API: a node declares a *liveliness token* on a key expression, and that token is seen as alive by any other node monitoring the key for as long as the declaring node keeps the token (and stays connected). Other nodes [subscribe](https://docs.rs/zenoh/1.9.0/zenoh/liveliness/struct.Liveliness.html) to be notified the moment a token appears or disappears, or [query](https://docs.rs/zenoh/1.9.0/zenoh/liveliness/index.html) the key for a one-shot snapshot of who is currently present. This is the purpose-built way to track availability — node membership, service discovery, leader presence.

A token carries presence: its identity is its key expression, and subscribers and queries learn which token changed by reading [`keyexpr`](@ref) off the sample. A token's appearance and withdrawal arrive as `PUT` and `DELETE` sample kinds; a liveliness sample has no payload. When the declaring node drops the token or exits, every watcher observes the `DELETE` — liveliness tracks the connection, so a crashed or partitioned node is reported gone automatically.

Zenoh.jl exposes three constructable entities — [`LivelinessToken`](@ref) to announce presence, [`LivelinessSubscriber`](@ref) to watch changes, and [`LivelinessSubscriberHandler`](@ref) for buffered watching — plus the verb [`liveliness_get`](@ref) for a snapshot. They reuse the data-plane callback and channel machinery, so their queue and delivery semantics match [Publish & Subscribe](@ref) and [Queries](@ref) exactly.

## Declaring a token

[`LivelinessToken`](@ref) declares presence on a key expression. The token signals "alive" to every matching liveliness subscriber for as long as it lives. Hold the returned handle; `close` it to withdraw explicitly.

```julia
using Zenoh
s = Zenoh.open(Zenoh.Config())

tok = LivelinessToken(s, Keyexpr("group/member/42"))

# ... node is alive while `tok` is held ...

close(tok)   # withdraw -> matching subscribers see a DELETE
```

`close(tok)` emits a `DELETE` to every watcher the instant it runs, giving deterministic withdrawal. Withdrawal is also automatic if a held token is never closed, but that fallback fires on garbage collection and so is not prompt — close explicitly when you want watchers to see the departure promptly. Presence is the token's whole surface: it takes no declare-time options.

## Watching for changes

[`LivelinessSubscriber`](@ref) reports tokens appearing and disappearing on a matching key expression. The callback form runs your function on a dedicated Julia task for each change:

```julia
sub = LivelinessSubscriber(s, Keyexpr("group/member/*"); history=true) do sample
    if kind(sample) === SampleKinds.PUT
        println("alive: ", keyexpr(sample))   # a token appeared
    elseif kind(sample) === SampleKinds.DELETE
        println("gone:  ", keyexpr(sample))   # a token withdrew
    end
end

# ... later ...
close(sub)
```

`PUT` means a token appeared; `DELETE` means a token withdrew. Read [`keyexpr`](@ref) on the sample to learn which token changed — the sample's identity is the token's key expression. The callback form is latest-wins single-slot; see [`Subscriber`](@ref) for the delivery semantics it inherits.

`history=true` replays the already-live tokens at subscribe time, so a late joiner sees the current membership set immediately rather than waiting for the next change. `history` is a subscriber-side option only — neither the token nor `liveliness_get` exposes it.

### Buffered watching

Omit the callback to get the buffered form, a [`LivelinessSubscriberHandler`](@ref) you drain by iteration, `take!`, or `tryrecv!`. This mirrors the data plane's callback-versus-channel split.

```julia
sub = LivelinessSubscriber(s, Keyexpr("group/member/*"); channel=:fifo, capacity=16)
for sample in sub
    println(kind(sample) === SampleKinds.PUT ? "alive: " : "gone:  ", keyexpr(sample))
end
```

`channel=:fifo` and `channel=:ring` both buffer in a drop-oldest ring and return a [`LivelinessSubscriberHandler`](@ref); `channel=:keep_all` buffers unboundedly, exactly as the data plane's `open(s, k; channel=:keep_all)` does. The queue semantics are inherited verbatim from [`SubscriberHandler`](@ref), including its zero-allocation caveat: a yielded `Sample` is valid only until the next iteration step, so call `take!` to retain one past the loop.

## Snapshotting who is present

[`liveliness_get`](@ref) is a one-shot query: it returns the tokens currently alive on a key expression, then completes. The buffered form returns a [`GetHandler`](@ref) you iterate for replies; each reply's sample carries a live token's key expression.

```julia
for reply in liveliness_get(s, Keyexpr("group/member/*"); timeout_ms=1000)
    println("present: ", keyexpr(sample(reply)))
end
```

A liveliness get is a query whose replies are token announcements, so it reuses the same [`Reply`](@ref) and [`GetHandler`](@ref) machinery as a data-plane [`get`](@ref).

To abort a snapshot early, pass a [`CancellationToken`](@ref) and `cancel` it (for example from a deadline timer). Your handle stays valid after you pass it, so you can still cancel from it:

```julia
ct = CancellationToken()
h = liveliness_get(s, Keyexpr("group/member/*"); timeout_ms=5000, cancellation=ct)
Timer(_ -> cancel(ct), 0.5)   # give up after 500 ms
for reply in h
    println("present: ", keyexpr(sample(reply)))
end
```

The callback form invokes `f` per reply on a dedicated task with latest-wins single-slot semantics and blocks until every reply has arrived — every peer responded or the timeout elapsed:

```julia
liveliness_get(s, Keyexpr("group/member/*"); timeout_ms=1000) do reply
    println("present: ", keyexpr(sample(reply)))
end
```

`:fifo` and `:ring` both deliver through the same drop-oldest ring on `liveliness_get`, so the `channel` keyword is interchangeable here; it is accepted for source compatibility with the data-plane `get`.

## Liveliness and Advanced Pub/Sub

An [`AdvancedPublisher`](@ref) can auto-declare a liveliness token to assert its own presence, letting [`AdvancedSubscriber`](@ref)s detect publishers joining and leaving. See [Advanced Pub/Sub](@ref) for how that presence signal drives history and recovery.

## API

```@docs
LivelinessToken
LivelinessSubscriber
LivelinessSubscriberHandler
liveliness_get
```

## Mapping to Zenoh, Rust, and C

| Zenoh.jl | Zenoh abstraction | Rust | zenoh-c |
| --- | --- | --- | --- |
| [`LivelinessToken`](@ref)`(s, k)` | [Liveliness token](https://docs.rs/zenoh/1.9.0/zenoh/liveliness/struct.LivelinessToken.html) | [`Liveliness::declare_token`](https://docs.rs/zenoh/1.9.0/zenoh/liveliness/struct.Liveliness.html) → [`LivelinessToken`](https://docs.rs/zenoh/1.9.0/zenoh/liveliness/struct.LivelinessToken.html) | [`z_liveliness_declare_token`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| `close(t::LivelinessToken)` | undeclare token | [`LivelinessToken::undeclare`](https://docs.rs/zenoh/1.9.0/zenoh/liveliness/struct.LivelinessToken.html) | [`z_liveliness_undeclare_token`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| `LivelinessToken` finalizer | drop token | `Drop for LivelinessToken` | [`z_liveliness_token_drop`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [`LivelinessSubscriber`](@ref)`(f, s, k; history)` | [liveliness subscriber](https://docs.rs/zenoh/1.9.0/zenoh/liveliness/struct.Liveliness.html) | [`Liveliness::declare_subscriber`](https://docs.rs/zenoh/1.9.0/zenoh/liveliness/struct.Liveliness.html) (closure handler) | [`z_liveliness_declare_subscriber`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [`LivelinessSubscriberHandler`](@ref) / `LivelinessSubscriber(s, k; channel)` | liveliness subscriber (channel handler) | `Liveliness::declare_subscriber` (FifoChannelHandler / RingChannelHandler) | `z_liveliness_declare_subscriber` |
| [`liveliness_get`](@ref) | [`Liveliness::get`](https://docs.rs/zenoh/1.9.0/zenoh/liveliness/struct.Liveliness.html) (replies are [Liveliness Token messages](https://zenoh.io/docs/manual/access-control/)) | [`Liveliness::get`](https://docs.rs/zenoh/1.9.0/zenoh/liveliness/struct.Liveliness.html) | [`z_liveliness_get`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| `history` keyword | `history` option | [`LivelinessSubscriberBuilder::history`](https://docs.rs/zenoh/1.9.0/zenoh/liveliness/struct.LivelinessSubscriberBuilder.html) | `z_liveliness_subscriber_options_t.history` |
| `cancellation` keyword | cancellation token | [`LivelinessGetBuilder::cancellation_token`](https://docs.rs/zenoh/1.9.0/zenoh/liveliness/struct.LivelinessGetBuilder.html) (unstable in 1.9.0) | `z_liveliness_get_options_t.cancellation_token` |

The mapping is direct: [`LivelinessToken`](@ref)`(s, k)` is the Rust `session.liveliness().declare_token(k).await`, calling `z_liveliness_declare_token` with a defaulted (empty) options struct. `close(t)` is the explicit Rust `undeclare()` (`z_liveliness_undeclare_token`), moving the token out so the GC finalizer's `z_liveliness_token_drop` is a no-op on the emptied slot; the finalizer alone mirrors Rust's automatic undeclare-on-drop. The callback [`LivelinessSubscriber`](@ref) is the Rust subscriber with a closure handler, the buffered form is the Rust subscriber with a channel handler, and both issue the same `z_liveliness_declare_subscriber` call. The `PUT`/`DELETE` semantics are Rust's `SampleKind::Put`/`SampleKind::Delete`. [`liveliness_get`](@ref) is `session.liveliness().get(k)`; because `z_liveliness_get` consumes a reply closure, it reuses the existing [`GetHandler`](@ref)/[`Reply`](@ref) machinery rather than introducing a liveliness-specific result type.

The divergences from upstream Rust are deliberate:

- **Constructors and keywords replace builders.** Zenoh.jl exposes plain constructors and keyword args (`history`, `channel`, `capacity`, `timeout_ms`, `cancellation`) where Rust has `LivelinessTokenBuilder`, `LivelinessSubscriberBuilder`, and `LivelinessGetBuilder`.
- **Session passed directly.** Zenoh.jl folds away Rust's `Session::liveliness() -> Liveliness` intermediary and passes the [`Session`](@ref) straight to each constructor and to `liveliness_get`.
- **One Rust subscriber, two Julia types.** Rust models callback versus channel purely by a handler type parameter on a single `Subscriber`. Zenoh.jl splits this into [`LivelinessSubscriber`](@ref) (callback, latest-wins single slot) and [`LivelinessSubscriberHandler`](@ref) (buffered), selected by the presence or absence of the callback `f`.
- **`liveliness_get`'s `channel` keyword does not affect delivery.** `:fifo` and `:ring` both map to the same drop-oldest ring; the keyword is accepted only for source compatibility with the data-plane `get` (whose own subscriber uses `:keep_all` to select a distinct heap-backed path).
- **Token is option-free.** `z_liveliness_token_options_t` is empty (a `_dummy` byte in the binding), so [`LivelinessToken`](@ref) exposes no declare-time options at all.

The `cancellation` keyword maps to Rust's [`LivelinessGetBuilder::cancellation_token`](https://docs.rs/zenoh/1.9.0/zenoh/liveliness/struct.LivelinessGetBuilder.html) (an unstable API in 1.9.0) and to `z_liveliness_get_options_t.cancellation_token`. Passing `cancellation=tok` clones the token and moves the clone into that field, so `cancel(tok)` aborts the in-flight query while your handle stays valid. See [`CancellationToken`](@ref).

!!! warning "Not wrapped"
    The C entrypoint `z_liveliness_declare_background_subscriber` exists in the bindings but has no Julia equivalent: every liveliness subscriber here is an owned handle with explicit `close` and a finalizer fallback.

The liveliness types subtype the data-plane `AbstractCallbackSubscriber` / `AbstractSubscriberHandler` and share their callback and channel machinery. They sit outside the [`AbstractPublisher`](@ref) hierarchy, and [`LivelinessToken`](@ref) is a standalone owned-handle type.