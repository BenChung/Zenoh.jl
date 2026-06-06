```@meta
CurrentModule = Zenoh
```

# Shared Memory

Shared memory (SHM) is Zenoh's same-host zero-copy transport: the payload lives in a POSIX shared-memory segment, and a receiver on the same machine reads it in place — zero network copy. Zenoh allocates the buffer from a *provider*, the publisher fills it, and the receiver gets a reference to that same segment — the bytes never leave it. Zenoh's SHM subsystem was [heavily reworked in 1.0](https://zenoh.io/docs/migration_1.0/c_pico/) with reference-counted buffers, dynamic transport negotiation, and aligned allocations.

Zenoh.jl exposes SHM through one typed handle, [`ZRef`](@ref). The headline path is two calls: open a session with SHM enabled, then `zref(session, T)`, which allocates from shared memory when it is available and falls back to the Julia heap otherwise — the same `ZRef{T}` either way, with no provider, buffer type, or SHM-specific call to name. Below that sit the receive-side views ([`borrow`](@ref), [`with_memory`](@ref)) and, for direct control, the provider and buffer types ([`ShmProvider`](@ref), [`alloc`](@ref), [`ShmBufMut`](@ref)).

!!! warning "Unstable upstream API"
    Zenoh's SHM API is documented as unstable, and [`cleanup_orphaned_shm_segments`](@ref) is Linux-only. The Zenoh.jl surface is stable, but the semantics it sits on may shift across Zenoh releases.

## Enabling shared memory

SHM requires both ends to opt in. The publisher allocates from a provider; the receiver maps incoming segments only after opening with a [`ShmClientStorage`](@ref). A session opened without `shm_clients` reports [`shm_state`](@ref) `:none` and quietly uses the network for every payload.

Pass [`default_shm_clients`](@ref) to [`open`](@ref Base.open(::Zenoh.Config)) on both ends:

```julia
using Zenoh

sub = open(Config(); shm_clients = default_shm_clients())
pub = open(Config(); shm_clients = default_shm_clients(), wait_for_shm = true)
```

The provider warms up shortly after the session connects, so `shm_state` at `open` may be `:initializing` or `:unavailable` before settling (typically within a second or two). Two controls handle the warm-up:

- `wait_for_shm = true` (or a timeout in seconds) on `open` blocks until the provider is ready.
- [`shm_ready`](@ref) re-probes a live session and adopts the provider the moment it becomes usable.

```julia
if shm_ready(pub)
    @info "SHM ready" state = shm_state(pub) capable = shm_capable(pub)
end
```

[`shm_capable`](@ref) reports whether a provider is cached — true exactly when `zref(session, T)` will allocate from SHM.

## The transparent path: `zref(session, T)`

[`zref`](@ref) builds a typed handle over a payload buffer for an `isbitstype` `T`. Given a session it picks the backing for you: a shared-memory segment when the session has a provider, the Julia heap otherwise. Either way the handle is the same: write with `r[] = x`, read with `r[]`, then [`put`](@ref) it.

```julia
r = zref(pub, NTuple{4, Float64})   # writable handle into an SHM segment (or the Julia heap)
r[] = (1.0, 2.0, 3.0, 4.0)
put(pub, Keyexpr("demo/shm"), r)    # hands the buffer off as the payload
```

`put` takes ownership of the `ZRef` and consumes it; the payload travels without a copy. Reusing a consumed `ZRef` throws.

If the provider has not been obtained yet, `zref(session, T)` lazily attempts the obtain, so the fast path self-heals once SHM becomes ready without an explicit [`shm_ready`](@ref) call. A full segment surfaces as a [`ShmAllocError`](@ref), which degrades to the Julia heap; register `on_shm_alloc_error` at `open` to escalate that failure instead of degrading silently.

!!! note "`T` must be isbits, and zero-copy needs alignment"
    `zref` rejects any `T` that is not `isbitstype` — a type holding Julia references would serialize live heap pointers. `zref(session, T)` requests `T`-alignment for the segment; SHM is the only transport that carries the sender's alignment through to the receiver, so it is the only one guaranteed to be read in place. Network paths read in place only when the slice is already `T`-aligned, and copy otherwise.

## The receive side

A subscriber reconstructs the value with the same [`zref`](@ref), passing the [`Sample`](@ref). The callback form of [`open`](@ref Base.open(::Zenoh.Config)) delivers each sample to your function:

```julia
open(sub, Keyexpr("demo/shm")) do sample
    r = zref(sample, NTuple{4, Float64})
    @info "received" value = r[] borrowed = isborrowed(r)
end
```

`zref(sample, T)` resolves through three tiers, picking the fastest the payload allows:

1. **SHM** — the payload is a shared segment, contiguous and sender-aligned: read in place, zero copy.
2. **Contiguous network slice** — a single network slice that happens to be `T`-aligned: read in place, zero copy.
3. **Copy** — fragmented or misaligned: the bytes are copied once into an aligned box.

[`isborrowed`](@ref) tells the two apart: `true` for tiers 1 and 2 (a zero-copy view), `false` when a copy was materialized. Use it to assert the fast path held.

!!! warning "A borrowed view must not escape the callback"
    A borrowed [`ZRef`](@ref), [`Borrowed`](@ref), or [`PayloadView`](@ref) pins the sample and is valid only while the sample is reachable. Read or copy the value out before the callback returns. `as_memory(payload(sample), T)` copies the payload into an owned `Memory{T}` you can keep; `collect` on a `Borrowed` does the same.

For byte-oriented access scoped to a block, [`borrow`](@ref) and [`with_memory`](@ref) hand you a [`Borrowed{T}`](@ref) view — `b[]` or `b.field` for a struct, `b[i]`/iteration for a buffer. `with_memory` closes the borrow when its function returns, so an escaped view raises a catchable [`BorrowError`](@ref) on its next use:

```julia
open(sub, Keyexpr("demo/shm")) do sample
    total = with_memory(sample, Float64) do b
        sum(b)              # zero-copy on the SHM / aligned-slice path
    end
    @info "sum" total
end
```

The lower-level [`with_payload_memory`](@ref) and the validated [`with_payload_memory_checked`](@ref) variants are covered under [Payloads & Serialization](@ref). The `unsafe_*` variants ([`unsafe_with_memory`](@ref), [`unsafe_memory`](@ref)) drop the per-access checks for known-correct hot paths.

## Direct provider and buffer control

For raw byte buffers, control over allocation policy, or capacity inspection, work with a provider directly. Two kinds exist, both [`AbstractShmProvider`](@ref):

- [`ShmProvider`](@ref)`(size)` — a standalone POSIX provider of fixed byte capacity.
- [`obtain_shm_provider`](@ref)`(session)` — the session's own provider (a [`SharedShmProvider`](@ref)), the same one `zref(session, T)` uses.

[`alloc`](@ref) returns a writable [`ShmBufMut`](@ref); fill it, then turn it into a payload with `ZBytes`, which hands the buffer off as the message body:

```julia
prov = obtain_shm_provider(pub)         # SharedShmProvider
@info "available bytes" available(prov)

buf = alloc(prov, 1024; align = 8, blocking = true)   # ShmBufMut
copyto!(buf, rand(UInt8, 1024))
put(pub, Keyexpr("demo/raw"), ZBytes(buf))            # hands the buffer off as the payload
```

`alloc` has two modes: the default allocates immediately and throws [`ShmAllocError`](@ref) on a full segment; `blocking = true` first garbage-collects and defragments, then waits for space. `align` requests a power-of-2 alignment and selects the aligned allocator; an invalid layout throws [`ShmLayoutError`](@ref).

[`available`](@ref), [`defragment`](@ref), and [`garbage_collect`](@ref) inspect and maintain a provider's free space, each returning a size in bytes. On the receive side, [`as_shm`](@ref) views a received `ZBytes` as a [`ShmBuf`](@ref) for a zero-copy read, and [`is_shm`](@ref) tests SHM backing without obtaining the buffer; [`data`](@ref) exposes a buffer's bytes as a `Memory{UInt8}`.

!!! warning "Orphaned segments are not freed on close"
    POSIX `/dev/shm` segments left by a process that exited without releasing them are reclaimed only by [`cleanup_orphaned_shm_segments`](@ref) (Linux) or process-level cleanup — never when the provider is released or the session closes. The session obtains its provider at most once per lifetime, so it materializes only one set of segments.

```julia
cleanup_orphaned_shm_segments()   # Linux: reclaim segments left by dead processes
```

## Public API

### Session SHM controls

```@docs
shm_state
shm_capable
shm_ready
```

### Providers and allocation

```@docs
AbstractShmProvider
ShmProvider
SharedShmProvider
obtain_shm_provider
alloc
available
defragment
garbage_collect
```

### Buffers and payload bridge

```@docs
ShmBufMut
ShmBuf
data
as_shm
is_shm
```

### Client storage and maintenance

```@docs
ShmClientStorage
default_shm_clients
cleanup_orphaned_shm_segments
```

### Errors

```@docs
ShmAllocError
ShmLayoutError
```

### Typed handles and views

```@docs
ZRef
zref
isborrowed
borrow
Borrowed
BorrowError
PayloadView
GuardedPayloadView
as_memory
with_memory
with_payload_memory
with_payload_memory_checked
unsafe_with_memory
unsafe_memory
put(::Zenoh.Publisher, ::Zenoh.ZRef)
```

## Mapping to Zenoh, Rust, and C

| Zenoh.jl | Zenoh abstraction | Rust | zenoh-c |
| --- | --- | --- | --- |
| [`ShmProvider`](@ref)`(size)` | [ShmProvider](https://docs.rs/zenoh/1.9.0/zenoh/shm/struct.ShmProvider.html) (POSIX backend) | [`ShmProvider<PosixShmProviderBackend>`](https://docs.rs/zenoh/1.9.0/zenoh/shm/struct.ShmProvider.html) | `z_posix_shm_provider_new` |
| [`SharedShmProvider`](@ref) / [`obtain_shm_provider`](@ref) | session-derived SHM provider | session/global provider | `z_obtain_shm_provider` |
| [`alloc`](@ref)`(p, n; align, blocking)` | provider `alloc` + [AllocPolicy](https://docs.rs/zenoh/1.9.0/zenoh/shm/trait.AllocPolicy.html) | `ShmProvider::alloc(...).with_policy` | `z_shm_provider_alloc` / `_aligned` / `_gc_defrag_blocking` / `_gc_defrag_blocking_aligned` |
| [`available`](@ref) / [`defragment`](@ref) / [`garbage_collect`](@ref) | provider inspection/maintenance | `ShmProvider::available` / `defragment` / `garbage_collect` | `z_shm_provider_available` / `_defragment` / `_garbage_collect` |
| [`ShmBufMut`](@ref) / [`ShmBuf`](@ref) | [ZShmMut](https://docs.rs/zenoh/1.9.0/zenoh/shm/struct.ZShmMut.html) / [ZShm](https://docs.rs/zenoh/1.9.0/zenoh/shm/struct.ZShm.html) | `ZShmMut` / `ZShm` | `z_owned_shm_mut_t` / `z_owned_shm_t` / `z_loaned_shm_t` |
| `ShmBuf(::ShmBufMut)` | freeze mutable → immutable | `ZShm: From<ZShmMut>` | `z_shm_from_mut` |
| `ZBytes(::ShmBufMut)` / `ZBytes(::ShmBuf)` | SHM buffer → payload | bytes from SHM | `z_bytes_from_shm_mut` / `z_bytes_from_shm` |
| [`as_shm`](@ref) / [`is_shm`](@ref) | view payload as SHM | bytes as loaned SHM | `z_bytes_as_loaned_shm` |
| [`shm_state`](@ref) symbols | [ShmProviderState](https://docs.rs/zenoh/1.9.0/zenoh/shm/index.html) | `ShmProviderState` | `z_shm_provider_state` |
| [`ShmAllocError`](@ref) / [`ShmLayoutError`](@ref) | alloc / layout failures | `ZAllocError` / `ZLayoutError` | `z_alloc_error_t` / `z_layout_error_t` |
| [`ShmClientStorage`](@ref) / [`default_shm_clients`](@ref) | [ShmClientStorage](https://docs.rs/zenoh/1.9.0/zenoh/shm/struct.ShmClientStorage.html) | `ShmClientStorage` | `z_owned_shm_client_storage_t` / `z_shm_client_storage_new_default` |
| [`open`](@ref Base.open(::Zenoh.Config))`(cfg; shm_clients=...)` | session with SHM clients | `Session::open` with client storage | `z_open_with_custom_shm_clients` |
| [`cleanup_orphaned_shm_segments`](@ref) | [orphan-segment cleanup](https://docs.rs/zenoh/1.9.0/zenoh/shm/index.html) (Linux) | `cleanup_orphaned_shm_segments` | `zc_cleanup_orphaned_shm_segments` |
| [`ZRef`](@ref) / [`zref`](@ref) | — | — | — |

The provider, buffer, client-storage, error, and inspection types map one-to-one onto the [`zenoh::shm`](https://docs.rs/zenoh/1.9.0/zenoh/shm/index.html) module and its [zenoh-c](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) `z_`-prefixed counterparts. The equivalence is exact for these, with a few precise narrowings.

[`alloc`](@ref) folds four distinct C entry points — and Rust's `AllocBuilder` policy chain — into one call governed by two keywords. Only two policies are reachable: the default (Rust `JustAlloc`) and `blocking = true` (Rust `GarbageCollect` + `Defragment` + `BlockOn`). The intermediate `GarbageCollect`-only, `Defragment`-only, and non-blocking `BlockOn` policies have no Julia surface. [`ShmProvider`](@ref)`(size)` takes only a size — `z_posix_shm_provider_new` with an implied layout — rather than an explicit `z_memory_layout_t`; alignment is expressed per allocation through `align` instead. The owned/loaned/moved distinction is internal: [`ShmBufMut`](@ref) and [`ShmBuf`](@ref) (parameterized by backing) are the only user-facing buffer types, and finalizers plus a `consumed` flag enforce drop and move-once invariants, so you never name `z_loan`/`z_move`/`z_drop`.

A few capabilities present upstream are not surfaced from Julia: custom [`ShmClient`](https://docs.rs/zenoh/1.9.0/zenoh/shm/trait.ShmClient.html) protocol implementations ([`default_shm_clients`](@ref) is the only client set), an explicit `MemoryLayout` type, and Zenoh's typed-SHM `Typed<T>` wrapper — Zenoh.jl provides typed access through its own [`ZRef`](@ref)`{T}` / [`Borrowed`](@ref)`{T}` over raw byte buffers.

!!! note "Zenoh.jl extension: `ZRef` and the transparent session path"
    [`ZRef`](@ref) and [`zref`](@ref) have no Zenoh or zenoh-c counterpart. They unify four backings — a Julia `Ref` box, a [`ShmBufMut`](@ref), a [`ShmBuf`](@ref), and a contiguous network view — behind one typed handle so the authoring, send, and receive API is identical with or without SHM. The transparent session policy — `zref(session, T)` using SHM when ready and degrading to the Julia heap on a full segment or no provider, plus the `on_shm_alloc_error` escalation hook — is a Zenoh.jl construct. So is the session-level lifecycle: [`shm_state`](@ref)'s `:none` and `:unavailable` symbols (Zenoh's `ShmProviderState` has only `ready`/`initializing`/`disabled`/`error`), [`shm_capable`](@ref), [`shm_ready`](@ref), the warm-up wait, lazy self-healing obtain, and the one-obtain-per-session leak guard are all Zenoh.jl bookkeeping over `z_obtain_shm_provider`.

See [Payloads & Serialization](@ref) for the full view-and-borrow API, [Sessions & Configuration](@ref) for `open`, and [Publish & Subscribe](@ref) for `put`/`declare`.
