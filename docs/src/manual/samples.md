```@meta
CurrentModule = Zenoh
```

# Samples

A `Sample` is the data unit Zenoh delivers to a subscriber, a query reply, or a [`get`](@ref). It bundles everything the network carried alongside the data: the [key expression](@ref "Key Expressions") it was published on, the [payload](@ref "Payloads & Serialization") bytes, the [`kind`](@ref) (a put or a delete), the [`encoding`](@ref) of the payload, an optional [`timestamp`](@ref), an optional [`attachment`](@ref), and four [quality-of-service](@ref "Quality of Service") values (`express`, `congestion_control`, `priority`, `reliability`). Zenoh's Rust API defines it as "the data unit received by `Subscriber` or `Querier` or `Session::get`; it contains the payload and all metadata associated with the data" ([`zenoh::sample::Sample`](https://docs.rs/zenoh/1.9.0/zenoh/sample/struct.Sample.html)).

Samples are received-only. You read their fields through the accessor functions below; you never construct one to publish. To send data, pass it through the call options of [`put`](@ref), `delete!`, and `reply`.

This page also covers [`ZTimestamp`](@ref), the sibling timestamp value you read off an inbound sample with [`timestamp`](@ref) or mint from a session to stamp an outbound put.

## The three sample representations

Zenoh.jl gives you a sample in one of three forms, each with its own lifetime. All three subtype `AbstractSample`, so every accessor below works uniformly on any of them.

| Form | You get it from | Lifetime |
|------|-----------------|----------|
| Owned [`Sample`](@ref) | `take!`, the `:keep_all` channel | A stable value you hold for as long as you like; reclaimed by GC. |
| Loaned [`Sample`](@ref) | `sample(::Reply)` (so the replies of a [`get`](@ref)) | Borrows from an `owner` value — valid only while that owner lives. |
| [`SampleHolder`](@ref) | You allocate one; [`recv!`](@ref) / [`tryrecv!`](@ref) / `for s in sub` refill it | Reusable single slot — its occupant is valid only until the next refill. |

The owned form is the safe default: hold it, stash it, pass it around. The loaned form and the `SampleHolder` occupant are borrows — valid only while their backing lives.

!!! warning "Borrowed samples are valid only until their backing goes away"
    Anything derived from a loaned `Sample` or a `SampleHolder` occupant — the [`payload`](@ref) `ZBytes`, the [`keyexpr`](@ref) string, the [`attachment`](@ref) — is valid only until the next [`recv!`](@ref)/[`tryrecv!`](@ref) refill (for a holder) or until the `owner` is collected (for a loaned sample). To keep data past that point, copy it out: `String(payload(s))`, `collect(payload(s))`, the `String` from `keyexpr(s)`.

## Reading a sample

Every accessor works uniformly on any sample form, returning the same value regardless of which representation you hold.

| Accessor | Returns | Notes |
|----------|---------|-------|
| [`keyexpr`](@ref)`(s)` | `String` | A fresh copy of the key expression. |
| [`keyexpr_view`](@ref)`(f, s)` | `f`'s result | Zero-copy byte view for hot paths; no `String` allocated. |
| [`payload`](@ref)`(s)` | `ZBytes` | Loaned; decode with `String`, `Vector{UInt8}`, or a reader. |
| [`encoding`](@ref)`(s)` | `Encoding` | The payload's format descriptor. |
| [`kind`](@ref)`(s)` | `SampleKind` | `SampleKinds.PUT` or `SampleKinds.DELETE`. |
| [`timestamp`](@ref)`(s)` | `ZTimestamp` or `nothing` | `nothing` when no timestamp is associated. |
| [`attachment`](@ref)`(s)` | `ZBytes` or `nothing` | `nothing` when no attachment is present. |
| [`priority`](@ref)`(s)` | `Priority` | QoS. |
| [`congestion_control`](@ref)`(s)` | `CongestionControl` | QoS. |
| [`express`](@ref)`(s)` | `Bool` | Whether batching was bypassed. |
| [`reliability`](@ref)`(s)` | `Reliability` | QoS. |

[`kind`](@ref) returns one of the `SampleKinds` singletons. Compare them with `===`:

```julia
if kind(s) === SampleKinds.PUT
    # value was published
elseif kind(s) === SampleKinds.DELETE
    # key was deleted
end
```

`SampleKinds` is a module holding the two singleton instances `SampleKinds.PUT` and `SampleKinds.DELETE`, both subtyping the abstract `SampleKind` returned by [`kind`](@ref).

## Zero-allocation receive loops

A [`SampleHolder`](@ref) is a caller-owned single slot you allocate once and refill in place, so a tight receive loop allocates nothing per sample. [`recv!`](@ref) blocks for the next sample, refills the holder in place (dropping the prior occupant), and returns it — or `nothing` once the subscriber is closed and drained. [`tryrecv!`](@ref) is the non-blocking variant: it refills the holder and returns it, or returns `nothing` when nothing is buffered.

```julia
using Zenoh

session = open(Config())
sub     = open(session, Keyexpr("demo/**"); channel = :fifo, capacity = 16)

holder = SampleHolder()
while (s = recv!(sub, holder)) !== nothing
    # `s` (and anything derived from it) is valid only until the next recv!.
    if kind(s) === SampleKinds.PUT
        key  = keyexpr(s)            # String, copied out
        body = String(payload(s))    # decode the ZBytes payload, copied out
        @info "put" key body encoding=encoding(s) priority=priority(s)

        ts = timestamp(s)            # ZTimestamp or nothing
        ts === nothing || @info "stamped" ntp64 = ntp64_time(ts)
    elseif kind(s) === SampleKinds.DELETE
        @info "delete" key = keyexpr(s)
    end
end

close(sub)
```

Iterating a buffered subscriber (`for s in sub`) reuses one holder internally, giving the same per-sample lifetime: process each `s` within its loop iteration.

## Timestamps

A [`ZTimestamp`](@ref) is a Zenoh timestamp: an NTP64 time produced by a Hybrid Logical Clock plus the [`zid`](@ref) of the HLC that generated it. On a put, "the first Zenoh router receiving this value automatically associates it with a timestamp" ([Zenoh timestamp](https://zenoh.io/docs/manual/abstractions/#timestamp)).

You obtain a `ZTimestamp` two ways: read one off an inbound sample with [`timestamp`](@ref), or mint a fresh one from a session's clock to stamp an outbound put, delete, or reply.

```julia
ts = ZTimestamp(session)                       # mint from the session's HLC
put(session, Keyexpr("demo/example"), "hello"; timestamp = ts)
```

[`ntp64_time`](@ref) returns the raw 64-bit NTP64 value as a `UInt64`. Split it yourself into the high 32 bits (seconds) and low 32 bits (fraction):

```julia
raw      = ntp64_time(ts)
seconds  = raw >> 32
fraction = raw & 0xffffffff
```

## Public API

```@docs
Sample
SampleHolder
payload
keyexpr
keyexpr_view
encoding
attachment
timestamp
kind
priority
congestion_control
express
reliability
ZTimestamp
ntp64_time
```

## Mapping to Zenoh, Rust, and C

| Zenoh.jl | Zenoh abstraction | Rust | zenoh-c |
|----------|-------------------|------|---------|
| [`Sample`](@ref) | [Sample](https://docs.rs/zenoh/1.9.0/zenoh/sample/struct.Sample.html) | [`sample::Sample`](https://docs.rs/zenoh/1.9.0/zenoh/sample/struct.Sample.html) | [`z_owned_sample_t` / `z_loaned_sample_t`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [`payload`](@ref) | [Value](https://zenoh.io/docs/manual/abstractions/#value) (payload half) | `Sample::payload()` | `z_sample_payload` |
| [`keyexpr`](@ref) / [`keyexpr_view`](@ref) | [Key expression](https://zenoh.io/docs/manual/abstractions/#key-expression) | `Sample::key_expr()` | `z_sample_keyexpr` |
| [`encoding`](@ref) | [Encoding](https://zenoh.io/docs/manual/abstractions/#encoding) | `Sample::encoding()` | `z_sample_encoding` |
| [`kind`](@ref) → [`SampleKind`](@ref) | [SampleKind](https://docs.rs/zenoh/1.9.0/zenoh/sample/enum.SampleKind.html) | [`sample::SampleKind`](https://docs.rs/zenoh/1.9.0/zenoh/sample/enum.SampleKind.html) | `z_sample_kind`, `z_sample_kind_t` |
| [`timestamp`](@ref) | [Timestamp](https://zenoh.io/docs/manual/abstractions/#timestamp) | `Sample::timestamp()` | `z_sample_timestamp` |
| [`attachment`](@ref) | — | `Sample::attachment()` | `z_sample_attachment` |
| [`express`](@ref) | — | `Sample::express()` | `z_sample_express` |
| [`congestion_control`](@ref) | — | `Sample::congestion_control()` | `z_sample_congestion_control` |
| [`priority`](@ref) | — | `Sample::priority()` | `z_sample_priority` |
| [`reliability`](@ref) | — | `Sample::reliability()` | `z_sample_reliability` |
| [`ZTimestamp`](@ref) | [Timestamp](https://zenoh.io/docs/manual/abstractions/#timestamp) | [`time::Timestamp`](https://docs.rs/zenoh/1.9.0/zenoh/time/struct.Timestamp.html) | `z_timestamp_t` |
| [`ZTimestamp(::Session)`](@ref) | — | [`Session::new_timestamp`](https://docs.rs/zenoh/1.9.0/zenoh/struct.Session.html#method.new_timestamp) | `z_timestamp_new` |
| [`ntp64_time`](@ref) | NTP64 time | [`time::NTP64`](https://docs.rs/zenoh/1.9.0/zenoh/time/struct.NTP64.html) via `get_time()` | `z_timestamp_ntp64_time` |
| [`zid`](@ref)`(::ZTimestamp)` | node UUID | [`TimestampId`](https://docs.rs/zenoh/1.9.0/zenoh/time/type.TimestampId.html) via `get_id()` | `z_timestamp_id` |

Each Zenoh.jl accessor maps one-to-one onto the corresponding `z_sample_*` C function (called through the loaned form), which in turn mirrors the Rust `Sample` accessor of the same name — including the four QoS accessors [`express`](@ref), [`congestion_control`](@ref), [`priority`](@ref), and [`reliability`](@ref), which match Rust's `Sample::express()`, `Sample::congestion_control()`, `Sample::priority()`, and `Sample::reliability()`. The mapping diverges in the following named ways.

!!! note "Value is split into payload and encoding"
    Zenoh's [`Value`](https://zenoh.io/docs/manual/abstractions/#value) fuses a payload with its encoding. Zenoh.jl exposes the two halves independently — [`payload`](@ref) returns a `ZBytes` and [`encoding`](@ref) returns an `Encoding` — with no fused `Value` wrapper, following zenoh-c.

!!! note "kind reifies the enum as singleton types"
    Rust's [`SampleKind`](https://docs.rs/zenoh/1.9.0/zenoh/sample/enum.SampleKind.html) is an enum with `Put` and `Delete` variants. Zenoh.jl reifies these as the singleton instances `SampleKinds.PUT` and `SampleKinds.DELETE` under an abstract [`SampleKind`](@ref) supertype; compare them with `===`.

!!! note "NTP64 is returned raw"
    [`ntp64_time`](@ref) returns the raw 64-bit value as a `UInt64`. Split the high 32 bits (seconds) and low 32 bits (fraction) yourself. [`ZTimestamp`](@ref) holds `z_timestamp_t` by value (it carries no external resources), so there is no owned/loaned split and no drop.

!!! warning "SampleHolder is a Zenoh.jl construct with no Zenoh counterpart"
    [`SampleHolder`](@ref) reuses a single `z_owned_sample_t` slot for zero-allocation receive loops. It has no analog in the Rust or C API. Its occupant — and anything derived from it — is valid only until the next refill, a lifetime hazard absent from owned [`Sample`](@ref)s. Rust models the borrow distinction through the borrow checker; Zenoh.jl enforces it by retaining `owner` and by convention.

!!! warning "Samples are received-only"
    Rust offers [`SampleBuilder`](https://docs.rs/zenoh/1.9.0/zenoh/sample/struct.SampleBuilder.html) (and `Put`/`Delete`/`Any` variants) to construct a `Sample`, and [`SampleFields`](https://docs.rs/zenoh/1.9.0/zenoh/sample/struct.SampleFields.html) to destructure one without cloning. Zenoh.jl has neither: you only ever receive samples and read them through per-field accessors. Rust's [`source_info()`](https://docs.rs/zenoh/1.9.0/zenoh/sample/struct.Sample.html#method.source_info) (source id and sequence number, an unstable Rust API) likewise has no Zenoh.jl accessor, and the C `z_sample_clone` path is internal-only — the owned `Sample` comes from the receive machinery, never an explicit user clone.

All sample and timestamp functions live in the stable core C API (the `z_` prefix); none use the `zc_` config helpers or the experimental `ze_` extensions ([zenoh-c API](https://zenoh-c.readthedocs.io/en/1.9.0/api.html)).

`zid` is exported, and [`zid`](@ref)`(::ZTimestamp)` is a method on that same generic shared with `zid(::Session)`. After `using Zenoh`, call it directly as `zid(ts)` (or fully qualified as `Zenoh.zid(ts)`).