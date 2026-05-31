# Single-slot overwrite-on-full callback subscriber. The shared
# latest-wins machinery lives in `callback.jl`; the per-kind trampolines
# and `cglobal` lookups are stamped out by `@closure_kind :sample` in
# `closure_kinds.jl`. This file just wires the Julia `Subscriber`
# lifecycle on top of those generic hooks.
#
# `open(f, s, k; …)` / `open(s, k; …)` are routing factories: when an
# advanced subscriber keyword is present they return the advanced handlers
# (defined in features/advanced_pubsub.jl); otherwise the plain ones.
# Routing keys on keyword presence (type-level), so the return type is
# resolved by ordinary inference — see the advanced-pubsub proposal §3.2.

# --- Julia-side Subscriber -------------------------------------------

# Abstract supertype shared with LivelinessSubscriber / AdvancedSubscriber.
# Concrete subtypes must hold the same fields (sub, ctx, async_cond, task,
# keyexpr, closed); Julia doesn't inherit fields, so the layout is duplicated
# but the close() lifecycle is shared via dispatch on this supertype. The
# owned-handle type of `sub` may differ per subtype (z_owned_subscriber_t for
# the data/liveliness subscribers, ze_owned_advanced_subscriber_t for the
# advanced one) — `_callback_sub_handle` / `_undeclare_callback_sub` adapt.
abstract type AbstractCallbackSubscriber end

"""
    Subscriber

Callback-form subscriber returned by `Base.open(f, s, k)`. The Zenoh
I/O thread stashes each sample in a single inline cell (overwriting
the previous one if not yet consumed) and wakes a Julia task; slow
consumers see only the latest message. Use
`open(s, k; channel=:fifo)` for queued semantics.
"""
mutable struct Subscriber <: AbstractCallbackSubscriber
    sub::Base.RefValue{LibZenohC.z_owned_subscriber_t}
    ctx::CallbackCtx{LibZenohC.z_owned_sample_t}
    async_cond::Base.AsyncCondition
    task::Task
    keyexpr::Keyexpr  # GC pin
    closed::Bool
end

# The owned-handle C type backing a callback subscriber `T` — read off its
# `sub` field so the shared `_open_callback_sub` allocates the right Ref
# without a hardcoded type. Type-stable (resolved from the field type).
_callback_sub_handle(::Type{T}) where {T<:AbstractCallbackSubscriber} =
    eltype(fieldtype(T, :sub))

# Shared callback-subscriber construction. `declare_fn(sub, closure) -> rtc`
# picks the C declare entrypoint (data vs. liveliness vs. advanced) and
# supplies any extra options. `T` is the concrete subscriber type to
# construct on success; its `sub` handle type is derived from `T`.
function _open_callback_sub(declare_fn::F, ::Type{T}, f::Function,
        k::Keyexpr; should_close_on_error::Bool=true) where {F, T<:AbstractCallbackSubscriber}
    ctx, async_cond, closure = _setup_callback(Val(:sample))

    sub = Ref{_callback_sub_handle(T)}()
    rtc = GC.@preserve ctx declare_fn(sub, closure)
    if rtc != LibZenohC.Z_OK
        # declare failed before the closure was installed → drop cb will fire
        # via z_closure_sample's own ownership machinery. Just clean Julia-side.
        _teardown_callback(Val(:sample), ctx, async_cond)
        _handle_result(rtc)
    end

    task = Threads.@spawn consume(f, Sample, ctx, async_cond, should_close_on_error)
    return T(sub, ctx, async_cond, task, k, false)
end

# z_subscriber_options_t is a single-field POD with no generated
# setproperty!; poke the field at its offset via `_store_field!` (same
# pattern as z_queryable_options_t in queryable.jl). Returns `nothing` if
# no user-set fields — caller passes C_NULL to take libzenoh defaults.
function _make_subscriber_opts(allowed_origin::Union{Nothing, Locality})
    isnothing(allowed_origin) && return nothing
    opts = Ref{LibZenohC.z_subscriber_options_t}()
    LibZenohC.z_subscriber_options_default(opts)
    _store_field!(opts, 1, _raw(allowed_origin))
    return opts
end

_sub_opts_arg(::Nothing) = C_NULL
_sub_opts_arg(r::Ref)    = r

# Advanced-only subscriber keywords. Presence of any routes `open(…)` to
# `AdvancedSubscriber` / `AdvancedSubscriberHandler`. Kept in sync with the
# `Advanced*` constructors in features/advanced_pubsub.jl.
const ADVANCED_SUB_KW = (:history, :recovery, :query_timeout_ms, :detection)

# --- Plain (data-plane) subscriber bodies ----------------------------

function _open_plain_callback(f::Function, s::Session, k::Keyexpr;
        should_close_on_error::Bool=true,
        allowed_origin::Union{Nothing, Locality} = nothing)
    opts = _make_subscriber_opts(allowed_origin)
    _open_callback_sub(Subscriber, f, k;
            should_close_on_error=should_close_on_error) do sub, closure
        GC.@preserve opts LibZenohC.z_declare_subscriber(_loan(s), sub, _loan(k),
            _move(closure), _sub_opts_arg(opts))
    end
end

function _open_plain_buffered(s::Session, k::Keyexpr;
        channel::Symbol = :fifo, capacity::Integer = 16,
        allowed_origin::Union{Nothing, Locality} = nothing)
    opts = _make_subscriber_opts(allowed_origin)
    # `:fifo`/`:ring` → drop-oldest ring (KEEP_LAST); `:keep_all` → heap-backed.
    _open_buffered_sub(SubscriberHandler, k, capacity, channel) do sub, closure
        GC.@preserve opts LibZenohC.z_declare_subscriber(_loan(s), sub, _loan(k),
            _move(closure), _sub_opts_arg(opts))
    end
end

# --- Routing `open` factories ----------------------------------------

"""
    open(f, s::Session, k::Keyexpr; should_close_on_error=true,
         allowed_origin=nothing, history, recovery, query_timeout_ms, detection)

Subscribe to keyexpr `k` in session `s`. `f(::Sample)` is invoked on a
dedicated Julia task for each sample that fits through the single-slot
handoff. Samples that arrive while the cell still holds an unconsumed
one overwrite it — the consumer always sees the latest message; older
ones are dropped silently.

With only the shared keywords this returns a plain [`Subscriber`](@ref);
passing any advanced feature keyword (`history`, `recovery`,
`query_timeout_ms`, `detection`) routes to an [`AdvancedSubscriber`](@ref)
with history replay / sample-miss recovery.

If `f` throws and `should_close_on_error` is `true`, the dispatcher
task exits; subsequent samples accumulate (and get overwritten) in
the cell until `close(sub)` is called.

`allowed_origin` filters which peers' samples are delivered. Accepts a
`Locality` singleton (`Localities.ANY` / `SESSION_LOCAL` / `REMOTE`).
"""
function Base.open(f::Function, s::Session, k::Keyexpr; kwargs...)
    _wants_advanced((; kwargs...), Val(ADVANCED_SUB_KW)) &&
        return AdvancedSubscriber(f, s, k; kwargs...)
    return _open_plain_callback(f, s, k; kwargs...)
end

"""
    open(s::Session, k::Keyexpr; channel=:fifo, capacity=16,
         allowed_origin=nothing, history, recovery, query_timeout_ms, detection)

Subscribe to keyexpr `k` in session `s` with a buffered handler. Iterate or
poll with `take!`/`tryrecv!`. Call `close(sub)` to undeclare; iteration
terminates once buffered samples are drained.

Delivery is the slot-free callback ring (no `@threadcall` worker is parked, so
arbitrarily many buffered endpoints coexist). `channel` selects the History
policy:

- `:fifo` / `:ring` (default) → bounded ring, **drop-oldest** on overflow,
  `capacity` slots → ROS2 **KEEP_LAST(capacity)**. Returns a
  [`SubscriberHandler`](@ref). `dropped_count(sub)` counts evictions.
- `:keep_all` → a consume task drains into an unbounded, heap-backed buffer →
  ROS2 **KEEP_ALL** (bounded only by memory; OOM, not deadlock, under
  sustained overload). Returns a [`KeepAllSubscriber`](@ref). `capacity` is a
  floor on the internal handoff ring, not a bound.

Neither blocks the IO thread. As with the callback form, passing an advanced
feature keyword routes to an [`AdvancedSubscriberHandler`](@ref).

`allowed_origin` accepts a `Locality` singleton (`Localities.ANY` etc.).
"""
function Base.open(s::Session, k::Keyexpr; kwargs...)
    _wants_advanced((; kwargs...), Val(ADVANCED_SUB_KW)) &&
        return AdvancedSubscriber(s, k; kwargs...)
    return _open_plain_buffered(s, k; kwargs...)
end

# Undeclare entrypoint for the callback `close` below. Default targets the
# data-plane subscriber; AdvancedSubscriber overrides in advanced_pubsub.jl.
_undeclare_callback_sub(sub::AbstractCallbackSubscriber) =
    LibZenohC.z_undeclare_subscriber(_move(sub.sub))

# NB: the callback-form subscriber intentionally has no GC finalizer.
# Its ctx is reachable only through this struct and the consume task
# (which form a reference cycle), so a finalizer that dropped the C
# subscriber would race the ctx's own finalization — the drop trampoline
# touches the ctx, and finalizer ordering within the cycle is undefined.
# Tearing down also has to `wait(task)`, which a finalizer cannot do. So
# the callback subscriber relies on an explicit `close()`; the plain
# channel handler (no ctx/task) does get a finalizer in `_open_buffered_sub`.
function Base.close(sub::AbstractCallbackSubscriber)
    sub.closed && return
    sub.closed = true

    signal_closing!(sub.ctx, sub.async_cond)

    # Blocks until libzenohc has drained any in-flight callbacks (they
    # bail on the closing flag) and invoked our drop trampoline. The
    # trampoline never blocks, so this returns promptly.
    _handle_result(_undeclare_callback_sub(sub))

    wait(sub.task)

    _teardown_callback(Val(:sample), sub.ctx, sub.async_cond)
    # sub.ctx (the Julia CallbackCtx) is released to GC when this
    # Subscriber becomes unreachable.
    return nothing
end

export Subscriber
