```@meta
CurrentModule = Zenoh
```

# Key Expressions

A key expression denotes a *set* of keys. A Zenoh key is a `/`-joined list of UTF-8 chunks — `organizationA/building8/room275/sensor3/temperature` — where `/` is the hierarchical separator, [just like a Unix path](https://zenoh.io/docs/manual/abstractions/#key). A [key expression](https://zenoh.io/docs/manual/abstractions/#key-expression) adds wildcards over that hierarchy: `*` matches any characters within one chunk (never crossing `/`), `$*` matches within a chunk, and `**` matches zero or more chunks. So `demo/**` denotes every key under `demo`, and `demo/*/temperature` denotes the temperature of every direct child of `demo`. Key expressions are the addressing layer underneath every Zenoh operation — publishers, subscribers, queries, and queryables all name their data with one.

In Zenoh.jl a key expression is a [`Keyexpr`](@ref): a validated value whose memory the garbage collector reclaims for you. Build one from a string literal with the [`kexpr"…"`](@ref @kexpr_str) macro or from a runtime `String` with the [`Keyexpr`](@ref) constructor; both validate the syntax eagerly, so an ill-formed expression fails the moment you construct it. Once you hold two `Keyexpr` values, the set predicates ([`includes`](@ref), [`intersects`](@ref), [`relation_to`](@ref)) tell you how their key-sets relate, and the composition functions ([`concat`](@ref), [`join`](@ref Base.join)) build longer keys from shorter ones.

## Constructing a key expression

There are two construction paths. Reach for the macro when the expression is a literal known at parse time; reach for the constructor when the bytes arrive at runtime.

```julia
using Zenoh

a = kexpr"demo/**"                       # literal, validated when the macro expands
b = Keyexpr("demo/example/zenoh-jl")     # runtime String
```

The [`kexpr"…"`](@ref @kexpr_str) macro additionally interpolates `$name` and `$(expr)` pieces, splicing `Keyexpr` or `AbstractString` values into the result:

```julia
room = "room275"
k = kexpr"building8/$room/sensor3"       # building8/room275/sensor3

prefix = kexpr"building8/$room"
full = kexpr"$prefix/sensor3"            # Keyexpr pieces splice in directly
```

The interpolating form splices `Keyexpr` and `AbstractString` pieces directly into the result, without an extra copy through a Julia `String`.

## Canonicalization

A key expression has a canonical form: `**/**` reduces to `**`, `**/*` reorders to `*/**`, `$*$*` collapses to `$*`, and so on (see the [canonical-form rules](https://zenoh.io/docs/manual/abstractions/#key-expression)). Construction requires canonical input by default — a non-canonical expression throws a `ZenohError`, so a typo surfaces at construction. Construction never rewrites your input.

Opt into canonicalization with the `c` flag on the macro or `autocanonize=true` on the constructor:

```julia
kexpr"a/**/**"c                       # canonized → a/**
Keyexpr("a/**/**"; autocanonize=true) # same, runtime form
```

Canonicalization reduces redundant wildcard runs on otherwise-valid expressions; it does not repair structurally invalid syntax. An empty chunk such as the `//` in `a//b` is invalid, and both the plain and the autocanonizing paths throw a `ZenohError` on it.

To canonicalize or test plain strings before they become a `Keyexpr`, use [`canonize`](@ref) and [`is_canon`](@ref). These operate on `AbstractString`, not on `Keyexpr` (a constructed `Keyexpr` is already canonical):

```julia
is_canon("a/**/**")    # false
canonize("a/**/**")    # "a/**"
is_canon("a/**")       # true
canonize("a//b")       # throws ZenohError — the empty chunk in a//b is invalid syntax
```

## Set relations

Key expressions denote sets, so the natural questions are about set membership and overlap. [`relation_to`](@ref) answers all of them at once, returning the full lattice relationship as one of four typed singletons from [`IntersectionLevels`](@ref):

```julia
relation_to(kexpr"demo/**", Keyexpr("demo/example/zenoh-jl"))  # IntersectionLevels.INCLUDES
```

| Level | Meaning |
|-------|---------|
| `IntersectionLevels.DISJOINT` | no key in common |
| `IntersectionLevels.INTERSECTS` | some keys shared, neither set contains the other |
| `IntersectionLevels.INCLUDES` | `a` ⊇ `b` |
| `IntersectionLevels.EQUALS` | identical key-sets |

The boolean predicates are projections of that lattice. [`includes(a, b)`](@ref includes) tests `a ⊇ b`; [`intersects(a, b)`](@ref intersects) tests overlap. Julia's standard set operators work too: `issubset` (`⊆`) is the dual of `includes`, and `isdisjoint` is the negation of `intersects`, so both are computed in Julia from the same two calls.

```julia
a = kexpr"demo/**"
b = Keyexpr("demo/example/zenoh-jl")

includes(a, b)                  # true:  demo/** ⊇ demo/example/zenoh-jl
b ⊆ a                           # true:  same fact, dual direction (issubset)
intersects(a, b)                # true
isdisjoint(a, kexpr"other/**")  # true
```

### `==` and set equality coincide

A `Keyexpr` is stored in canonical form, and `==` compares that canonical text. `relation_to(a, b) == IntersectionLevels.EQUALS` asks the set question — do `a` and `b` match the same keys. For any two constructed `Keyexpr` values the two agree: canonicalization normalizes set-equal expressions to identical text, so `a/**/**` becomes `a/**` at construction and compares equal to a directly-built `a/**`.

```julia
x = Keyexpr("a/**")
y = Keyexpr("a/**/**"; autocanonize=true)       # canonized to "a/**" on construction

x == y                                          # true (same canonical text)
relation_to(x, y) == IntersectionLevels.EQUALS  # true (same key-set)
```

Use `==` (and the consistent `hash`) for identity in dictionaries and sets; use `relation_to`/`includes`/`intersects` to ask whether one expression matches another.

## Composing key expressions

[`join`](@ref Base.join) and [`concat`](@ref) build a longer key expression from parts. They differ in one place: `join` inserts a `/` separator, `concat` appends verbatim.

```julia
join(Keyexpr("demo"), Keyexpr("sensor"))    # Keyexpr("demo/sensor")    — separator inserted
concat(Keyexpr("demo/sensor"), "-temp")     # Keyexpr("demo/sensor-temp") — no separator
```

Use `join` to descend the hierarchy and `concat` to extend the final chunk.

## Reading a key expression back

`String`, `string`, `print`, and `show` all return the canonical text of a `Keyexpr`:

```julia
String(kexpr"demo/**")    # "demo/**"
```

## API

```@docs
AbstractKeyexpr
Keyexpr
@kexpr_str
includes
intersects
relation_to
IntersectionLevel
IntersectionLevels
concat
join(::Keyexpr, ::Keyexpr)
issubset(::Keyexpr, ::Keyexpr)
isdisjoint(::Keyexpr, ::Keyexpr)
canonize
is_canon
DeclaredKeyexpr
declare_keyexpr
```

## Mapping to Zenoh, Rust, and C

| Zenoh.jl | Zenoh abstraction | Rust | zenoh-c |
|----------|-------------------|------|---------|
| [`Keyexpr`](@ref) | [Key expression](https://zenoh.io/docs/manual/abstractions/#key-expression) | [`keyexpr` / `OwnedKeyExpr` / `KeyExpr`](https://docs.rs/zenoh/1.9.0/zenoh/key_expr/index.html) | [`z_owned_keyexpr_t`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [`kexpr"…"`](@ref @kexpr_str) | key-expression literal | [`KeyExpr::new`](https://docs.rs/zenoh/1.9.0/zenoh/key_expr/struct.KeyExpr.html#method.new) | `z_keyexpr_from_str` / `z_keyexpr_from_substr` |
| [`Keyexpr(s; autocanonize)`](@ref Keyexpr) | key-expression literal | [`KeyExpr::autocanonize`](https://docs.rs/zenoh/1.9.0/zenoh/key_expr/struct.KeyExpr.html#method.autocanonize) | `z_keyexpr_from_str{,_autocanonize}` |
| [`includes`](@ref) / [`issubset`](@ref Base.issubset) | set inclusion | [`keyexpr::includes`](https://docs.rs/zenoh/1.9.0/zenoh/key_expr/struct.keyexpr.html#method.includes) | `z_keyexpr_includes` |
| [`intersects`](@ref) / [`isdisjoint`](@ref Base.isdisjoint) | set intersection | [`keyexpr::intersects`](https://docs.rs/zenoh/1.9.0/zenoh/key_expr/struct.keyexpr.html#method.intersects) | `z_keyexpr_intersects` |
| [`relation_to`](@ref) + [`IntersectionLevels`](@ref) | [set-intersection relation](https://docs.rs/zenoh/1.9.0/zenoh/key_expr/enum.SetIntersectionLevel.html) | [`KeyExpr::relation_to`](https://docs.rs/zenoh/1.9.0/zenoh/key_expr/struct.KeyExpr.html#method.relation_to) → [`SetIntersectionLevel`](https://docs.rs/zenoh/1.9.0/zenoh/key_expr/enum.SetIntersectionLevel.html) | `z_keyexpr_relation_to` / `z_keyexpr_intersection_level_t` |
| `==` / `hash` | — | — | `z_keyexpr_equals` |
| [`concat`](@ref) | — | [`KeyExpr::concat`](https://docs.rs/zenoh/1.9.0/zenoh/key_expr/struct.KeyExpr.html#method.concat) | `z_keyexpr_concat` |
| [`join`](@ref Base.join) | — | [`keyexpr::join`](https://docs.rs/zenoh/1.9.0/zenoh/key_expr/struct.keyexpr.html#method.join) | `z_keyexpr_join` |
| [`canonize`](@ref) / [`is_canon`](@ref) | canonical form | [`Canonize`](https://docs.rs/zenoh/1.9.0/zenoh/key_expr/index.html) | `z_keyexpr_canonize` / `z_keyexpr_is_canon` |

[`Keyexpr`](@ref) wraps the C [`z_owned_keyexpr_t`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) handle with a `z_keyexpr_drop` finalizer, so it is the owned form and the bytes are always copied into owned storage. The constructor calls `z_keyexpr_from_str{,_autocanonize}`; the interpolating macro path assembles one buffer and calls `z_keyexpr_from_substr{,_autocanonize}`. `relation_to` maps `z_keyexpr_intersection_level_t` one-for-one onto the four [`IntersectionLevels`](@ref) singletons, which mirror Rust's [`SetIntersectionLevel`](https://docs.rs/zenoh/1.9.0/zenoh/key_expr/enum.SetIntersectionLevel.html) variants. `includes`, `intersects`, `concat`, `join`, `canonize`, and `is_canon` each wrap their `z_keyexpr_*` counterpart directly; `issubset` and `isdisjoint` are Julia-side derivations (`includes(b, a)` and `!intersects(a, b)`) with no dedicated C entry point.

!!! note "One Julia type for three Rust forms"
    Zenoh.jl exposes one form — the owned, GC-finalized [`Keyexpr`](@ref), which always owns its bytes. Rust splits the concept into the borrowed [`keyexpr`](https://docs.rs/zenoh/1.9.0/zenoh/key_expr/struct.keyexpr.html) (a `str` newtype), `OwnedKeyExpr` (an `Arc<str>`), and `KeyExpr` (a possibly-declared form that can carry a `Session` optimization); the C `z_view_keyexpr_t` borrowed view rounds out the set. The borrowed variants have no Julia equivalent; Rust's declared `KeyExpr` maps to [`DeclaredKeyexpr`](@ref) (see the warning below).

!!! note "relation_to is stable here, unstable in Rust"
    On Rust's borrowed [`keyexpr`](https://docs.rs/zenoh/1.9.0/zenoh/key_expr/struct.keyexpr.html#method.relation_to), `relation_to` is gated behind the crate's `unstable` feature flag (it is stable on `KeyExpr`). Zenoh.jl exposes [`relation_to`](@ref) unconditionally.

!!! warning "Declared key expressions carry no wire benefit here"
    `z_declare_keyexpr` / `z_undeclare_keyexpr` are wrapped as [`DeclaredKeyexpr`](@ref) (via [`declare_keyexpr`](@ref)) for API parity with upstream Zenoh, but in this libzenohc they provide **no on-wire optimization**: session-level `put`/`get` send the full key string on every call regardless of declaration. This was confirmed by profiling and a pure-C repro — it is a libzenohc/zenoh-core behavior, not a binding limitation (the full investigation and repro live under `docs/design/`). The path that *does* reduce key bytes on the wire is a [`Publisher`](@ref) (or [`Querier`](@ref)), which declares its own key — so for repeated operations on a fixed key, use those, not `DeclaredKeyexpr`.

!!! note "Interpolation is a Zenoh.jl extension"
    The `$name` / `$(expr)` template assembly in [`kexpr"…"`](@ref @kexpr_str) is specific to Zenoh.jl. Rust constructs key expressions from string literals through [`KeyExpr::new`](https://docs.rs/zenoh/1.9.0/zenoh/key_expr/struct.KeyExpr.html#method.new); the single-buffer `$`-interpolation has no Rust or C analogue.