# Advanced pub/sub — reliability layered on plain pub/sub via the
# `ze_advanced_*` (unstable) C surface:
#
#   • AdvancedPublisher  — sample cache (serve history), per-source
#     sequence numbering + optional heartbeat (sample-miss detection),
#     liveliness-based publisher detection.
#   • AdvancedSubscriber — history replay on join, gap recovery
#     (retransmit queries), sample-miss notifications.
#
# `Publisher` / `open` route here transparently when an advanced feature
# keyword is present (see publisher.jl / subscriber.jl); `AdvancedPublisher`
# / `AdvancedSubscriber` can also be constructed directly for a guaranteed
# concrete return type. Both share `AbstractPublisher` /
# `AbstractCallbackSubscriber` / `AbstractSubscriberHandler` with the plain
# types, so `put` / `delete!` / `close` / iteration / `MatchingListener`
# work uniformly.
#
# Each advanced feature is configured by a keyword carrying its options
# value (no bare bools): presence opts in, omission opts out. The option
# structs below mirror the C nested option structs 1:1 (`is_enabled` /
# the detection toggles are implied by presence).

# ── User-facing option structs ───────────────────────────────────────

"""
    CacheOptions(; max_samples=1, congestion_control=nothing, priority=nothing, express=nothing)

Publisher-side sample cache: retains the last `max_samples` samples and
serves them to late/recovering advanced subscribers. `CacheOptions(n)` is
shorthand for `CacheOptions(max_samples=n)`.
"""
struct CacheOptions
    max_samples::Int
    congestion_control::Union{Nothing, CongestionControl}
    priority::Union{Nothing, Priority}
    express::Union{Nothing, Bool}
    CacheOptions(; max_samples::Integer=1, congestion_control=nothing,
                   priority=nothing, express=nothing) =
        new(max_samples, congestion_control, priority, express)
end
CacheOptions(max_samples::Integer) = CacheOptions(; max_samples=max_samples)

"""
    MissDetectionOptions(; heartbeat=:none, period_ms=0)

Publisher-side sample-miss detection: stamps samples with per-source
sequence numbers so subscribers can detect gaps. `heartbeat` is `:none`,
`:periodic`, or `:sporadic`; `period_ms` tunes the periodic heartbeat.
`MissDetectionOptions(sym)` is shorthand for `MissDetectionOptions(heartbeat=sym)`.
"""
struct MissDetectionOptions
    heartbeat::Symbol
    period_ms::Int
    MissDetectionOptions(; heartbeat::Symbol=:none, period_ms::Integer=0) =
        new(heartbeat, period_ms)
end
MissDetectionOptions(heartbeat::Symbol) = MissDetectionOptions(; heartbeat=heartbeat)

"""
    HistoryOptions(; detect_late_publishers=false, max_samples=0, max_age_ms=0)

Subscriber-side history replay: on declaration, query matching advanced
publishers and replay their cached samples. `max_samples`/`max_age_ms` of
`0` mean unbounded. `detect_late_publishers` also back-fills from
publishers that appear after the subscriber.
"""
struct HistoryOptions
    detect_late_publishers::Bool
    max_samples::Int
    max_age_ms::Int
    HistoryOptions(; detect_late_publishers::Bool=false, max_samples::Integer=0,
                     max_age_ms::Integer=0) =
        new(detect_late_publishers, max_samples, max_age_ms)
end

"""
    RecoveryOptions(; periodic_queries_period_ms=0)

Subscriber-side gap recovery. A positive `periodic_queries_period_ms` polls
for missed last samples at that interval. The default `0` recovers gaps from
the publisher heartbeat and sequence numbers alone.
"""
struct RecoveryOptions
    periodic_queries_period_ms::Int
    RecoveryOptions(; periodic_queries_period_ms::Integer=0) =
        new(periodic_queries_period_ms)
end

"""
    DetectionOptions()

Enable liveliness-based detection of this endpoint (publisher or
subscriber). The detection-metadata keyexpr is not yet exposed.
"""
struct DetectionOptions
    DetectionOptions() = new()
end

# ── C option translation ─────────────────────────────────────────────

function _heartbeat_mode(s::Symbol)
    s === :none     && return LibZenohC.ZE_ADVANCED_PUBLISHER_HEARTBEAT_MODE_NONE
    s === :periodic && return LibZenohC.ZE_ADVANCED_PUBLISHER_HEARTBEAT_MODE_PERIODIC
    s === :sporadic && return LibZenohC.ZE_ADVANCED_PUBLISHER_HEARTBEAT_MODE_SPORADIC
    throw(ArgumentError("heartbeat must be :none, :periodic, or :sporadic; got :$s"))
end

# Build the C nested-struct value, taking unspecified scalar QoS from the
# defaulted `base` sub-struct. `is_enabled` is forced true (presence == on).
function _cache_value(c::CacheOptions, base::LibZenohC.ze_advanced_publisher_cache_options_t)
    LibZenohC.ze_advanced_publisher_cache_options_t(
        true,
        Csize_t(c.max_samples),
        isnothing(c.congestion_control) ? base.congestion_control : _raw(c.congestion_control),
        isnothing(c.priority)           ? base.priority           : _raw(c.priority),
        isnothing(c.express)            ? base.is_express         : c.express)
end
_cache_value(n::Integer, base) = _cache_value(CacheOptions(n), base)

function _miss_detection_value(m::MissDetectionOptions, _base)
    LibZenohC.ze_advanced_publisher_sample_miss_detection_options_t(
        true, _heartbeat_mode(m.heartbeat), UInt64(m.period_ms))
end
_miss_detection_value(s::Symbol, base) = _miss_detection_value(MissDetectionOptions(s), base)

function _history_value(h::HistoryOptions, _base)
    LibZenohC.ze_advanced_subscriber_history_options_t(
        true, h.detect_late_publishers, Csize_t(h.max_samples), UInt64(h.max_age_ms))
end

function _recovery_value(r::RecoveryOptions, _base)
    last = LibZenohC.ze_advanced_subscriber_last_sample_miss_detection_options_t(
        r.periodic_queries_period_ms > 0, UInt64(r.periodic_queries_period_ms))
    LibZenohC.ze_advanced_subscriber_recovery_options_t(true, last)
end

# ── Options builders ─────────────────────────────────────────────────

# Field indices into the C options structs (see gen/LibZenohC.jl).
#   ze_advanced_publisher_options_t : 1 publisher_options, 2 cache,
#       3 sample_miss_detection, 4 publisher_detection, 5 *_metadata
#   ze_advanced_subscriber_options_t: 1 subscriber_options, 2 history,
#       3 recovery, 4 query_timeout_ms, 5 subscriber_detection, 6 *_metadata
function _make_advanced_publisher_opts(;
        cache=nothing, miss_detection=nothing, detection=nothing,
        encoding=nothing, congestion_control=nothing, priority=nothing,
        express=nothing, reliability=nothing, allowed_destination=nothing)
    opts = Ref{LibZenohC.ze_advanced_publisher_options_t}()
    LibZenohC.ze_advanced_publisher_options_default(opts)
    base = opts[]

    pub_opts, enc_ref = _make_publisher_opts(; encoding, congestion_control,
        priority, express, reliability, allowed_destination)
    _store_field!(opts, 1, pub_opts[])

    isnothing(cache)          || _store_field!(opts, 2, _cache_value(cache, base.cache))
    isnothing(miss_detection) || _store_field!(opts, 3, _miss_detection_value(miss_detection, base.sample_miss_detection))
    isnothing(detection)      || _store_field!(opts, 4, true)
    return opts, enc_ref
end

function _make_advanced_subscriber_opts(;
        history=nothing, recovery=nothing, query_timeout_ms=nothing,
        detection=nothing, allowed_origin=nothing)
    opts = Ref{LibZenohC.ze_advanced_subscriber_options_t}()
    LibZenohC.ze_advanced_subscriber_options_default(opts)
    base = opts[]

    if !isnothing(allowed_origin)
        sub_opts = Ref{LibZenohC.z_subscriber_options_t}()
        LibZenohC.z_subscriber_options_default(sub_opts)
        _store_field!(sub_opts, 1, _raw(allowed_origin))
        _store_field!(opts, 1, sub_opts[])
    end
    isnothing(history)          || _store_field!(opts, 2, _history_value(history, base.history))
    isnothing(recovery)         || _store_field!(opts, 3, _recovery_value(recovery, base.recovery))
    isnothing(query_timeout_ms) || _store_field!(opts, 4, UInt64(query_timeout_ms))
    isnothing(detection)        || _store_field!(opts, 5, true)
    return opts
end

# ── AdvancedPublisher ────────────────────────────────────────────────

"""
    AdvancedPublisher(s::Session, k::Keyexpr; cache, miss_detection, detection,
                      encoding, congestion_control, priority, express,
                      reliability, allowed_destination)

Declare an advanced publisher on `k`. Always returns an `AdvancedPublisher`
(the routing `Publisher(s, k; …)` returns one transparently when an advanced
keyword is set). Supports `put`, `delete!`, `MatchingListener`,
`matching_status`, and `close`.

!!! note
    `cache` and `miss_detection` stamp samples, so the session must have
    **timestamping enabled** (`Config(; str="{timestamping:{enabled:true}}")`,
    or a routed/timestamping deployment) — otherwise the declare fails with
    `Z_EGENERIC`.
"""
mutable struct AdvancedPublisher <: AbstractPublisher
    pub::Base.RefValue{LibZenohC.ze_owned_advanced_publisher_t}
    keyexpr::AbstractKeyexpr  # GC pin
    closed::Bool
    AdvancedPublisher(pub::Base.RefValue{LibZenohC.ze_owned_advanced_publisher_t}, k::Keyexpr) =
        new(pub, k, false)
end

function AdvancedPublisher(s::Session, k::Keyexpr; kwargs...)
    opts, enc_ref = _make_advanced_publisher_opts(; kwargs...)
    pub = Ref{LibZenohC.ze_owned_advanced_publisher_t}()
    ret = GC.@preserve enc_ref LibZenohC.ze_declare_advanced_publisher(
        _loan(s), pub, _loan(k), opts)
    _handle_result(ret)
    finalizer(p -> LibZenohC.ze_advanced_publisher_drop(_move(p)), pub)
    return AdvancedPublisher(pub, k)
end

function Base.close(p::AdvancedPublisher)
    p.closed && return
    p.closed = true
    _handle_result(LibZenohC.ze_undeclare_advanced_publisher(_move(p.pub)))
    return nothing
end

"""
    put(ap::AdvancedPublisher, payload; shm=nothing, timestamp, encoding, attachment)

Publish `payload` through advanced publisher `ap` via `ze_advanced_publisher_put`,
caching it and stamping the configured per-source sequence number. The
declare-time QoS applies, so the per-call options match the plain
[`put(::Publisher, …)`](@ref) form (`timestamp`, `encoding`, `attachment`, and
an SHM provider as `shm`).
"""
function put(ap::AdvancedPublisher, payload; shm=nothing, kwargs...)
    bytes = _shm_zbytes(shm, payload)
    inner, enc_ref, attach_ref, ts = _make_put_opts(LibZenohC.z_publisher_put_options_t; kwargs...)
    opts = Ref{LibZenohC.ze_advanced_publisher_put_options_t}()
    LibZenohC.ze_advanced_publisher_put_options_default(opts)
    _store_field!(opts, 1, inner[])  # ze_advanced_publisher_put_options_t.put_options
    GC.@preserve enc_ref attach_ref ts begin
        rtc = LibZenohC.ze_advanced_publisher_put(_loan(ap.pub), _move(bytes), opts)
        _handle_result(rtc)
    end
end

"""
    delete!(ap::AdvancedPublisher; timestamp)

Publish a delete (tombstone) sample on the advanced publisher's keyexpr.
"""
function Base.delete!(ap::AdvancedPublisher; timestamp::Union{Nothing, ZTimestamp} = nothing)
    inner = Ref{LibZenohC.z_publisher_delete_options_t}()
    LibZenohC.z_publisher_delete_options_default(inner)
    isnothing(timestamp) ||
        (Base.unsafe_convert(Ptr{LibZenohC.z_publisher_delete_options_t}, inner).timestamp =
            Base.unsafe_convert(Ptr{LibZenohC.z_timestamp_t}, timestamp.ts))
    opts = Ref{LibZenohC.ze_advanced_publisher_delete_options_t}()
    LibZenohC.ze_advanced_publisher_delete_options_default(opts)
    _store_field!(opts, 1, inner[])  # ze_advanced_publisher_delete_options_t.delete_options
    GC.@preserve timestamp begin
        _handle_result(LibZenohC.ze_advanced_publisher_delete(_loan(ap.pub), opts))
    end
    return nothing
end

# MatchingListener / matching_status for AdvancedPublisher — added to the
# generics from matching.jl (that file loads first but can't name this type).

"""
    MatchingListener(f, ap::AdvancedPublisher; should_close_on_error=true)

Declare a matching listener on advanced publisher `ap`. Same semantics as the
plain [`Publisher`](@ref) form.
"""
function MatchingListener(f::Function, ap::AdvancedPublisher;
        should_close_on_error::Bool=true)
    _matching_listener_setup(f, ap, should_close_on_error) do handle, closure
        LibZenohC.ze_advanced_publisher_declare_matching_listener(
            _loan(ap.pub), handle, _move(closure))
    end
end

"""
    matching_status(ap::AdvancedPublisher) -> Bool

One-shot poll of `ap`'s current matching status (true iff at least one
matching subscriber exists). For change notifications use
[`MatchingListener`](@ref).
"""
function matching_status(ap::AdvancedPublisher)
    status = Ref{LibZenohC.z_matching_status_t}()
    rtc = LibZenohC.ze_advanced_publisher_get_matching_status(_loan(ap.pub), status)
    _handle_result(rtc)
    return status[].matching
end

# ── AdvancedSubscriber (callback + buffered) ─────────────────────────

"""
    AdvancedSubscriber(f, s::Session, k::Keyexpr; should_close_on_error=true,
                       allowed_origin, history, recovery, query_timeout_ms, detection)

Callback-form advanced subscriber. `f(::Sample)` runs on a dedicated Julia
task (latest-wins single slot, like [`Subscriber`](@ref)), plus
history/recovery per the advanced options. `open(f, s, k; history=…)` routes
here transparently.
"""
mutable struct AdvancedSubscriber <: AbstractCallbackSubscriber
    sub::Base.RefValue{LibZenohC.ze_owned_advanced_subscriber_t}
    ctx::CallbackCtx{LibZenohC.z_owned_sample_t}
    async_cond::Base.AsyncCondition
    task::Task
    keyexpr::AbstractKeyexpr  # GC pin
    closed::Bool
end

"""
    AdvancedSubscriberHandler

Buffered advanced subscriber returned by `AdvancedSubscriber(s, k; channel=…)`
(or `open(s, k; history=…)`). Iterate / `take!` / `tryrecv!` to consume
`Sample`s. See [`SubscriberHandler`](@ref).
"""
mutable struct AdvancedSubscriberHandler <: AbstractSubscriberHandler
    sub::Base.RefValue{LibZenohC.ze_owned_advanced_subscriber_t}
    ctx::CallbackCtx{LibZenohC.z_owned_sample_t}
    async_cond::Base.AsyncCondition
    keyexpr::AbstractKeyexpr
    closed::Bool
end

function AdvancedSubscriber(f::Function, s::Session, k::Keyexpr;
        should_close_on_error::Bool=true, kwargs...)
    opts = _make_advanced_subscriber_opts(; kwargs...)
    _open_callback_sub(AdvancedSubscriber, f, k;
            should_close_on_error=should_close_on_error) do sub, closure
        GC.@preserve opts LibZenohC.ze_declare_advanced_subscriber(
            _loan(s), sub, _loan(k), _move(closure), opts)
    end
end

function AdvancedSubscriber(s::Session, k::Keyexpr;
        channel::Symbol=:fifo, capacity::Integer=16, kwargs...)
    opts = _make_advanced_subscriber_opts(; kwargs...)
    # `:fifo`/`:ring` → drop-oldest ring (KEEP_LAST); `:keep_all` → heap-backed.
    _open_buffered_sub(AdvancedSubscriberHandler, k, capacity, channel) do sub, closure
        GC.@preserve opts LibZenohC.ze_declare_advanced_subscriber(
            _loan(s), sub, _loan(k), _move(closure), opts)
    end
end

# Advanced-subscriber overrides of the shared undeclare/drop dispatch.
_undeclare_callback_sub(sub::AdvancedSubscriber) =
    LibZenohC.ze_undeclare_advanced_subscriber(_move(sub.sub))
_drop_sub_handle(s::Base.RefValue{LibZenohC.ze_owned_advanced_subscriber_t}) =
    LibZenohC.ze_advanced_subscriber_drop(_move(s))
_undeclare_sub_handle(s::Base.RefValue{LibZenohC.ze_owned_advanced_subscriber_t}) =
    LibZenohC.ze_undeclare_advanced_subscriber(_move(s))

# ── isadvanced predicate ─────────────────────────────────────────────

"""
    isadvanced(x) -> Bool

`true` for the advanced publisher/subscriber variants, `false` for the plain
ones. Lets generic code branch on the kind a routing constructor returned
without `isa`.
"""
isadvanced(::AbstractPublisher)         = false
isadvanced(::AdvancedPublisher)         = true
isadvanced(::AbstractCallbackSubscriber) = false
isadvanced(::AbstractSubscriberHandler)  = false
isadvanced(::AdvancedSubscriber)         = true
isadvanced(::AdvancedSubscriberHandler)  = true
isadvanced(::KeepAllSubscriber)          = false
isadvanced(::KeepAllSubscriber{LibZenohC.ze_owned_advanced_subscriber_t}) = true

# ── :miss closure kind + SampleMissListener ──────────────────────────
#
# `ze_closure_miss` is the only `ze_`-prefixed closure family, so rather
# than generalize @closure_kind's hardcoded `z_` naming for one case we
# hand-write the :pod-shape plumbing here, mirroring what
# `@closure_kind :matching_status :pod` expands to (ze_miss_t is POD).

const _CALL_CB_MISS = Ref{Ptr{Cvoid}}(C_NULL)
const _DROP_CB_MISS = Ref{Ptr{Cvoid}}(C_NULL)

_call_tramp_miss(item::Ptr{LibZenohC.ze_miss_t}, ctx::Ptr{Cvoid}) =
    call_body_pod!(item, ctx, LibZenohC.ze_miss_t)
_drop_tramp_miss(ctx::Ptr{Cvoid}) = drop_body!(ctx, LibZenohC.ze_miss_t)

_register_init!() do
    _CALL_CB_MISS[] = @cfunction(_call_tramp_miss, Cvoid,
        (Ptr{LibZenohC.ze_miss_t}, Ptr{Cvoid}))
    _DROP_CB_MISS[] = @cfunction(_drop_tramp_miss, Cvoid, (Ptr{Cvoid},))
end

_make_callback_ctx(::Val{:miss}) = CallbackCtx{LibZenohC.ze_miss_t}()
_make_closure_ref(::Val{:miss})  = Ref{LibZenohC.ze_owned_closure_miss_t}()

function _install_closure!(::Val{:miss},
        closure::Ref{LibZenohC.ze_owned_closure_miss_t},
        ctx::CallbackCtx{LibZenohC.ze_miss_t})
    LibZenohC.ze_closure_miss(closure, _CALL_CB_MISS[], _DROP_CB_MISS[], ctx_p(ctx))
end

function _teardown_callback(::Val{:miss},
        ctx::CallbackCtx{LibZenohC.ze_miss_t},
        async_cond::Base.AsyncCondition; close_async::Bool=true)
    destroy_ctx_pod!(ctx, async_cond; close_async)
end

"""
    SampleMiss

A detected gap in an advanced publisher's stream, delivered to a
[`SampleMissListener`](@ref): `source` is the publisher's entity id and
`count` is the number of missed samples.
"""
struct SampleMiss
    source::LibZenohC.z_entity_global_id_t
    count::UInt32
end

@inline _miss_unwrap(r::Base.RefValue{LibZenohC.ze_miss_t}) =
    SampleMiss(r[].source, r[].nb)

"""
    SampleMissListener(f, sub::AdvancedSubscriber; should_close_on_error=true)

Declare a sample-miss listener on advanced subscriber `sub`. `f(::SampleMiss)`
runs on a dedicated Julia task each time an unrecoverable gap is detected.
Call `close(ml)` to undeclare.
"""
mutable struct SampleMissListener
    handle::Base.RefValue{LibZenohC.ze_owned_sample_miss_listener_t}
    ctx::CallbackCtx{LibZenohC.ze_miss_t}
    async_cond::Base.AsyncCondition
    task::Task
    target::AdvancedSubscriber  # GC pin — listener references the subscriber internally
    closed::Bool
end

function SampleMissListener(f::Function, sub::AdvancedSubscriber;
        should_close_on_error::Bool=true)
    ctx, async_cond, closure = _setup_callback(Val(:miss))
    handle = Ref{LibZenohC.ze_owned_sample_miss_listener_t}()
    rtc = GC.@preserve ctx LibZenohC.ze_advanced_subscriber_declare_sample_miss_listener(
        _loan(sub.sub), handle, _move(closure))
    if rtc != LibZenohC.Z_OK
        _teardown_callback(Val(:miss), ctx, async_cond)
        _handle_result(rtc)
    end
    task = Threads.@spawn consume(f, _miss_unwrap, ctx, async_cond, should_close_on_error)
    return SampleMissListener(handle, ctx, async_cond, task, sub, false)
end

function Base.close(ml::SampleMissListener)
    ml.closed && return
    ml.closed = true
    signal_closing!(ml.ctx, ml.async_cond)
    _handle_result(LibZenohC.ze_undeclare_sample_miss_listener(_move(ml.handle)))
    wait(ml.task)
    _teardown_callback(Val(:miss), ml.ctx, ml.async_cond)
    return nothing
end

export AdvancedPublisher, AdvancedSubscriber, AdvancedSubscriberHandler,
    SampleMiss, SampleMissListener, isadvanced,
    CacheOptions, MissDetectionOptions, HistoryOptions, RecoveryOptions,
    DetectionOptions
