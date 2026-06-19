# Publisher + put + delete!. The session-level `put(s::Session, k, payload; …)`
# and the long-lived `Publisher` form share the per-call options (timestamp,
# encoding, attachment) but differ on QoS fields — see `_make_put_opts`.
# `_shm_zbytes` routes the optional `shm=` kwarg through to an
# SHM-backed ZBytes; specializations live in shm.jl.
#
# `Publisher(s, k; …)` is a *routing* constructor: a Julia constructor is just
# a function and need not call `new` or return its own type. When an advanced
# feature keyword is present it returns an `AdvancedPublisher` (defined in
# features/advanced_pubsub.jl); otherwise the plain `Publisher`. Routing keys on
# keyword *presence* (a property of `typeof(kwargs)`), so the return type is
# resolved by ordinary inference, not by value-level constant propagation — see
# the advanced-pubsub proposal §3.2.

# Common abstract supertype for the plain and advanced publishers. Concrete so
# clients stay type-stable: `Publisher` remains a concrete type, and a client
# that wants to hold either kind parameterizes (`struct Foo{P<:AbstractPublisher}
# pub::P end`) rather than storing the abstract field directly.
"""
    abstract type AbstractPublisher

Supertype of the plain [`Publisher`](@ref) and the `AdvancedPublisher`. Each
subtype stays concrete, so a client that holds either kind parameterizes on
`P<:AbstractPublisher` (`struct Foo{P<:AbstractPublisher}; pub::P; end`) and
keeps its field type-stable.
"""
abstract type AbstractPublisher end

"""
    Publisher <: AbstractPublisher

Long-lived publisher declared on a [`Keyexpr`](@ref), wrapping an owned
`z_owned_publisher_t` (the `keyexpr` field pins the key expression alive for
the C handle's lifetime). QoS — congestion control, priority, express,
reliability, allowed destination — is fixed at declare time, so [`put`](@ref)
and [`delete!`](@ref) on a publisher carry only per-call timestamp, encoding,
and attachment.

Build one with `Publisher(s::Session, k::Keyexpr; …)`, publish with
`put(p, payload; …)`, and release the C handle with `close(p)` (a finalizer
drops the handle as a GC safety net). For the convenience one-shot path that
publishes without a long-lived handle, see `put(s::Session, k, payload; …)`.
"""
mutable struct Publisher <: AbstractPublisher
    pub::Base.RefValue{LibZenohC.z_owned_publisher_t}
    keyexpr::AbstractKeyexpr # we have to keep this for GC
    closed::Bool
    # Held by `close` (which undeclares → gravestones `pub`) AND by every op that loans `pub`
    # (`put`/`delete!`/`matching_status`/`MatchingListener`), so a concurrent `close` can't move the
    # handle to a gravestone mid-loan (a null-deref / use-after-free on a libzenoh thread). Any new
    # op that loans `pub` MUST take this lock. `ReentrantLock`, not `SpinLock`: `z_publisher_put` can
    # block under `congestion_control = BLOCK`, so a waiter must yield; uncontended it is alloc-free.
    lock::Base.ReentrantLock
    # Low-level inner constructor: wraps an already-declared owned handle.
    Publisher(pub::Base.RefValue{LibZenohC.z_owned_publisher_t}, k::Keyexpr) =
        new(pub, k, false, Base.ReentrantLock())
end

# Advanced-only publisher keywords. Presence of any routes `Publisher(s, k; …)`
# to `AdvancedPublisher`. Kept in sync with the `Advanced*` constructors in
# features/advanced_pubsub.jl.
const ADVANCED_PUB_KW = (:cache, :miss_detection, :detection)

# Type-level "did the caller pass an advanced keyword?" — `names` is bound from
# the kwargs NamedTuple type, so this folds to a constant at inference time.
@inline _wants_advanced(::NamedTuple{names}, ::Val{adv}) where {names, adv} =
    any(in(adv), names)

# Build a z_publisher_options_t from the shared QoS kwargs. Returns
# `(opts, enc_ref)`; the caller GC.@preserves `enc_ref` (a moved-owned encoding)
# across the declare. Shared by the plain `Publisher` and `AdvancedPublisher`
# (which copies the value into its nested `publisher_options` field).
function _make_publisher_opts(;
        encoding::Union{Nothing, Encoding, AbstractString, Base.MIME} = nothing,
        congestion_control::Union{Nothing, CongestionControl}         = nothing,
        priority::Union{Nothing, Priority}                            = nothing,
        express::Union{Nothing, Bool}                                 = nothing,
        reliability::Union{Nothing, Reliability}                      = nothing,
        allowed_destination::Union{Nothing, Locality}                 = nothing)
    opts = Ref{LibZenohC.z_publisher_options_t}()
    LibZenohC.z_publisher_options_default(opts)
    optsP = Base.unsafe_convert(Ptr{LibZenohC.z_publisher_options_t}, opts)

    enc_ref = isnothing(encoding) ? nothing : _to_owned_encoding(_as_encoding(encoding))
    isnothing(enc_ref)             || (optsP.encoding            = _move(enc_ref))
    isnothing(congestion_control)  || (optsP.congestion_control  = _raw(congestion_control))
    isnothing(priority)            || (optsP.priority            = _raw(priority))
    isnothing(express)             || (optsP.is_express          = express)
    isnothing(reliability)         || (optsP.reliability         = _raw(reliability))
    isnothing(allowed_destination) || (optsP.allowed_destination = _raw(allowed_destination))
    return opts, enc_ref
end

function _declare_plain_publisher(s::Session, k::Keyexpr; kwargs...)
    opts, enc_ref = _make_publisher_opts(; kwargs...)
    pub = Ref{LibZenohC.z_owned_publisher_t}()
    ret = GC.@preserve enc_ref LibZenohC.z_declare_publisher(_loan(s), pub, _loan(k), opts)
    _handle_result(ret)
    # GC safety net: if the Publisher is dropped without an explicit
    # close(), drop the C handle. No-op once close() has moved it out.
    finalizer(p -> LibZenohC.z_publisher_drop(_move(p)), pub)
    return Publisher(pub, k)
end

"""
    Publisher(s::Session, k::Keyexpr; encoding, congestion_control, priority,
              express, reliability, allowed_destination,
              cache, miss_detection, detection)

Declare a publisher on keyexpr `k`. With only the shared QoS keywords this
returns a plain [`Publisher`](@ref); passing any advanced feature keyword
(`cache`, `miss_detection`, `detection`) routes to an
[`AdvancedPublisher`](@ref) instead (same operations, plus history/recovery
support). Construct `AdvancedPublisher(s, k; …)` directly for a guaranteed
concrete return type.
"""
function Publisher(s::Session, k::Keyexpr; kwargs...)
    _wants_advanced((; kwargs...), Val(ADVANCED_PUB_KW)) &&
        return AdvancedPublisher(s, k; kwargs...)
    return _declare_plain_publisher(s, k; kwargs...)
end

function Base.close(p::Publisher)
    @lock p.lock begin
        p.closed && return nothing
        p.closed = true
        _handle_result(LibZenohC.z_undeclare_publisher(_move(p.pub)))
    end
    return nothing
end

function _init_put_opts(::Type{LibZenohC.z_publisher_put_options_t})
    opts = Ref{LibZenohC.z_publisher_put_options_t}()
    LibZenohC.z_publisher_put_options_default(opts)
    return opts
end

function _init_put_opts(::Type{LibZenohC.z_put_options_t})
    opts = Ref{LibZenohC.z_put_options_t}()
    LibZenohC.z_put_options_default(opts)
    return opts
end

const _Put_Types = Union{LibZenohC.z_publisher_put_options_t, LibZenohC.z_put_options_t}

# Shared between session-level put (z_put_options_t) and publisher put
# (z_publisher_put_options_t): timestamp, encoding, attachment. QoS
# fields (congestion_control / priority / is_express / allowed_destination)
# only exist on z_put_options_t — at the publisher level they're baked
# into the Publisher itself — so the session-level `put` handles those
# inline rather than threading another conditional through this helper.
function _make_put_opts(::Type{T};
        timestamp::Union{Nothing, ZTimestamp} = nothing,
        encoding::Union{Nothing, Encoding, AbstractString, Base.MIME} = nothing,
        attachment = nothing) where T <: _Put_Types
    opts  = _init_put_opts(T)
    optsP = Base.unsafe_convert(Ptr{T}, opts)

    enc_ref    = isnothing(encoding)   ? nothing : _to_owned_encoding(_as_encoding(encoding))
    attach_ref = isnothing(attachment) ? nothing : ZBytes(attachment)

    isnothing(timestamp)  || (optsP.timestamp  = Base.unsafe_convert(Ptr{LibZenohC.z_timestamp_t}, timestamp.ts))
    isnothing(enc_ref)    || (optsP.encoding   = _move(enc_ref))
    isnothing(attach_ref) || (optsP.attachment = _move(attach_ref))

    # `timestamp` is returned so the caller can GC.@preserve it across the
    # put: optsP.timestamp is a *borrowed* pointer into the ZTimestamp's
    # Ref (unlike encoding/attachment, which are moved-owned), so the
    # ZTimestamp must outlive the z_put/z_publisher_put call.
    return opts, enc_ref, attach_ref, timestamp
end

# Default for `shm=` kwarg routing. shm.jl specializes on AbstractShmProvider
# to alloc + copy into SHM and produce an SHM-backed ZBytes.
#
# The `::Nothing` (no `shm=`) arm forwards an *already-built* owned ZBytes
# unchanged via the `ZBytes(::ZBytes)` identity (types/bytes.jl), which `put`
# then `_move`s into `z_publisher_put` — so an SHM payload built upstream (e.g.
# from a ShmBufMut) is sent zero-copy with no `shm=` kwarg. The paired
# `_shm_zbytes(::AbstractShmProvider, ::ZBytes)` arm in shm.jl is the same
# passthrough when a provider happens to be named.
_shm_zbytes(::Nothing, payload) = ZBytes(payload)

"""
    put(p::Publisher, payload; shm=nothing, timestamp, encoding, attachment)

Publish `payload` (an update [`Sample`](@ref)) through a declared publisher via
`z_publisher_put`. The publisher's declare-time QoS applies, so the only
per-call options are `timestamp`, `encoding`, and `attachment`; an SHM-backed
payload is selected by passing an SHM provider as `shm`.

For a one-shot publish without declaring a publisher — and with per-call QoS —
use `put(s::Session, k, payload; …)`.
"""
function put(p::Publisher, payload; shm=nothing, kwargs...)
    # Build the (fallible) options first, then the payload — and if building the
    # SHM payload throws (a full/fragmented segment is the *expected* steady state
    # under load), release the already-built attachment on this task so the
    # finalizer-less owned ZBytes can't leak. (`_shm_zbytes` itself releases a
    # half-filled buffer; this guards the attachment.)
    opts, enc_ref, attach_ref, ts = _make_put_opts(LibZenohC.z_publisher_put_options_t; kwargs...)
    local bytes
    try
        bytes = _shm_zbytes(shm, payload)
    catch
        attach_ref === nothing || close(attach_ref)
        rethrow()
    end
    # Lock against close/undeclare across the C put so we never loan a gravestoned handle. Options
    # + payload are built above, OUTSIDE the lock, so a (possibly blocking) SHM alloc doesn't hold it.
    @lock p.lock begin
        if p.closed
            # Undeclared concurrently: drop the built owned bytes/attachment (finalizer-less → would
            # leak) and no-op — the put is moot post-close. `close` is gravestone-idempotent, so a
            # reused/held caller box (ROSNode's payload_zb/att_zb) is just re-gravestoned, exactly as
            # the normal-path `_move` would leave it.
            close(bytes)
            attach_ref === nothing || close(attach_ref)
            return nothing
        end
        GC.@preserve enc_ref attach_ref ts begin
            _handle_result(LibZenohC.z_publisher_put(_loan(p.pub), _move(bytes), opts))
        end
    end
    return nothing
end

"""
    put(s::Session, k::Keyexpr, payload; shm=nothing, congestion_control, priority,
        express, reliability, allowed_destination, timestamp, encoding, attachment)

Publish `payload` on keyexpr `k` in one shot via `z_put`, the lightweight path
that needs no declared [`Publisher`](@ref). Because there is no long-lived
handle to bake QoS into, this form accepts the full per-call QoS set
(`congestion_control`, `priority`, `express`, `reliability`,
`allowed_destination`) alongside the shared `timestamp`/`encoding`/`attachment`
options; pass an SHM provider as `shm` for an SHM-backed payload.

Reach for [`Publisher`](@ref) plus `put(p, payload; …)` when publishing
repeatedly on the same key.
"""
function put(s::Session, k::AbstractKeyexpr, payload;
        shm=nothing,
        congestion_control::Union{Nothing, CongestionControl} = nothing,
        priority::Union{Nothing, Priority}                    = nothing,
        express::Union{Nothing, Bool}                         = nothing,
        reliability::Union{Nothing, Reliability}              = nothing,
        allowed_destination::Union{Nothing, Locality}         = nothing,
        kwargs...)
    GC.@preserve s k begin
        sp = _loan(s); kp = _loan(k)        # closed-check before any owned payload is built
        opts, enc_ref, attach_ref, ts = _make_put_opts(LibZenohC.z_put_options_t; kwargs...)
        optsP = Base.unsafe_convert(Ptr{LibZenohC.z_put_options_t}, opts)
        isnothing(congestion_control)  || (optsP.congestion_control  = _raw(congestion_control))
        isnothing(priority)            || (optsP.priority            = _raw(priority))
        isnothing(express)             || (optsP.is_express          = express)
        isnothing(reliability)         || (optsP.reliability         = _raw(reliability))
        isnothing(allowed_destination) || (optsP.allowed_destination = _raw(allowed_destination))
        local bytes
        try
            bytes = _shm_zbytes(shm, payload)
        catch
            attach_ref === nothing || close(attach_ref)
            rethrow()
        end
        GC.@preserve enc_ref attach_ref ts begin
            rtc = LibZenohC.z_put(sp, kp, _move(bytes), opts)
            _handle_result(rtc)
        end
    end
end

# ── delete! ──────────────────────────────────────────────────────────
#
# Publishes a tombstone (delete sample) on a keyexpr. Unified across
# Session / Publisher / AdvancedPublisher (the AdvancedPublisher method is
# in features/advanced_pubsub.jl), extending `Base.delete!`. Argument shapes
# mirror `put`: session form takes the keyexpr + QoS, publisher form takes
# just the timestamp (QoS is baked into the publisher).

"""
    delete!(s::Session, k::Keyexpr; timestamp, congestion_control, priority,
            express, reliability, allowed_destination)

Publish a delete (tombstone) sample on keyexpr `k`.
"""
function Base.delete!(s::Session, k::AbstractKeyexpr;
        timestamp::Union{Nothing, ZTimestamp}                 = nothing,
        congestion_control::Union{Nothing, CongestionControl} = nothing,
        priority::Union{Nothing, Priority}                    = nothing,
        express::Union{Nothing, Bool}                         = nothing,
        reliability::Union{Nothing, Reliability}              = nothing,
        allowed_destination::Union{Nothing, Locality}         = nothing)
    opts = Ref{LibZenohC.z_delete_options_t}()
    LibZenohC.z_delete_options_default(opts)
    optsP = Base.unsafe_convert(Ptr{LibZenohC.z_delete_options_t}, opts)
    isnothing(timestamp)           || (optsP.timestamp           = Base.unsafe_convert(Ptr{LibZenohC.z_timestamp_t}, timestamp.ts))
    isnothing(congestion_control)  || (optsP.congestion_control  = _raw(congestion_control))
    isnothing(priority)            || (optsP.priority            = _raw(priority))
    isnothing(express)             || (optsP.is_express          = express)
    isnothing(reliability)         || (optsP.reliability         = _raw(reliability))
    isnothing(allowed_destination) || (optsP.allowed_destination = _raw(allowed_destination))

    GC.@preserve timestamp begin
        _handle_result(LibZenohC.z_delete(_loan(s), _loan(k), opts))
    end
    return nothing
end

"""
    delete!(p::Publisher; timestamp)

Publish a delete (tombstone) sample on the publisher's keyexpr.
"""
function Base.delete!(p::Publisher; timestamp::Union{Nothing, ZTimestamp} = nothing)
    opts = Ref{LibZenohC.z_publisher_delete_options_t}()
    LibZenohC.z_publisher_delete_options_default(opts)
    optsP = Base.unsafe_convert(Ptr{LibZenohC.z_publisher_delete_options_t}, opts)
    isnothing(timestamp) || (optsP.timestamp = Base.unsafe_convert(Ptr{LibZenohC.z_timestamp_t}, timestamp.ts))
    @lock p.lock begin                       # same put/close race — loan must be lock-guarded
        p.closed && return nothing           # undeclared concurrently → the delete is moot
        GC.@preserve timestamp begin
            _handle_result(LibZenohC.z_publisher_delete(_loan(p.pub), opts))
        end
    end
    return nothing
end

export AbstractPublisher, Publisher, put
