```@meta
CurrentModule = Zenoh
```

# Scouting

Scouting discovers other Zenoh nodes on the network. Zenoh defines it as
[the process of discovering Zenoh nodes in the network](https://docs.rs/zenoh/1.9.0/zenoh/scouting/index.html),
driven by the transport layer and the active configuration. A node answers a
scout probe with a [`Hello`](@ref) message carrying its identity, role, and
reachable endpoints. A process can scout without ever opening a
[session](@ref "Sessions & Configuration").

Zenoh.jl exposes discovery through one exported function, [`scout`](@ref). A
single call runs one bounded scouting round against a copy of the supplied
[`Config`](@ref), delivers a [`Hello`](@ref) per node heard, and returns when
the round ends. Two forms cover the common needs: a callback form that handles
each [`Hello`](@ref) as it arrives, and a collecting form that hands back a
`Vector{Hello}` once the round finishes. Reach for the callback form to act on
each peer as it is discovered; reach for the collecting form when you want the
complete set in hand.

## Running one round

`scout` runs exactly one round and blocks the calling task until that round
completes. A round ends when its timeout elapses or Zenoh otherwise terminates
it, so a finite `timeout_ms` bounds how long the call blocks.

```julia
using Zenoh

config = Config()                       # default configuration

# Collecting form: block, then return every Hello heard this round.
hellos = scout(config; timeout_ms=1000)
for h in hellos
    println(whatami_string(h.whatami), " ", h.zid, " @ ", h.locators)
end
```

`timeout_ms` bounds the round in milliseconds. `timeout_ms=0` (the default)
uses Zenoh's default round length; it does not mean an instant or unbounded
round.

## Handling discoveries as they arrive

The callback form invokes `f(::Hello)` on a dedicated Julia task once per node
announcement, and blocks until the round finishes. Reach for it to act on each
peer as it is discovered.

```julia
using Zenoh

scout(Config(); timeout_ms=1000) do h::Hello
    @info "discovered" role=whatami_string(h.whatami) zid=h.zid locators=h.locators
end
```

The collecting form returns every `Hello` once the round ends.

## Filtering by role with `what`

The `what` keyword selects which node roles to probe for. It accepts a
[`WhatAmI`](@ref) singleton, a collection of them, or `nothing` (the default)
to use Zenoh's default filter. The singletons are `WhatAmIs.ROUTER`,
`WhatAmIs.PEER`, and `WhatAmIs.CLIENT`; combine roles by passing a tuple.

```julia
# Routers and peers only.
scout(Config(); what=(WhatAmIs.ROUTER, WhatAmIs.PEER), timeout_ms=1000) do h::Hello
    @info "node" role=whatami_string(h.whatami)
end

# A single role.
hellos = scout(Config(); what=WhatAmIs.PEER, timeout_ms=1000)
```

`what` uses the same [`WhatAmI`](@ref) values that come back on
`Hello.whatami`, so the role you filter on and the role you read are spelled
identically.

## Reading a `Hello`

Each [`Hello`](@ref) exposes three fields:

- `zid` — the node's Zenoh ID.
- `whatami::WhatAmI` — its announced role, a [`WhatAmI`](@ref) singleton
  (`WhatAmIs.ROUTER`, `WhatAmIs.PEER`, or `WhatAmIs.CLIENT`).
- `locators::Vector{String}` — the endpoints the node is reachable at.

A returned `Hello` is fully detached and safe to keep indefinitely: every
field, including each locator string, stays valid after the round ends.

Use [`whatami_string`](@ref) for Zenoh's lowercase role name; `show`
renders the singleton as `WhatAmIs.PEER`:

```julia
h = first(scout(Config(); what=WhatAmIs.PEER, timeout_ms=1000))
whatami_string(h.whatami)   # "peer"
h.whatami                   # WhatAmIs.PEER
```

[`whatami_string`](@ref) accepts the role singleton directly, so
`whatami_string(h.whatami)` and `whatami_string(WhatAmIs.PEER)` both work.

## Choosing a discovery strategy

Which nodes answer a scout round depends on the transport configuration. Two
strategies dominate, configured through the [`Config`](@ref):

- **Multicast scouting.** Nodes in `peer` mode
  [join multicast group `224.0.0.224` on UDP port `7446`](https://zenoh.io/docs/getting-started/deployment/)
  and automatically connect to the peers and routers they discover there.
  Client mode runs multicast scouting too, to find a node to attach its single
  session to.
- **Gossip scouting.** Peer-mode nodes
  [forward the applications and routers they already know to newly scouted nodes](https://zenoh.io/docs/getting-started/deployment/),
  bootstrapping discovery from entry points listed in the configuration's
  `connect` section. Gossip scouting is the fallback when multicast is
  unavailable.

## API

```@docs
scout
Hello
whatami_string
```

The role values returned in [`Hello`](@ref)`.whatami` are documented with the
rest of the quality-of-service singletons: see [`WhatAmI`](@ref) and
[`WhatAmIs`](@ref) on the [Quality of Service](@ref) page.

## Mapping to Zenoh, Rust, and C

| Zenoh.jl | Zenoh abstraction | Rust | zenoh-c |
| --- | --- | --- | --- |
| [`scout`](@ref) (callback form) | [scouting](https://docs.rs/zenoh/1.9.0/zenoh/scouting/index.html) round + callback handler | [`zenoh::scout`](https://docs.rs/zenoh/1.9.0/zenoh/fn.scout.html) → [`ScoutBuilder`](https://docs.rs/zenoh/1.9.0/zenoh/scouting/struct.ScoutBuilder.html) → [`Scout`](https://docs.rs/zenoh/1.9.0/zenoh/scouting/struct.Scout.html) | `z_scout` |
| [`scout`](@ref) (collecting form) | scouting round drained to a list | awaiting a [`Scout`](https://docs.rs/zenoh/1.9.0/zenoh/scouting/struct.Scout.html) and receiving every `Hello` | `z_scout` + manual collection |
| [`Hello`](@ref) | [Hello message](https://docs.rs/zenoh/1.9.0/zenoh/scouting/struct.Hello.html) | [`zenoh::scouting::Hello`](https://docs.rs/zenoh/1.9.0/zenoh/scouting/struct.Hello.html) | `z_owned_hello_t` |
| `Hello.zid` / `.whatami` / `.locators` | Hello identity / role / endpoints | `Hello::zid()` / `whatami()` / `locators()` | `z_hello_zid` / `z_hello_whatami` / `z_hello_locators` |
| [`WhatAmI`](@ref) | [node role](https://zenoh.io/docs/getting-started/deployment/) | `zenoh::config::WhatAmI` | `z_whatami_t` |
| `what` keyword (`WhatAmI`) | role filter | [`WhatAmIMatcher`](https://docs.rs/zenoh/1.9.0/zenoh/config/struct.WhatAmIMatcher.html) | `z_what_t` + `z_scout_options_t.what` |
| `timeout_ms` keyword | round length | scout duration | `z_scout_options_t.timeout_ms` |
| [`whatami_string`](@ref) | role name string | — | `z_whatami_to_view_string` |

The callback form of [`scout`](@ref) is the whole-pipeline equivalent of Rust's
[`zenoh::scout(what, config)`](https://docs.rs/zenoh/1.9.0/zenoh/fn.scout.html)
with a callback handler: it calls C `z_scout` with the moved config, a moved
`z_closure_hello_t`, and a `z_scout_options_t`, then fires `f(::Hello)` per
reply. The collecting form is the analogue of awaiting a Rust
[`Scout`](https://docs.rs/zenoh/1.9.0/zenoh/scouting/struct.Scout.html) and
receiving every `Hello`, returning them as a `Vector{Hello}`. Each `Hello`
field maps one-to-one onto a Rust accessor and the matching `z_hello_*` call.
The `what` keyword is Zenoh.jl's spelling of the
[`WhatAmIMatcher`](https://docs.rs/zenoh/1.9.0/zenoh/config/struct.WhatAmIMatcher.html):
`WhatAmIs.ROUTER`/`.PEER`/`.CLIENT` OR-combine into a `z_what_t` bitset, and
`timeout_ms` writes straight into `z_scout_options_t.timeout_ms` only when it is
greater than `0`, leaving libzenohc's default round length in place otherwise.
The
[`Config`](@ref) is cloned before the call because C `z_scout` takes
`z_moved_config_t` and consumes it — the same
[owned/loaned/moved model](https://zenoh-c.readthedocs.io/en/1.9.0/concepts.html)
that governs the rest of the bindings.

Four behaviors diverge from Rust:

!!! warning "Single bounded round, no Scout handle"
    Rust's [`zenoh::scout`](https://docs.rs/zenoh/1.9.0/zenoh/fn.scout.html)
    returns a
    [`ScoutBuilder`](https://docs.rs/zenoh/1.9.0/zenoh/scouting/struct.ScoutBuilder.html),
    and the resulting
    [`Scout`](https://docs.rs/zenoh/1.9.0/zenoh/scouting/struct.Scout.html)
    scouts continuously until it is dropped. Zenoh.jl exposes neither a builder
    nor a handle: [`scout`](@ref) runs exactly one bounded round and blocks
    until libzenohc ends it. Bound the round with `timeout_ms`. There is no
    `Scout` handle to drop for early termination.

!!! note "Callback-only transport, no streaming receiver"
    libzenohc provides only the `z_closure_hello_t` callback channel for
    scouting; it ships no FIFO/ring handler for `Hello`. Zenoh.jl mirrors this
    directly. Rust's streaming receiver
    (`while let Ok(hello) = receiver.recv_async().await`) has no Zenoh.jl
    counterpart: pass a callback, or take the whole `Vector{Hello}` after the
    round finishes. The collecting [`scout`](@ref) form is built on top of the
    callback form (`push!` under a lock), not from a generic handler.

!!! note "Eager copy, not lazy borrow"
    Rust's `Hello` accessors borrow from the live message. Zenoh.jl copies every
    field — including each locator `String` — into Julia-owned memory at
    construction, because the underlying `z_owned_hello_t` is dropped before the
    user touches the `Hello`. The Julia `Hello` is therefore fully detached and
    safe to retain.

!!! note "`what` is Symbol-based"
    Elsewhere Zenoh.jl uses typed [`WhatAmI`](@ref) singletons, but `scout`'s
    `what` filter takes Symbols (`:router`/`:peer`/`:client`), compound symbols
    (`:router_peer`), or symbol collections. Passing a [`WhatAmI`](@ref) value
    to `what` is unsupported and errors. Roles are read back as
    [`WhatAmI`](@ref) values on `Hello.whatami`.