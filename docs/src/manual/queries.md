```@meta
CurrentModule = Zenoh
```

# Queries

A query is Zenoh's request/reply primitive: a client issues a `get` against a
[selector](https://zenoh.io/docs/manual/abstractions/#selector) (a key
expression plus optional parameters), the network routes it to every matching
[queryable](https://zenoh.io/docs/manual/abstractions/#queryable) — "a
computation registered at a specific key expression [that] can be triggered by a
`get` operation" — and each queryable answers with zero or more replies. Zenoh.jl
exposes both halves: [`Queryable`](@ref) declares the server-side computation,
and `get` (a `Base.get` method) issues the client-side request and surfaces the
[`Reply`](@ref) stream.

Both halves come in two delivery forms, and the choice is the core of this page.
The **callback form** runs your function per query/reply on a dedicated task
through a single-slot, latest-wins handoff; the **channel form** buffers items in
a capacity-bounded ring you drain with iteration or [`tryrecv!`](@ref). For
queryables the distinction is load-bearing: a query overwritten in the
single-slot handoff is revoked, so its originating `get` times out. Real query
workloads belong on the channel form.

## The selector: key expression plus parameters

Zenoh's selector is a key expression and, after a `?`, a `;`-separated string of
URL-encoded parameters (`path/**/x?arg1=val1;arg2=value%202`). Zenoh.jl keeps the
two parts separate: `get` takes a [`Keyexpr`](@ref) and a plain `String` of
parameters, and a served [`Query`](@ref) exposes them through [`keyexpr`](@ref)
and [`parameters`](@ref). Parameters are passed and read as raw strings —
application code interprets them.

```julia
using Zenoh

session = open(Config())
ke = Keyexpr("demo/example/zget")
```

## Serving queries: the Queryable

A [`Queryable`](@ref) declared on a key expression receives every matching query.
Answer each one with [`reply`](@ref) (a successful Put-kind sample),
[`reply_del`](@ref) (a Delete-kind notification), or [`reply_err`](@ref) (an error
payload). A queryable may emit any number of replies per query, including none.

### Channel form (recommended for real workloads)

`Queryable(s, k; channel=:fifo)` returns a buffered queryable — also typed
[`QueryableHandler`](@ref) — that you iterate to receive each [`Query`](@ref).
Reply inline and the loop continues; iteration ends after [`close`](@ref) once
buffered queries drain.

```julia
qable = Queryable(session, ke; channel=:fifo, capacity=16, complete=true)

server = Threads.@spawn for q in qable
    @info "query" key=keyexpr(q) params=parameters(q)
    reply(q, "the answer"; encoding="text/plain")
end
```

Iteration finalizes the **previous** `Query` at the start of each step, which is
what releases the originating `get` from its wait. So the contract is: reply while
you hold the query and never accumulate queries across iterations. `collect`ing a
`Queryable` yields queries that are already finalized.

For deferred handling, pull with `take!` (blocking) or [`tryrecv!`](@ref)
(non-blocking, returns `nothing` when the buffer is empty). These hand the
`Query` out without a follow-on finalize, so its lifetime is yours: `finalize`
the query after replying, or the originating `get` blocks for its full timeout
window.

```julia
q = take!(qable)
try
    reply(q, "deferred answer")
finally
    finalize(q.q)   # release the query now; otherwise the get waits out its timeout
end
```

### Callback form

`Queryable(f, s, k)` invokes `f(::Query)` per query on a dedicated task and drops
the `Query` as soon as `f` returns. The handoff is single-slot latest-wins:
queries arriving while the slot is occupied overwrite the previous one, and an
overwritten query is revoked — its client sees a timeout. The form fits
low-rate, reactive servers; for sustained query traffic the channel form is the
right choice.

```julia
qable = Queryable(session, ke) do q
    reply(q, "callback answer")
end
```

`f` must finish replying before it returns; the `Query` handle is gone
afterward. Deferring reply work past the callback sees the query revoked.

### Lifetime and options

Both forms undeclare on [`close`](@ref), which is idempotent. The channel form
also carries a GC finalizer safety net; the callback form relies on explicit
`close` (its consume task and context form a reference cycle that a finalizer
cannot tear down safely). Two declare-time options apply to either form:

- `complete` — mark the queryable as holding the full data for its key
  expression, which `QueryTargets.ALL_COMPLETE` queries select for.
- `allowed_origin` — a `Localities` singleton (`ANY`, `SESSION_LOCAL`,
  `REMOTE`) restricting which sessions' queries it answers.

### Replying on a wildcard key expression

[`reply`](@ref) and [`reply_del`](@ref) default to borrowing the query's own
key expression, which is the right choice when the queryable serves a concrete
key. A query's key expression may itself be a glob; when you serve a wildcard
queryable, pass an explicit per-key `Keyexpr` so each reply carries the concrete
key it answers for.

```julia
qable = Queryable(session, Keyexpr("demo/sensors/**"); channel=:fifo)
for q in qable
    reply(q, "23.5"; encoding="text/plain")              # default: query's keyexpr (may be a glob)
    reply(q, "23.5", Keyexpr("demo/sensors/temp"))       # explicit: the concrete key answered
end
```

## Issuing queries: get

`get` issues a query and delivers the [`Reply`](@ref) stream. It is not exported
by Zenoh; it extends `Base.get`, so a bare `get(...)` already resolves to it
after `using Zenoh` (every example below relies on that). Qualify as `Zenoh.get`
only if another imported package's `get` would shadow it.

### Channel form

`get(s, k, params="")` returns a [`GetHandler`](@ref) you iterate, `take!`, or
`tryrecv!`. The handler self-terminates when every peer has replied or the
timeout elapses — no explicit close is needed.

```julia
gh = get(session, ke, "arg=1";
         target = QueryTargets.ALL,
         consolidation = QueryConsolidations.NONE,
         timeout_ms = 1000)

for r in gh
    if is_ok(r)
        smp = sample(r)
        println(keyexpr(smp), " => ", String(payload(smp)))
    else
        println("ERR: ", String(error_payload(r)))
    end
end
```

A [`Reply`](@ref) is ok-or-error: [`is_ok`](@ref) discriminates, [`sample`](@ref)
yields the success [`Sample`](@ref), and [`error_payload`](@ref) /
[`error_encoding`](@ref) read the error branch (each throws if called on the
wrong branch).

### Callback form

`get(f, s, k, params="")` invokes `f(::Reply)` per reply and blocks until
delivery completes (all peers replied or the timeout elapsed).
Delivery is the single-slot latest-wins handoff, so a slow consumer sees only the
latest reply. Pass `should_close_on_error=false` to keep consuming after `f`
throws.

```julia
get(session, ke, "arg=1"; timeout_ms=1000) do r
    is_ok(r) && println(String(payload(sample(r))))
end
```

### Query routing and consolidation

`get` folds Zenoh's query options into keyword arguments:

- `target` — which matching queryables receive the query:
  `QueryTargets.BEST_MATCHING` / `ALL` / `ALL_COMPLETE` (or the
  `:best_matching` / `:all` / `:all_complete` symbol shorthand).
- `consolidation` — the reply de-duplication strategy:
  `QueryConsolidations.AUTO` / `NONE` / `MONOTONIC` / `LATEST` (or `:auto` /
  `:none` / `:monotonic` / `:latest`).
- `accept_replies` — which reply key expressions are accepted:
  `ReplyKeyexprs.ANY` or `MATCHING_QUERY` (the default).
- `timeout_ms` — request timeout in milliseconds; `0` means no timeout.
- `payload`, `encoding`, `attachment` — request data sent to the queryable
  (read there with [`payload`](@ref), [`encoding`](@ref), [`attachment`](@ref)).
- `congestion_control`, `priority`, `express`, `allowed_destination` — the
  shared QoS controls (see [Quality of Service](@ref)).
- `cancellation` — a [`CancellationToken`](@ref); see below.

## Cancelling an in-flight get

A [`CancellationToken`](@ref) bounds a running `get` independently of its
timeout. Hand it to a `get` and call [`cancel`](@ref) to abort: the get's reply
stream ends promptly. The token you hold stays valid to cancel through after the
`get` starts, and clones of a token share one cancellation flag.

```julia
tok = CancellationToken()
gh = get(session, ke; cancellation=tok)
Threads.@spawn (sleep(0.5); cancel(tok))   # abort from a deadline timer
foreach(_ -> nothing, gh)                   # stream ends when the get is cancelled
@show is_cancelled(tok)
```

For a [Querier](#Reusable-queries:-the-Querier) `get`, the `cancellation` token
is the only per-call bound, since querier get options carry no timeout. It is the
abort path, separate from `timeout_ms`, and it is safe to `cancel` after the
operation already finished.

## Reusable queries: the Querier

A [`Querier`](@ref) is a long-lived query handle declared once for a key
expression with baked-in `target`, `consolidation`, QoS, and `timeout_ms`. Each
`get(querier, params)` reuses those defaults, returning a [`GetHandler`](@ref)
(channel form) or running a callback (callback form) just as a Session `get`
does. Declaring once resolves the key expression and query settings a single
time and reuses them across every `get`, so a stream of queries to the same key
amortizes that setup.

```julia
q = Querier(session, ke;
            target = QueryTargets.ALL,
            consolidation = QueryConsolidations.LATEST,
            timeout_ms = 5_000)

@show querier_id(q)                 # (; zid, eid) — the querier's global entity id

for r in get(q, "arg=1")            # channel form, reusing the baked-in defaults
    is_ok(r) && println(String(payload(sample(r))))
end

get(q, "arg=2"; payload="hello", encoding="text/plain") do r   # callback form
    @show r
end

close(q)                            # undeclare; idempotent
```

`timeout_ms` is declare-time only on a querier; express a per-call deadline by
wiring a timer to `cancel(tok)` on a `cancellation` token. The querier's declared
key expression is fixed; the positional `parameters` string is the only per-call
selector part. See the [Querier reference](#Querier) below for `querier_id` and
the full keyword set.

## API

### Queryable side

```@docs
Queryable
QueryableHandler
Query
reply
reply_err
reply_del
parameters
accepts_replies
```

### Get side

```@docs
get(::Function, ::Zenoh.Session, ::Zenoh.Keyexpr, ::AbstractString)
get(::Zenoh.Session, ::Zenoh.Keyexpr, ::AbstractString)
GetHandler
Reply
is_ok
sample
error_payload
error_encoding
```

### Cancellation

```@docs
CancellationToken
cancel
is_cancelled
```

### Querier

```@docs
Querier
querier_id
get(::Zenoh.Querier, ::AbstractString)
get(::Function, ::Zenoh.Querier, ::AbstractString)
```

### Reusable, allocation-free gets

A [`ReusableGet`](@ref) wraps a [`Querier`](@ref) for the request/reply hot path: it allocates its
whole apparatus once, and each [`call!`](@ref) re-arms it in place and blocks until the first reply,
so a steady-state call allocates nothing on the Zenoh.jl side. The reply lands in a pooled
[`ReplyHolder`](@ref) — read it, and copy out anything you need, before the next `call!` reuses the
slot. A `ReusableGet` is single-in-flight: a concurrent `call!` throws [`ConcurrentUseError`](@ref),
so use one per task or a small pool.

```@docs
ReusableGet
call!
ReplyHolder
ConcurrentUseError
```

## Mapping to Zenoh, Rust, and C

| Zenoh.jl | Zenoh abstraction | Rust | zenoh-c |
| --- | --- | --- | --- |
| [`Queryable`](@ref) (+ both constructors) | [Queryable](https://zenoh.io/docs/manual/abstractions/#queryable) | [`zenoh::query::Queryable`](https://docs.rs/zenoh/1.9.0/zenoh/query/struct.Queryable.html) / `Session::declare_queryable` | `z_declare_queryable` / `z_owned_queryable_t` |
| [`Query`](@ref) + accessors | [Query](https://docs.rs/zenoh/1.9.0/zenoh/query/struct.Query.html) | [`zenoh::query::Query`](https://docs.rs/zenoh/1.9.0/zenoh/query/struct.Query.html) | `z_query_keyexpr` / `z_query_parameters` / `z_query_payload` / `z_query_encoding` / `z_query_attachment` / `z_query_accepts_replies` |
| [`reply`](@ref) / [`reply_del`](@ref) / [`reply_err`](@ref) | reply to a Query | `Query::reply` / `reply_del` / `reply_err` | `z_query_reply` / `z_query_reply_del` / `z_query_reply_err` |
| `get(s, k, params; ...)` / `get(f, s, k, params)` | get / query | [`Session::get`](https://docs.rs/zenoh/1.9.0/zenoh/struct.Session.html#method.get) (SessionGetBuilder) | `z_get` |
| [`GetHandler`](@ref) | reply handler | get handler (`recv_async`) | reply closure + ring |
| [`Reply`](@ref) + [`is_ok`](@ref)/[`sample`](@ref)/[`error_payload`](@ref)/[`error_encoding`](@ref) | [Reply](https://docs.rs/zenoh/1.9.0/zenoh/query/struct.Reply.html) / [ReplyError](https://docs.rs/zenoh/1.9.0/zenoh/query/struct.ReplyError.html) | [`zenoh::query::Reply`](https://docs.rs/zenoh/1.9.0/zenoh/query/struct.Reply.html) | `z_reply_is_ok` / `z_reply_ok` / `z_reply_err` |
| `QueryTargets.{BEST_MATCHING,ALL,ALL_COMPLETE}` | query target | [`QueryTarget`](https://docs.rs/zenoh/1.9.0/zenoh/query/enum.QueryTarget.html) | `Z_QUERY_TARGET_*` |
| `QueryConsolidations.{AUTO,NONE,MONOTONIC,LATEST}` | reply consolidation | [`ConsolidationMode`](https://docs.rs/zenoh/1.9.0/zenoh/query/enum.ConsolidationMode.html) | `z_query_consolidation_auto/none/monotonic/latest` |
| `ReplyKeyexprs.{ANY,MATCHING_QUERY}` | reply key expression | `ReplyKeyExpr` | `Z_REPLY_KEYEXPR_*` |
| [`CancellationToken`](@ref) / [`cancel`](@ref) / [`is_cancelled`](@ref) | [CancellationToken](https://docs.rs/zenoh/1.9.0/zenoh/cancellation/index.html) | [`zenoh::cancellation::CancellationToken`](https://docs.rs/zenoh/1.9.0/zenoh/cancellation/struct.CancellationToken.html) | `z_cancellation_token_new/clone/cancel/is_cancelled/drop` |
| [`Querier`](@ref) / [`querier_id`](@ref) | querier | [`zenoh::query::Querier`](https://docs.rs/zenoh/1.9.0/zenoh/query/struct.Querier.html) / `Session::declare_querier` | `z_declare_querier` / `z_querier_get_with_parameters_substr` / `z_querier_id` |

The [`Query`](@ref) accessors, the three reply functions, the [`Reply`](@ref)
discriminants, and the `QueryTarget` / `QueryConsolidation` / `ReplyKeyExpr`
selectors are 1:1 with their Rust methods and `z_*` C calls. `complete` and
`allowed_origin` map to `z_queryable_options_t.complete` /
`.allowed_origin`; `Localities.{ANY,SESSION_LOCAL,REMOTE}` map 1:1 to
`Z_LOCALITY_*`. The two `get` forms and both `Querier` `get` forms wrap `z_get`
/ `z_querier_get_with_parameters_substr`; the Querier uses the `_substr`
entrypoint (pointer + length) so a `SubString` of parameters threads through
without a copy.

Several Zenoh constructs are deliberately reshaped or absent in Zenoh.jl:

!!! note "Builders are folded into keyword arguments"
    Rust's `SessionGetBuilder`, `QueryableBuilder`,
    `QuerierBuilder`/`QuerierGetBuilder`, and the `ReplyBuilder*` family are all
    collapsed into keyword arguments on `get` / `Queryable` / `Querier` /
    `reply` / `reply_err` / `reply_del`. There is no chained-builder API.

!!! note "No Selector, Parameters, or ReplyError type"
    Rust's `Selector` (key expression + `Parameters`) is split into a separate
    [`Keyexpr`](@ref) argument and a raw parameters `String`. Rust's `ReplyError`
    struct is folded into [`Reply`](@ref), surfaced only through
    [`error_payload`](@ref) / [`error_encoding`](@ref) guarded by
    [`is_ok`](@ref).

!!! warning "Single-slot callback delivery has no Rust analog"
    The callback `get` and callback `Queryable` use a single-slot, latest-wins
    handoff: an item arriving while the slot is occupied overwrites the previous
    one. For queryables an overwritten query is revoked, so its client sees a
    timeout. This is a Zenoh.jl delivery choice; prefer the channel form for real
    query workloads.

!!! warning "Query lifetime is an explicit contract in the channel form"
    Dropping an owned [`Query`](@ref) (`z_query_drop`) is what sends the
    final-ack the originating `get` awaits. Iteration finalizes the previous
    query at each step, so reply inline and never stash queries across
    iterations; `take!` / [`tryrecv!`](@ref) hand out the query without
    that follow-up, so you must call `finalize(q.q)` after replying. Rust handles
    this through `Drop` scope.

!!! warning "Cancellation is unstable upstream"
    [`CancellationToken`](@ref) wraps zenoh's unstable
    [cancellation](https://docs.rs/zenoh/1.9.0/zenoh/cancellation/index.html) API
    (it requires the Rust `unstable` crate feature). It is the abort path,
    distinct from `timeout_ms`. `z_get` consumes (moves) the token it is given, so
    `get` passes it a `z_cancellation_token_clone` and keeps the caller's handle
    valid; clones share one flag (`z_cancellation_token_cancel` /
    `z_cancellation_token_is_cancelled`).

!!! note "channel=:fifo and :ring deliver identically"
    For `get`, `Queryable`, and `Querier` replies, `channel=:fifo` and
    `channel=:ring` both route through the same capacity-bounded callback ring
    (drop-oldest on overflow, ROS `KEEP_LAST`). The symbol exists for API
    symmetry; lossless backpressure would require a Rust-side notifying FIFO
    handler.

!!! note "Background queryables are not yet wrapped"
    `z_declare_background_queryable` exists in the C bindings but has no Zenoh.jl
    wrapper (there is a source `TODO(background-queryable)`). Fire-and-forget,
    session-lifetime queryables are unavailable today. The Querier likewise omits
    the matching-status / matching-listener API and `accept_replies`.

See also [Quality of Service](@ref), [Key Expressions](@ref), and
[Samples](@ref).