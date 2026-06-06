```@meta
CurrentModule = Zenoh
```

# Quality of Service

Quality of Service (QoS) settings tune how Zenoh's transport moves a message: which transmission queue it rides ([`Priority`](@ref)), what happens when that queue fills ([`CongestionControl`](@ref)), whether the network layer retransmits losses ([`Reliability`](@ref)), and which peers it reaches ([`Locality`](@ref)). Zenoh.jl also folds the query-shaping options ([`QueryTarget`](@ref), [`QueryConsolidation`](@ref), [`ReplyKeyexpr`](@ref)) and two read-side singleton families ([`SampleKind`](@ref), [`WhatAmI`](@ref)) into the same module.

That shared design is the page's organizing idea: every one of these is a **strongly-typed singleton sum type**. Zenoh.jl gives each level its own zero-field type under an abstract supertype and exposes one instance constant per level (`Priorities.REAL_TIME`, `CongestionControls.BLOCK`, …), where Rust and C expose a single bounded enum. The constants are the user-facing API. Three properties follow directly:

- Method signatures dispatch on the abstract type (`priority::Union{Nothing, Priority}`), so a bogus value raises a method error at the call site.
- Identity comparison is free: `priority(sample) === Priorities.REAL_TIME` is a pointer compare, no field unpack.
- Downstream code can add a method per level (`handle(::Priorities.RealTime, msg) = …`).

Each setting matches the Zenoh data-plane abstraction one-to-one; the [Mapping section](#Mapping-to-Zenoh,-Rust,-and-C) states the correspondences precisely and names every divergence.

## Sender-side QoS: priority, congestion control, reliability, locality

These travel with each outgoing message. Set them when you create a [`Publisher`](@ref), inline on a session `put`, or on a `get` request.

[`Priority`](@ref) selects the transmission queue. With QoS enabled in the [`Config`](@ref) (`transport.<type>.qos`), Zenoh keeps one queue per priority and services them highest-first. The seven levels run from `Priorities.REAL_TIME` (highest) to `Priorities.BACKGROUND` (lowest), with `Priorities.DATA` as the default.

[`CongestionControl`](@ref) decides what happens when the target queue is full. `CongestionControls.DROP` (the default) discards the message; `CongestionControls.BLOCK` makes the sender wait for the queue to drain.

[`Reliability`](@ref) chooses whether the network layer retransmits lost messages. `Reliabilities.RELIABLE` (the default) guarantees delivery; `Reliabilities.BEST_EFFORT` delivers once and drops losses. You fix this on the sender: a publisher sets its reliability at declare time, and a session `put` sets it per call.

[`Locality`](@ref) scopes the destination set. `Localities.ANY` (the default) reaches both session-local and remote subscribers; `Localities.SESSION_LOCAL` stays within the same session; `Localities.REMOTE` reaches only remote peers. It surfaces as `allowed_destination=` on publishers, `put`, and `get`, and as `allowed_origin=` on subscribers.

```julia
using Zenoh

session = open(Config())

# A publisher bakes its QoS in at declare time.
pub = Publisher(session, Keyexpr("demo/qos");
    priority            = Priorities.REAL_TIME,
    congestion_control  = CongestionControls.BLOCK,
    reliability         = Reliabilities.RELIABLE,
    express             = true,
    allowed_destination = Localities.ANY)

put(pub, "hello")   # uses the publisher's fixed reliability; no per-put override

# A session put can set the same QoS inline, including reliability.
put(session, Keyexpr("demo/qos"), "once";
    priority            = Priorities.DATA_HIGH,
    congestion_control  = CongestionControls.DROP,
    reliability         = Reliabilities.BEST_EFFORT)
```

!!! warning "A publisher's reliability cannot be overridden per `put`"
    A [`Publisher`](@ref) fixes `Reliability` at declare time; a per-`put` call on that publisher carries no reliability of its own. To vary reliability per message, publish through a session `put`, which accepts `reliability=`.

The `express=true` keyword above is a `Bool` flag: it bypasses transport batching to cut latency.

## Query-shaping QoS: target, consolidation, reply key expressions

These shape a `get` on the requester side. `target=` and `consolidation=` also apply to a long-lived [`Querier`](@ref); `accept_replies=` is a session-`get` keyword with no `Querier` equivalent.

[`QueryTarget`](@ref) selects which matching queryables the query reaches: `QueryTargets.BEST_MATCHING` (the default, chosen by the routing strategy), `QueryTargets.ALL` (every match), or `QueryTargets.ALL_COMPLETE` (every queryable declared complete).

[`QueryConsolidation`](@ref) sets the reply de-duplication strategy: `QueryConsolidations.AUTO` (the default, deferring to the queryable's preference), `NONE` (forward everything, duplicates allowed), `MONOTONIC` (forward immediately unless a same-or-newer timestamp already went out for the key), or `LATEST` (hold back to send only the highest-timestamp set per key).

[`ReplyKeyexpr`](@ref) constrains reply keys via `accept_replies=` on a session `get`: `ReplyKeyexprs.MATCHING_QUERY` (the default) requires replies to match the query key expression; `ReplyKeyexprs.ANY` admits any key.

```julia
for reply in get(session, Keyexpr("demo/**");
        target         = QueryTargets.ALL,            # or the :all shorthand
        consolidation  = QueryConsolidations.LATEST,  # or the :latest shorthand
        accept_replies = ReplyKeyexprs.MATCHING_QUERY)
    if is_ok(reply)
        smp = sample(reply)
        @show priority(smp) congestion_control(smp) reliability(smp) kind(smp)
    end
end
```

`target=` and `consolidation=` accept either the typed singleton or a `Symbol` shorthand (`:best_matching`/`:all`/`:all_complete` and `:auto`/`:none`/`:monotonic`/`:latest`), on both `get` and a [`Querier`](@ref).

!!! note "Symbol shorthands are limited to `target` and `consolidation`"
    The `:all`/`:latest`-style shorthands exist only for `target=` and `consolidation=`. `priority`, `congestion_control`, `reliability`, `allowed_destination`, and `accept_replies` are typed `Union{Nothing, ...}` against their abstract supertypes, so passing a `Symbol` there is a method error. Use the typed singleton (`Priorities.REAL_TIME`, `ReplyKeyexprs.ANY`, …).

## Read-side metadata: sample kind and discovery roles

[`SampleKind`](@ref) reports whether an inbound [`Sample`](@ref) carries a value or signals a key deletion: `SampleKinds.PUT` (issued by a `put`) or `SampleKinds.DELETE` (issued by a `delete`). Read it with `kind(::Sample)`.

The sender-side QoS that round-trips through the transport is readable off an inbound sample with matching accessors, each returning the typed singleton:

```julia
priority(smp)            === Priorities.REAL_TIME
congestion_control(smp)  === CongestionControls.DROP
reliability(smp)         === Reliabilities.RELIABLE
kind(smp)                === SampleKinds.PUT
```

[`WhatAmI`](@ref) names the role a node announces during scouting: `WhatAmIs.ROUTER`, `WhatAmIs.PEER`, or `WhatAmIs.CLIENT`. It names a node's scouting role. You read it off a `Hello` returned by [`scout`](@ref) and render it with [`whatami_string`](@ref); the `scout(...; what=...)` filter takes `Symbol`s (`:router`, `:peer`, `:client`). See the discovery documentation for scouting in full.

## Setting QoS in static configuration

A static [`Config`](@ref) can fix reliability for a whole deployment: a `Reliabilities` singleton drops into a publication-rule / QoS-overwrite config section. It is the one QoS here with a config-builder bridge; congestion control, priority, and express reach config as their own keyword fields.

## Public API

```@docs
Priority
Priorities
CongestionControl
CongestionControls
Reliability
Reliabilities
Locality
Localities
ReplyKeyexpr
ReplyKeyexprs
QueryTarget
QueryTargets
QueryConsolidation
QueryConsolidations
SampleKind
SampleKinds
WhatAmI
WhatAmIs
```

## Mapping to Zenoh, Rust, and C

| Zenoh.jl | Zenoh abstraction | Rust | zenoh-c |
| --- | --- | --- | --- |
| [`Priority`](@ref) / `Priorities.*` | [Priority](https://docs.rs/zenoh/1.9.0/zenoh/qos/enum.Priority.html) | [`zenoh::qos::Priority`](https://docs.rs/zenoh/1.9.0/zenoh/qos/enum.Priority.html) | `z_priority_t` |
| [`CongestionControl`](@ref) / `CongestionControls.*` | [CongestionControl](https://docs.rs/zenoh/1.9.0/zenoh/qos/enum.CongestionControl.html) | [`zenoh::qos::CongestionControl`](https://docs.rs/zenoh/1.9.0/zenoh/qos/enum.CongestionControl.html) | `z_congestion_control_t` |
| [`Reliability`](@ref) / `Reliabilities.*` | [Reliability](https://docs.rs/zenoh/1.9.0/zenoh/qos/enum.Reliability.html) | [`zenoh::qos::Reliability`](https://docs.rs/zenoh/1.9.0/zenoh/qos/enum.Reliability.html) | `z_reliability_t` |
| [`Locality`](@ref) / `Localities.*` | Locality | [`zenoh::sample::Locality`](https://docs.rs/zenoh/1.9.0/zenoh/sample/enum.Locality.html) | `z_locality_t` |
| [`QueryTarget`](@ref) / `QueryTargets.*` | QueryTarget | [`zenoh::query::QueryTarget`](https://docs.rs/zenoh/1.9.0/zenoh/query/enum.QueryTarget.html) | `z_query_target_t` |
| [`QueryConsolidation`](@ref) / `QueryConsolidations.*` | [ConsolidationMode](https://docs.rs/zenoh/1.9.0/zenoh/query/enum.ConsolidationMode.html) | [`zenoh::query::ConsolidationMode`](https://docs.rs/zenoh/1.9.0/zenoh/query/enum.ConsolidationMode.html) | `z_query_consolidation_t` |
| [`ReplyKeyexpr`](@ref) / `ReplyKeyexprs.*` | reply key expression | [`zenoh::query::ReplyKeyExpr`](https://docs.rs/zenoh/1.9.0/zenoh/query/enum.ReplyKeyExpr.html) | `z_reply_keyexpr_t` |
| [`SampleKind`](@ref) / `SampleKinds.*` | Sample kind | [`zenoh::sample::SampleKind`](https://docs.rs/zenoh/1.9.0/zenoh/sample/enum.SampleKind.html) | `z_sample_kind_t` |
| [`WhatAmI`](@ref) / `WhatAmIs.*` | WhatAmI | [`zenoh::config::WhatAmI`](https://docs.rs/zenoh/1.9.0/zenoh/config/enum.WhatAmI.html) | `z_whatami_t` |

The zenoh-c column names each C type without a hyperlink: the [zenoh-c API reference](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) is a single concatenated page, so a bare link would land every row at the same top-of-page spot. The Rust column links to the canonical per-type docs.rs page, which resolves to the exact abstraction.

Each Julia singleton maps one-to-one to its C enumerator through an unexported `_raw`, e.g. `_raw(Priorities.REAL_TIME) == LibZenohC.Z_PRIORITY_REAL_TIME`. The seven priority levels, the two congestion-control modes, the two reliability modes, the three localities, the three query targets, the two reply-keyexpr modes, the two sample kinds, and the three discovery roles each match the C enum exactly; the four consolidation modes are each built via their `z_query_consolidation_t` constructor rather than a bare enumerator. [`Priority`](@ref), [`CongestionControl`](@ref), [`Reliability`](@ref), and [`SampleKind`](@ref) also round-trip in reverse — the `priority`/`congestion_control`/`reliability`/`kind` accessors on a [`Sample`](@ref) read the libzenoh value off the loaned sample and recover the typed singleton.

The divergences are deliberate and worth naming exactly:

- **Singleton sum types, not an enum.** Zenoh.jl models each level as a distinct zero-field type under an abstract supertype, which enables dispatch and free identity comparison. Rust and C use one bounded enum value per setting.
- **`CongestionControls` omits `BlockFirst`.** Only `BLOCK` and `DROP` exist; the C/Rust `BlockFirst` (`Z_CONGESTION_CONTROL_BLOCK_FIRST`, an unstable Rust feature) has no Julia equivalent. The underlying integers follow C ordering (`BLOCK=0`, `DROP=1`), reversed from Rust's discriminants; the singleton API hides the difference, so reason about behavior.
- **Consolidation is a built struct.** `_raw` on a `QueryConsolidations` singleton calls the libzenoh builder (`z_query_consolidation_auto()`, …) and returns a fully-built `z_query_consolidation_t`, ready to drop into the get/querier options. The signed `z_consolidation_mode_t` enum stays hidden, and its numbering differs both ways: the C enum is signed (`AUTO=-1`, `NONE=0`, `MONOTONIC=1`, `LATEST=2`) while Rust's `ConsolidationMode` discriminants run `0..3` — another reason to reason about behavior.
- **Module grouping differs from Rust.** Zenoh.jl folds all of these, plus `ReplyKeyexpr` and `WhatAmI`, into one `qos.jl`, where Rust scatters them across `zenoh::qos`, `zenoh::query`, and `zenoh::sample`.
- **Publisher reliability is fixed at declare time.** `z_publisher_put_options_t` carries no reliability field, so a per-`put` call on a publisher cannot override the reliability set when the publisher was declared. A session `put` carries its own `reliability=`.
- **Reliability bridges into static config.** A `Reliabilities` singleton entering a `PublicationRule` / `QosOverwriteValues` section emits the zenoh config token `"reliable"` or `"best_effort"`. The other QoS settings reach config as their own keyword fields rather than through this builder bridge.

!!! warning "Reliability is stable here, unstable in Rust"
    `zenoh::qos::Reliability` sits behind the unstable crate feature in Rust. [`Reliability`](@ref) is a first-class, stable part of the Zenoh.jl API — treat it as GA.

!!! note "WhatAmI is a discovery role, only loosely QoS"
    [`WhatAmI`](@ref) names a node's scouting role. It lives in `qos.jl` for implementation convenience and shares the singleton design, but its natural home is discovery. Unlike every other submodule here it defines no `DEFAULT` constant, and `scout`'s `what=` filter takes `Symbol`s rather than `WhatAmI` singletons.