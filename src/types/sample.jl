# Sample — owned/loaned/reusable wrappers around `z_owned_sample_t`. Delivered
# by subscribers and queries; accessors (below) read the underlying loaned form
# via `_loaned_sample`, dispatched on the abstract supertype so all three
# representations share one set of accessors.
abstract type AbstractSample end

# Per-occupant recycle epoch for the in-place-reused sample sources (the iterate
# box and SampleHolder). One cell per source; its `gen` is bumped — never
# reallocated, so zero per-item allocation — each time the source drops its
# occupant and refills. A zero-copy view over such a source captures `(cell, gen)`
# by value; `_check_token` fails once the cell's gen has moved on, turning the
# otherwise-silent use-after-recycle into a catchable `BorrowError`. A monotone
# counter (not a re-armed bool) is ABA-safe: a stale view's captured gen can never
# match again.
mutable struct _RecycleEpoch
    gen::UInt64
end
_RecycleEpoch() = _RecycleEpoch(UInt64(1))
@inline _bump!(e::_RecycleEpoch) = (e.gen += UInt64(1); nothing)

# Views over already-safe sources (owned/loaned samples) carry `nothing` and skip
# the check (a not-taken branch — zero overhead, no behavior change). `BorrowError`
# is defined in types/zref.jl (included after this file); it is referenced here
# only in the late-bound throw body, resolved at call time.
@inline _check_token(::Nothing) = nothing
@inline function _check_token(t::Tuple{_RecycleEpoch,UInt64})
    t[1].gen == t[2] || throw(BorrowError(
        "received zero-copy view used after its sample slot was recycled (iterate \
         advanced, or recv!/tryrecv! refilled the holder); copy out with \
         `collect`/`as_memory`, or take an owned sample with `take!`/`:keep_all`"))
    return nothing
end

"""
    Sample

A received sample. The owned form (from `take!` / `:keep_all` / `get`) owns its
handle and drops it on GC, so it may be held arbitrarily long; the loaned form
(from `sample(::Reply)`) borrows from `owner`.
"""
struct Sample{S <: Union{Base.RefValue{LibZenohC.z_owned_sample_t},
                         Ptr{LibZenohC.z_loaned_sample_t}}} <: AbstractSample
    s::S
    # For the loaned form, `owner` holds the value `s` borrows from (e.g.
    # the Reply behind `sample(::Reply)`) so the underlying sample outlives
    # this wrapper. `nothing` for the owned form, which owns `s` directly.
    owner::Any
end
Sample(p::Ptr{LibZenohC.z_loaned_sample_t}, owner=nothing) =
    Sample{Ptr{LibZenohC.z_loaned_sample_t}}(p, owner)
function Sample(r::Base.RefValue{LibZenohC.z_owned_sample_t})
    finalizer(x -> LibZenohC.z_sample_drop(_move(x)), r)
    return Sample{Base.RefValue{LibZenohC.z_owned_sample_t}}(r, nothing)
end

"""
    SampleHolder()

A reusable, caller-owned sample slot for zero-allocation receiving. Allocate one
and refill it in place with [`recv!`](@ref)/`tryrecv!`, or let `for s in sub`
reuse one internally. Holds one owned sample at a time (dropped on the next
`recv!` and on GC). The contained sample is valid only until the next refill —
don't stash it or anything derived from it (`payload`, `keyexpr`, …) past then.
"""
mutable struct SampleHolder <: AbstractSample
    s::Base.RefValue{LibZenohC.z_owned_sample_t}
    epoch::_RecycleEpoch     # bumped on each in-place refill; views capture it to detect staleness
end
function SampleHolder()
    r = Ref{LibZenohC.z_owned_sample_t}()
    # Gravestone init so an unfilled/finished holder drops cleanly (drop of a
    # null owned sample is a no-op).
    LibZenohC.z_internal_sample_null(r)
    h = SampleHolder(r, _RecycleEpoch())
    # Bump before the finalizer drop too, for the same reason as the iterate box:
    # a view built via the internal `_borrow_sample(h.s, h.epoch)` pins h.s/h.epoch
    # but not `h`, so a finalize-time drop must invalidate it. (The public `payload(h)`
    # path pins `h` itself, blocking this finalizer while a view is live; this covers
    # the rest, keeping the every-drop-bumps invariant uniform.)
    finalizer(hh -> (_bump!(hh.epoch); LibZenohC.z_sample_drop(_move(hh.s))), h)
    return h
end
# Drop the holder's current occupant (no-op on the gravestone), readying it for
# the next in-place refill. Bump the epoch FIRST so any view still held over the
# previous occupant fails its `_check_token` rather than reading the recycled slot.
@inline _drop_current!(h::SampleHolder) = (_bump!(h.epoch); LibZenohC.z_sample_drop(_move(h.s)))

# Non-finalized owned `Sample` borrowing a caller-managed box (the iterate
# reusable box owns the drop). Concrete `Sample` so it satisfies `::Sample` call
# sites; valid only while the box holds this occupant. The box's recycle `epoch`
# rides in `owner` (otherwise `nothing` for this form), so views derived from the
# sample capture it and detect a later in-place recycle.
@inline _borrow_sample(box::Base.RefValue{LibZenohC.z_owned_sample_t}, epoch::_RecycleEpoch) =
    Sample{Base.RefValue{LibZenohC.z_owned_sample_t}}(box, epoch)

# Recycle token for a view's backing source: a `(cell, gen)` pair for the in-place
# reusable sources (iterate box / SampleHolder), `nothing` for owned/loaned samples
# (whose views pin the sample and are safe to hold). Recovered from `owner` without
# changing its role as the GC pin; owned (`owner=nothing`) and loaned (`owner=Reply`)
# forms both yield `nothing`.
@inline _token(s::Sample) = (o = getfield(s, :owner); o isa _RecycleEpoch ? (o, o.gen) : _token_owner(o))
@inline _token(h::SampleHolder) = (h.epoch, h.epoch.gen)
@inline _token(z::ZBytes) = _token_owner(getfield(z, :owner))
# Resolve a captured recycle token from a view's `owner`, whatever its kind: a reusable
# source forwards its token; anything else (owned/loaned handle, `nothing`) yields none.
# The `Reply` method is added in messaging/channel.jl (defined later), so a view over a
# ReplyHolder-borrowed reply's payload is staleness-checked just like one over a Sample.
@inline _token_owner(@nospecialize(o)) = nothing
@inline _token_owner(o::Sample) = _token(o)
@inline _token_owner(o::SampleHolder) = _token(o)

_loaned_sample(s::Sample{Ptr{LibZenohC.z_loaned_sample_t}}) = s.s
_loaned_sample(s::Sample{Base.RefValue{LibZenohC.z_owned_sample_t}}) = _loan(s.s)
_loaned_sample(h::SampleHolder) = _loan(h.s)

"""
    timestamp(s::AbstractSample) -> Union{ZTimestamp, Nothing}

The sample's [`ZTimestamp`](@ref) (NTP64 time plus the generating node's id),
or `nothing` when the sample carries none. The first Zenoh router to receive a
put stamps it; samples that were never routed through a timestamping node arrive
unstamped.
"""
function timestamp(s::AbstractSample)
    ts = LibZenohC.z_sample_timestamp(_loaned_sample(s))
    if ts == C_NULL
        return nothing
    else
        ZTimestamp(ts)
    end
end

"""
    payload(s::AbstractSample) -> ZBytes

The sample's data as a loaned `ZBytes` borrowing from `s`, so the bytes stay
valid for as long as the returned value is reachable. Pair with [`encoding`](@ref)
to interpret them.
"""
function payload(s::AbstractSample)
    # Pass `s` as owner so the returned (loaned) ZBytes keeps the sample —
    # and thus the borrowed buffer — alive for as long as it is reachable.
    return ZBytes(LibZenohC.z_sample_payload(_loaned_sample(s)), s)
end

"""
    kind(s::AbstractSample) -> SampleKind

The sample's [`SampleKind`](@ref) singleton: `SampleKinds.PUT` for a
value-carrying put, `SampleKinds.DELETE` for a key deletion. Compare with `===`.
"""
kind(s::AbstractSample) = _sample_kind_from_raw(LibZenohC.z_sample_kind(_loaned_sample(s)))

"""
    keyexpr(s::AbstractSample) -> String

The sample's key expression, copied into a freshly allocated `String`. On decode
hot paths that only hash or compare the key, [`keyexpr_view`](@ref) avoids this
allocation.
"""
function keyexpr(s::AbstractSample)
    # The view string borrows from the sample; GC.@preserve keeps `s` alive
    # until unsafe_string has copied the bytes out.
    GC.@preserve s begin
        ke = LibZenohC.z_sample_keyexpr(_loaned_sample(s))
        view = Ref{LibZenohC.z_view_string_t}()
        LibZenohC.z_keyexpr_as_view_string(ke, view)
        loaned = LibZenohC.z_view_string_loan(view)
        return unsafe_string(LibZenohC.z_string_data(loaned), LibZenohC.z_string_len(loaned))
    end
end

"""
    keyexpr_view(f, s::AbstractSample)

Call `f(ptr::Ptr{UInt8}, len::Int)` with a zero-copy view of the sample's
keyexpr bytes for the duration of `f`, **without** allocating the `String` that
[`keyexpr`](@ref) copies out. `s` (and thus the borrowed keyexpr) is kept alive
across `f` via `GC.@preserve`; the pointer is valid only within `f`. For decode
hot paths that hash/compare the keyexpr bytes and only materialize a `String` on
a cold miss.
"""
@inline function keyexpr_view(f, s::AbstractSample)
    GC.@preserve s begin
        ke = LibZenohC.z_sample_keyexpr(_loaned_sample(s))
        view = Ref{LibZenohC.z_view_string_t}()
        LibZenohC.z_keyexpr_as_view_string(ke, view)
        GC.@preserve view begin
            loaned = LibZenohC.z_view_string_loan(view)
            return f(Ptr{UInt8}(LibZenohC.z_string_data(loaned)),
                     Int(LibZenohC.z_string_len(loaned)))
        end
    end
end

"""
    attachment(s::AbstractSample) -> Union{ZBytes, Nothing}

The sample's attachment as a loaned `ZBytes` borrowing from `s`, or `nothing`
when the sample carries no attachment.
"""
function attachment(s::AbstractSample)
    a = LibZenohC.z_sample_attachment(_loaned_sample(s))
    if a == C_NULL
        return nothing
    else
        return ZBytes(a, s)
    end
end

"""
    congestion_control(s::AbstractSample) -> CongestionControl

The `CongestionControl` QoS the sample was published with.
"""
congestion_control(s::AbstractSample) = _congestion_control_from_raw(LibZenohC.z_sample_congestion_control(_loaned_sample(s)))

"""
    priority(s::AbstractSample) -> Priority

The `Priority` QoS the sample was published with.
"""
priority(s::AbstractSample) = _priority_from_raw(LibZenohC.z_sample_priority(_loaned_sample(s)))

"""
    express(s::AbstractSample) -> Bool

Whether the sample was sent express, bypassing the batching layer for lower
latency.
"""
express(s::AbstractSample) = LibZenohC.z_sample_express(_loaned_sample(s))

"""
    reliability(s::AbstractSample) -> Reliability

The `Reliability` QoS the sample was published with.
"""
reliability(s::AbstractSample) = _reliability_from_raw(LibZenohC.z_sample_reliability(_loaned_sample(s)))

"""
    encoding(s::AbstractSample) -> Encoding

The `Encoding` describing the format of the sample's [`payload`](@ref).
"""
function encoding(s::AbstractSample)
    return _from_loaned_encoding(LibZenohC.z_sample_encoding(_loaned_sample(s)))
end

export Sample, SampleHolder, payload, keyexpr, keyexpr_view, encoding, attachment, timestamp, kind,
    priority, congestion_control, express, reliability
