```@meta
CurrentModule = Zenoh
```

# Payloads & Serialization

A [`ZBytes`](@ref) is Zenoh's raw byte payload: the data half of every message that crosses the network. Zenoh's model calls the data-plus-format unit a [Value](https://zenoh.io/docs/manual/abstractions/#value) — "a user provided data item along with its encoding" — and [`ZBytes`](@ref) carries the data, the raw payload bytes held with minimized copying. The matching [Encoding](https://zenoh.io/docs/manual/abstractions/#value) is a separate object (see [Encoding](@ref)); you assemble a Value at the call site by passing both to [`put`](@ref) or [`reply`](@ref), so the two halves stay independent.

This page covers two distinct layers:

1. **Raw payloads** — [`ZBytes`](@ref), its readers/writer, and [`ZSlice`](@ref). These move bytes verbatim and conform to Julia's `IO` interface.
2. **The structured codec** — [`ZSerializer`](@ref) / [`ZDeserializer`](@ref) and the [`serialize`](@ref Zenoh.serialize) / [`deserialize`](@ref Zenoh.deserialize) helpers. This is `zenoh-ext`'s portable, framed, length-prefixed, defined-endian encoding that round-trips typed values across Zenoh's Rust, C++, Python, and Julia bindings.

A raw [`ZBytes`](@ref) ships bytes you already have; the codec produces a [`ZBytes`](@ref) a peer in another language can decode field-by-field. Both travel as a [`ZBytes`](@ref) on the wire.

## Sending raw bytes

[`put`](@ref) and [`reply`](@ref) accept anything [`ZBytes`](@ref) can wrap, so the common case needs no explicit construction:

```julia
using Zenoh

pub = Publisher(session, kexpr"demo/raw")
put(pub, UInt8[1, 2, 3, 4])   # wrapped in a ZBytes for you
put(pub, "hello")             # a String works the same way
```

Constructing a [`ZBytes`](@ref) yourself matters when you care about ownership and copying. The byte- and string-buffer constructors default to **zero-copy take-ownership**: Zenoh borrows your buffer in place and frees it through a deleter once transmission completes. Zenoh.jl pins the Julia source for you until that deleter fires, so the buffer stays alive exactly as long as Zenoh needs it.

```julia
buf = rand(UInt8, 1 << 20)
put(pub, ZBytes(buf))             # zero-copy: `buf` is pinned until zenoh releases it
put(pub, ZBytes(buf; copy=true))  # immediate copy: `buf` is free to mutate afterward
```

Pass `copy=true` when the source is short-lived or about to be mutated; Zenoh copies immediately, so the source need not outlive the call. A `Symbol` becomes a static-lifetime string payload with no copy and no pinning, since interned symbol data is effectively static.

### Ownership and cleanup

Clean up an owned [`ZBytes`](@ref) on the caller's task — Zenoh.jl attaches no GC finalizer, because dropping a shared-memory-backed payload off-thread would corrupt Zenoh's SHM bookkeeping and can wedge delivery. Two leak-free exits cover every owned [`ZBytes`](@ref) you can hold:

- **Move-on-send** — passing it to [`put`](@ref), [`reply`](@ref), or `get` hands ownership to Zenoh, which frees it.
- **Explicit `close`** — `close(z)` drops it on your task when you build one but decide not to send it.

```julia
z = ZBytes(UInt8[0xde, 0xad])
# ... decide not to send it ...
close(z)   # reclaim on this task
```

Building an owned [`ZBytes`](@ref) and dropping the reference without sending or closing it leaks the buffer. Inbound payloads are loaned (see below), so this concerns only payloads you construct. [`ZSlice`](@ref) differs here: it attaches a drop finalizer, because slices are not SHM-backed and carry no deadlock risk.

## Reading inbound payloads

A payload that arrives in a subscriber or queryable callback is a **loaned** [`ZBytes`](@ref) borrowing the [`Sample`](@ref)'s buffer (see [`payload`](@ref)). The [`ZBytes`](@ref) holds the [`Sample`](@ref) as its owner, so the borrowed buffer stays valid while the [`ZBytes`](@ref) is reachable. To keep data past the callback, materialize a copy:

```julia
function on_sample(s)
    data = Vector{UInt8}(payload(s))   # copy out into an owned Julia vector
    text = String(payload(s))          # or decode the whole payload as a String
end
```

`String(z)` and `Vector{UInt8}(z)` each consolidate the entire payload — including a fragmented one stitched from several network buffers — into one independent Julia value.

### Streaming reads

For large payloads, read incrementally. `open(z, Val(:read))` returns a [`ZBytesReader`](@ref), a seekable `IO` cursor over the payload:

```julia
r = open(payload(s), Val(:read))
header = read(r, UInt32)
seek(r, 8)
rest = readavailable(r)
```

It supports `read`, `unsafe_read`, `readbytes!`, `seek`, `skip`, `position`, `bytesavailable`, and `eof`.

A second reader, `open(z, Val(:readslice))`, returns a [`ZBytesSliceReader`](@ref) that walks the payload's underlying slices and copies directly out of each one, avoiding the per-read crossing into the standard reader — worthwhile in tight read loops. It is a Julia-only performance variant.

### Iterating slices

A [`ZBytes`](@ref) may be assembled from several network buffers. Iterating one walks those slices in place:

```julia
for slice in payload(s)
    # `slice` is a view into one underlying slice
end
```

## Building payloads incrementally

[`ZBytesWriter`](@ref) assembles a payload piece by piece through the `IO` interface, then [`finish`](@ref)es into a [`ZBytes`](@ref). Prefer the do-block form: it finishes on success and cleans up the writer if the body throws, so the writer is always reclaimed:

```julia
bytes = open(ZBytes, Val(:write)) do w
    write(w, "header:")
    write(w, UInt8[0xde, 0xad])
end
put(pub, bytes)   # `bytes` (owned) is moved into `put`; do not reuse it afterward
```

`append!(w, z)` splices an existing [`ZBytes`](@ref) onto the writer's tail by *moving* it (zero-copy when possible); the appended [`ZBytes`](@ref) is dead afterward. A [`ZBytes`](@ref) that has been moved — by `append!`, [`finish`](@ref), or a send — must not be used again.

The bare [`ZBytesWriter`](@ref) constructor and `close`/[`finish`](@ref) are available when the do-block shape does not fit, cleaned up on the caller's task like [`ZBytes`](@ref): [`finish`](@ref) consumes the writer to produce the payload, and `close` discards an unfinished one.

## Slices

A [`ZSlice`](@ref) wraps Zenoh's owned or loaned contiguous byte slice. It appears as the element type when iterating a [`ZBytes`](@ref), and the materialize paths build one internally; you seldom construct one yourself. The buffer constructor mirrors [`ZBytes`](@ref): `ZSlice(buf)` defaults to zero-copy take-ownership and `ZSlice(buf; copy=true)` copies immediately. Unlike [`ZBytes`](@ref), an owned [`ZSlice`](@ref) carries a drop finalizer.

## Structured serialization

The codec encodes typed values into a portable framed layout that any Zenoh binding can decode. Use it when the receiver is a different language or you want a self-describing field sequence rather than a raw byte blob. It lives in the external `zenoh-ext` layer, so the structured codec evolves independently of raw byte handling.

The one-shot helpers cover the common case. They are public but unexported, so qualify them as `Zenoh.serialize` / `Zenoh.deserialize`:

```julia
# Serialize a Tuple and send it:
id16 = ntuple(i -> UInt8(i), 16)          # NTuple{16,UInt8} -> fixed-width [u8; 16]
put(pub, Zenoh.serialize((Int64(42), id16)))

# Deserialize in a callback (copy out before the callback returns):
function on_structured(s)
    seq, id = Zenoh.deserialize(Tuple{Int64, NTuple{16,UInt8}}, s)
end
```

For streaming reads, exhaustion checks, or interleaved field handling, drive the cursors directly. [`ZSerializer`](@ref) accumulates values and [`finish`](@ref)es into a payload; [`ZDeserializer`](@ref) reads them back **in write order**:

```julia
buf = open(ZSerializer) do ser
    write(ser, Int64(7))
    write(ser, UInt8[0xaa, 0xbb])   # length-prefixed Vector{UInt8}
end

d = ZDeserializer(buf)
n  = read(d, Int64)
bs = read(d, Vector{UInt8})
@assert Zenoh.is_done(d)
```

[`ZSerializer`](@ref) and [`ZDeserializer`](@ref) encapsulate [`ZBytes`](@ref): a deserializer is built from a [`Sample`](@ref) (or a [`ZBytes`](@ref)) and yields owned Julia values; a serializer's [`finish`](@ref) yields the payload you hand to [`put`](@ref). Normal structured use never names [`ZBytes`](@ref).

!!! warning "Read before the callback returns"
    A [`ZDeserializer`](@ref) reads in place against the borrowed payload buffer. Read or copy every value out before the originating [`Sample`](@ref) or callback returns — values left unread point at freed memory once the buffer is released.

### Supported types and the extension point

The codec wraps these value types today:

| Julia type | Wire shape |
| --- | --- |
| `Int64` | defined-endian `i64` |
| `UInt8` | `u8` |
| `Vector{UInt8}` | length-prefixed `Vec<u8>` |
| `NTuple{N,UInt8}` | fixed-width `[u8; N]`, no length prefix |
| `Tuple` | concatenation of its element encodings |

`Vector{UInt8}` carries a length prefix; `NTuple{N,UInt8}` is fixed-width. The two encode differently, so pick the one whose shape the peer expects.

`zenoh-ext` additionally defines `bool`, the full integer and float width family, `str`/`string`, and sequence-length framing, available to bind but not yet wrapped. Adding one is a single `write(::ZSerializer, ::T)` method plus a matching `read(::ZDeserializer, ::Type{T})`; the [Mapping section](#Mapping-to-Zenoh,-Rust,-and-C) shows the underlying binding pattern.

## API

### Raw payloads

```@docs
ZBytes
ZBytesReader
ZBytesSliceReader
ZBytesWriter
ZSlice
finish
```

### Reusable and borrowed payloads

The default [`ZBytes`](@ref) constructors allocate a fresh owned payload per call. For hot publish
loops, two paths reuse one payload across sends and drop that per-send allocation:

- **Copy path.** [`reusable_copy_bytes`](@ref) allocates one owned box; re-arm it each send with
  [`copy_bytes!`](@ref), which copies the bytes into zenoh's own storage. The source buffer is free
  to mutate the instant `copy_bytes!` returns. [`OwnedZBytes`](@ref) is the concrete type both
  return, for typing a held field.
- **Borrow (zero-copy) path.** [`lent_bytes`](@ref) hands zenoh your buffer in place with no copy,
  plus a deleter that fires once transmission completes. You own the buffer's lifetime: keep it alive
  and unmodified until the deleter fires. [`CompletionCell`](@ref) is a ready-made deleter that wakes
  the lending task when zenoh is done; [`completion_deleter`](@ref) and [`completion_ctx`](@ref)
  supply its `on_release` and `ctx`.

```@docs
reusable_copy_bytes
copy_bytes!
OwnedZBytes
lent_bytes
CompletionCell
completion_deleter
completion_ctx
```

### Structured codec

```@docs
ZSerializer
ZDeserializer
Zenoh.serialize
Zenoh.deserialize
Zenoh.is_done
```

## Mapping to Zenoh, Rust, and C

| Zenoh.jl | Zenoh abstraction | Rust | zenoh-c |
| --- | --- | --- | --- |
| [`ZBytes`](@ref) | [payload of a Value](https://zenoh.io/docs/manual/abstractions/#value) | [`zenoh::bytes::ZBytes`](https://docs.rs/zenoh/1.9.0/zenoh/bytes/struct.ZBytes.html) | [`z_owned_bytes_t` / `z_loaned_bytes_t`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [`ZBytesReader`](@ref) | byte read cursor | [`zenoh::bytes::ZBytesReader`](https://docs.rs/zenoh/1.9.0/zenoh/bytes/struct.ZBytesReader.html) | [`z_bytes_reader_t`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [`ZBytesWriter`](@ref) + [`finish`](@ref) | byte write cursor | [`zenoh::bytes::ZBytesWriter`](https://docs.rs/zenoh/1.9.0/zenoh/bytes/struct.ZBytesWriter.html) | [`z_owned_bytes_writer_t`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| `Base.iterate(::ZBytes)` | slice iterator | [`zenoh::bytes::ZBytesSliceIterator`](https://docs.rs/zenoh/1.9.0/zenoh/bytes/struct.ZBytesSliceIterator.html) | [`z_bytes_slice_iterator_t`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [`ZSlice`](@ref) | Slice | (internal) | [`z_owned_slice_t` / `z_loaned_slice_t`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [`ZSerializer`](@ref) / [`ZDeserializer`](@ref) / [`serialize`](@ref Zenoh.serialize) / [`deserialize`](@ref Zenoh.deserialize) | structured serialization ([zenoh-ext](https://docs.rs/zenoh-ext/1.9.0/zenoh_ext/index.html)) | [`z_serialize`](https://docs.rs/zenoh-ext/1.9.0/zenoh_ext/fn.z_serialize.html) / [`z_deserialize`](https://docs.rs/zenoh-ext/1.9.0/zenoh_ext/fn.z_deserialize.html) | [`ze_serializer_*` / `ze_deserializer_*`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [`Zenoh.is_done`](@ref) | deserializer exhaustion | — | `ze_deserializer_is_done` |

[`ZBytes`](@ref) is the Julia handle for the [`zenoh::bytes` module](https://docs.rs/zenoh/1.9.0/zenoh/bytes/index.html)'s payload type. The default `ZBytes(::Vector)` / `ZBytes(::String)` constructors map to C's `z_bytes_from_buf` / `z_bytes_from_str` (take-ownership with a deleter callback); `copy=true` maps to `z_bytes_copy_from_buf`; `ZBytes(::Symbol)` maps to `z_bytes_from_static_str`. [`ZBytesReader`](@ref) and [`ZBytesWriter`](@ref) are the Julia `IO`-conforming mirrors of Rust's `std::io::Read` + `std::io::Seek` and `std::io::Write` cursors over a payload. The structured codec is the front-end to `zenoh-ext`: `write`/`read` bind one method per type onto `ze_serializer_serialize_*` / `ze_deserializer_deserialize_*`.

The codec's per-type wrapping is also its extension point. The `bool`, float, full int/uint width, and `str`/`string` functions are bound in `gen/LibZenohC.jl`; wrapping one adds a `write` method that loans the serializer into `ze_serializer_serialize_*` and a `read` method that calls `ze_deserializer_deserialize_*` into an output `Ref`, each through the internal loan/pointer/result helpers:

```julia
function Base.write(s::ZSerializer, x::Float64)
    Zenoh._handle_result(Zenoh.LibZenohC.ze_serializer_serialize_double(Zenoh._ser_loan(s), x))
    return nothing
end
function Base.read(d::ZDeserializer, ::Type{Float64})
    out = Ref{Float64}()
    GC.@preserve d Zenoh._handle_result(
        Zenoh.LibZenohC.ze_deserializer_deserialize_double(Zenoh._deser_ptr(d), out))
    return out[]
end
```

The equivalence is exact except where named below.

!!! note "Value is a call-site pair"
    Zenoh's [Value](https://zenoh.io/docs/manual/abstractions/#value) bundles a payload and an [Encoding](@ref). Zenoh.jl has no `Value` type: the payload is a [`ZBytes`](@ref), the encoding is a separate [`Encoding`](@ref Encoding), and you pass them independently to [`put`](@ref) or [`reply`](@ref). A Value exists only as the pair of arguments at the call site.

!!! note "Ownership is a type parameter"
    Rust and C present an owned `ZBytes` (`z_owned_bytes_t`) and a separate loaned reference (`z_loaned_bytes_t`). Zenoh.jl folds both into one parametric [`ZBytes`](@ref) whose `R` type parameter selects the owned or loaned C form, so ownership state is a Julia type parameter rather than a distinct type. [`ZSlice`](@ref) does the same for slices.

!!! warning "Structured codec is zenoh-ext, not core"
    [`ZSerializer`](@ref) / [`ZDeserializer`](@ref) and the [`serialize`](@ref Zenoh.serialize) / [`deserialize`](@ref Zenoh.deserialize) helpers wrap the external [`zenoh-ext`](https://docs.rs/zenoh-ext/1.9.0/zenoh_ext/index.html) crate (the `ze_` C prefix), not core Zenoh. They are layered above [`ZBytes`](@ref): a one-shot `Zenoh.serialize(x)` runs through a [`ZSerializer`](@ref) open/[`finish`](@ref) cycle (it does not bind C's one-shot `ze_serialize_*`).

Further divergences:

- **No GC finalizer on owned [`ZBytes`](@ref).** Cleanup runs on the caller's task by move-on-send or explicit `close` — because `z_bytes_drop` invokes the buffer deleter, and dropping an SHM-backed payload off the GC thread corrupts SHM bookkeeping. [`ZSlice`](@ref) *does* finalize, since slices are not SHM-backed.
- **[`ZBytesSliceReader`](@ref) has no Rust or C counterpart.** It is a Julia-only `IO` reader (`open(z, Val(:readslice))`) that copies directly out of each slice's data pointer, distinct from the standard [`ZBytesReader`](@ref) (`open(z, Val(:read))`) that calls `z_bytes_reader_read` per read.
- **No `OptionZBytes`.** Rust's [`OptionZBytes`](https://docs.rs/zenoh/1.9.0/zenoh/bytes/struct.OptionZBytes.html) ergonomic optional-payload wrapper has no Julia equivalent; Julia uses a [`ZBytes`](@ref), or `nothing` where an optional payload is needed.
- **The codec handles are not `<: IO`.** [`ZSerializer`](@ref) / [`ZDeserializer`](@ref) sit off the `IO` hierarchy so `read`/`write` always run the framed-codec methods. Were they `<: IO`, Julia's generic `write(io, x) = unsafe_write(io, Ref(x), sizeof(x))` fallback would emit raw isbits bytes. Contrast [`ZBytesWriter`](@ref) / [`ZBytesReader`](@ref), which *are* `<: IO` and move raw bytes.
- **Codec value-type subset.** Only `Int64`, `UInt8`, `Vector{UInt8}`, `NTuple{N,UInt8}`, and `Tuple` are wrapped. C/zenoh-ext additionally offer `bool`, floats, the full int/uint width family, `str`/`string`, and sequence-length framing — bound but not yet wrapped (see the extension point above).
- **`serialize`, `deserialize`, and `is_done` are public but unexported.** Reach them as `Zenoh.serialize` / `Zenoh.deserialize` / `Zenoh.is_done`. Only [`ZSerializer`](@ref) and [`ZDeserializer`](@ref) are exported from the codec.
- **[`finish`](@ref) is one name, two methods.** [`finish(::ZBytesWriter)`](@ref) extracts a payload from the byte writer; [`finish(::ZSerializer)`](@ref) extracts one from the structured serializer. Both consume (move) their handle.