```@meta
CurrentModule = Zenoh
```

# Encoding

An [`Encoding`](@ref) is the format descriptor that travels alongside a payload so a receiver knows how to interpret the bytes it gets. It is a MIME-like media type in `type/subtype[;schema]` form — `"application/json"`, `"text/plain;utf-8"` — matching Zenoh's definition of encoding as ["a description of the value format, allowing Zenoh (or your application) to know how to encode/decode the value to/from a bytes buffer"](https://zenoh.io/docs/manual/abstractions/#encoding).

Encoding is metadata, not a transform. Zenoh carries the descriptor on the wire and hands it back unchanged. Attaching the right encoding lets higher layers (content filtering, automatic deserialization in other clients) act on the payload, while the [predefined media types](https://docs.rs/zenoh/1.9.0/zenoh/bytes/struct.Encoding.html) keep the network cost small.

## Constructing an encoding

`Encoding` holds two fields: a `mime` media-type string and an optional `schema`. Build one from a string, append a schema with the keyword, and serialize back to the wire form with `string`:

```julia
using Zenoh

e = Encoding("text/plain"; schema = "utf-8")
e.mime     # "text/plain"
e.schema   # "utf-8"
string(e)  # "text/plain;utf-8"

Encoding("application/json")  # schema defaults to nothing
```

The `schema` is an arbitrary substring appended after a semicolon. [Zenoh leaves its semantics to the implementer](https://docs.rs/zenoh/1.9.0/zenoh/bytes/struct.Encoding.html) and carries it verbatim — `utf-8` for `text/plain` is the conventional example. Zenoh.jl passes the schema through verbatim; apply any escaping your consumers require.

A Julia `Base.MIME` constructs an encoding too, by stringifying it:

```julia
Encoding(MIME("application/json")) == Encoding("application/json")  # true
```

`Encoding(::AbstractString)` always succeeds — any string is a valid `mime`, so construction never fails. `Encoding` values are immutable and compare and hash by their fields, so they work directly as `Dict` and `Set` keys.

## Well-known encodings

The [`Encodings`](@ref) submodule provides 53 named constants for standard media types. Access them with the qualified name — they are not exported, so `Encodings.NAME` is required:

```julia
using Zenoh

Zenoh.Encodings.APPLICATION_JSON   # Encoding("application/json")
Zenoh.Encodings.TEXT_PLAIN         # Encoding("text/plain")
Zenoh.Encodings.ZENOH_BYTES        # Encoding("zenoh/bytes")
```

Each constant is a precomputed `Encoding` value carrying the literal media-type string. The names follow Zenoh's predefined media-type families: `application/*` (20), `audio/*` (5), `image/*` (5), `text/*` (10), `video/*` (10), and `zenoh/*` (3).

`zenoh/bytes` is Zenoh's [default encoding for raw binary data](https://docs.rs/zenoh/1.9.0/zenoh/bytes/struct.Encoding.html). Zenoh.jl has no zero-argument `Encoding()` constructor: to send a payload without specifying a format, pass `nothing` (the default) for the `encoding` keyword and Zenoh applies the `zenoh/bytes` default for you.

## Three interchangeable input forms

Every operation that takes an `encoding` keyword — [`put`](@ref), [`get`](@ref Base.get), [`Publisher`](@ref), [`reply`](@ref) — accepts an `Encoding`, an `AbstractString`, or a `Base.MIME`. (`get` on a [`Querier`](@ref) takes `encoding` at get time, not on the querier constructor.) Most paths annotate the keyword as `Union{Nothing, Encoding, AbstractString, Base.MIME}`; `reply` annotates it as plain `encoding=nothing`. All of them route the value through the same `_as_encoding` coercion to an `Encoding`, so you can pass whichever form is most convenient:

```julia
ke = Keyexpr("demo/key")   # or kexpr"demo/key"

# All three are equivalent at the call site.
put(session, ke, data; encoding = Zenoh.Encodings.APPLICATION_JSON)
put(session, ke, data; encoding = "application/json")
put(session, ke, data; encoding = MIME("application/json"))
```

Passing a bare string is the lightweight path for one-off custom types; the named constants document intent and give you compiler-checked names for the common cases.

## Reading an encoding off a sample

The [`encoding`](@ref) accessor on a received [`Sample`](@ref) returns an `Encoding`, reconstructed from the wire form. Reply errors expose theirs through [`error_encoding`](@ref):

```julia
enc = encoding(sample)
enc.mime
enc.schema   # nothing unless the sender appended one
```

Splitting the wire string on its first `;` round-trips well-formed values exactly.

!!! warning "Semicolons in the media type"
    Read-back takes everything after the first `;` as the schema, so a media type containing its own `;` is misread. Keep media-type strings free of semicolons and confine any `;` to the schema you control.

## Mapping to Zenoh, Rust, and C

| Zenoh.jl | Zenoh abstraction | Rust | zenoh-c |
| --- | --- | --- | --- |
| [`Encoding`](@ref) (struct) | [Encoding](https://zenoh.io/docs/manual/abstractions/#encoding) | [`zenoh::bytes::Encoding`](https://docs.rs/zenoh/1.9.0/zenoh/bytes/struct.Encoding.html) | [`z_owned_encoding_t`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) / `z_loaned_encoding_t` |
| `Encoding(mime; schema=…)` | `type/subtype[;schema]` | [`FromStr`](https://docs.rs/zenoh/1.9.0/zenoh/bytes/struct.Encoding.html) + [`with_schema`](https://docs.rs/zenoh/1.9.0/zenoh/bytes/struct.Encoding.html#method.with_schema) | [`z_encoding_from_str`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) + [`z_encoding_set_schema_from_str`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| `string(::Encoding)` | wire string | `to_string` | [`z_encoding_to_string`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [`Encodings`](@ref)`.NAME` | predefined media types | [`Encoding::APPLICATION_*` consts](https://docs.rs/zenoh/1.9.0/zenoh/bytes/struct.Encoding.html) | [`z_encoding_*()` accessors](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| `encoding(sample)` | sample encoding | sample `encoding()` | [`z_sample_encoding`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| `==`, `hash` (Julia-side) | value equality | `PartialEq` | [`z_encoding_equals`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) / `z_encoding_clone` (both unbound) |

Zenoh.jl's `Encoding` is the Julia-side mirror of Rust's `zenoh::bytes::Encoding`: a MIME-like media type plus optional schema, used as payload-format metadata on samples and replies. Rust itself treats that sample/reply encoding as optional metadata, which is why omission (`nothing`) is the natural absence model. The keyword `schema` constructor combines what Rust splits into `FromStr` and `with_schema`, and what C splits into `z_encoding_from_str` plus `z_encoding_set_schema_from_str`. Marshalling into a put/get/reply allocates a libzenoh-owned `z_owned_encoding_t` and moves it into the option struct; reading one back goes through `z_encoding_to_string` and a semicolon split.

Specific divergences from the Rust and C APIs:

!!! note "Constants are literal-string values, not libzenoh handles"
    `Encodings.*` are constructed as `Encoding("media/type")` at module load, bypassing the C accessor functions (`z_encoding_application_json()` and friends). They are plain immutable Julia values. The predefined-string-to-integer-id wire optimization happens later inside libzenoh during marshalling, when the constant is used.

!!! note "No default-encoding constructor"
    Rust provides `Default = ZENOH_BYTES` and C provides `z_encoding_loan_default()`. Zenoh.jl has no `Encoding()` and never calls `loan_default`. Express absence by passing `nothing` to the `encoding` keyword; libzenoh's own `zenoh/bytes` default then applies.

- **`schema` is a constructor keyword.** Pass it inline — `Encoding(mime; schema=…)` — where Rust uses the chained `with_schema` builder. `Encoding` is immutable; `z_encoding_set_schema_from_str` runs only as an internal marshalling step.
- **Schema is passed through verbatim.** The write path concatenates `mime;schema` with no escaping; the read path splits on the first `;`. Round-tripping is exact for well-formed inputs (see the warning above).
- **Equality and hashing live in Julia.** `==` and `hash` operate on the struct fields. `z_encoding_clone` and `z_encoding_equals` are not bound; the immutable value is re-marshalled on demand.
- **The submodule exports nothing.** Only the names `Encoding` and `Encodings` are exported; constants must be qualified as `Encodings.APPLICATION_JSON`. Rust exposes them as associated consts on the `Encoding` type itself.
- **Encoding is purely the format descriptor.** Payload bytes are a separate concern, reached through the sample's payload accessor.

```@docs
Encoding
Encodings
```
