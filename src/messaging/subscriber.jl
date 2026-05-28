# Single-slot overwrite-on-full callback subscriber. The shared
# latest-wins machinery lives in `callback.jl`; the per-kind trampolines
# and `cglobal` lookups are stamped out by `@closure_kind :sample` in
# `closure_kinds.jl`. This file just wires the Julia `Subscriber`
# lifecycle on top of those generic hooks.

# --- Julia-side Subscriber -------------------------------------------

# Abstract supertype shared with LivelinessSubscriber. Concrete subtypes
# must hold the same fields (sub, ctx, async_cond, task, keyexpr, closed);
# Julia doesn't inherit fields, so the layout is duplicated but the
# close() lifecycle is shared via dispatch on this supertype.
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

# Shared callback-subscriber construction. `declare_fn(sub, closure) -> rtc`
# picks the C declare entrypoint (data vs. liveliness) and supplies any
# extra options. `T` is the concrete subscriber type to construct on
# success.
function _open_callback_sub(declare_fn::F, ::Type{T}, f::Function,
        k::Keyexpr; should_close_on_error::Bool=true) where {F, T<:AbstractCallbackSubscriber}
    ctx, async_cond, closure = _setup_callback(Val(:sample))

    sub = Ref{LibZenohC.z_owned_subscriber_t}()
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
# setproperty!; poke the field through the raw pointer (same pattern as
# z_queryable_options_t in queryable.jl). Returns `nothing` if no
# user-set fields — caller passes C_NULL to take libzenoh defaults.
function _make_subscriber_opts(allowed_origin::Union{Nothing, Locality})
    isnothing(allowed_origin) && return nothing
    opts = Ref{LibZenohC.z_subscriber_options_t}()
    LibZenohC.z_subscriber_options_default(opts)
    p = Base.unsafe_convert(Ptr{LibZenohC.z_subscriber_options_t}, opts)
    unsafe_store!(Ptr{LibZenohC.z_locality_t}(p + fieldoffset(LibZenohC.z_subscriber_options_t, 1)),
                  _raw(allowed_origin))
    return opts
end

_sub_opts_arg(::Nothing) = C_NULL
_sub_opts_arg(r::Ref)    = r

"""
    open(f, s::Session, k::Keyexpr; should_close_on_error=true,
         allowed_origin=nothing)

Subscribe to keyexpr `k` in session `s`. `f(::Sample)` is invoked on a
dedicated Julia task for each sample that fits through the single-slot
handoff. Samples that arrive while the cell still holds an unconsumed
one overwrite it — the consumer always sees the latest message; older
ones are dropped silently.

If `f` throws and `should_close_on_error` is `true`, the dispatcher
task exits; subsequent samples accumulate (and get overwritten) in
the cell until `close(sub)` is called.

`allowed_origin` filters which peers' samples are delivered. Accepts a
`Locality` singleton (`Localities.ANY` / `SESSION_LOCAL` / `REMOTE`).
"""
function Base.open(f::Function, s::Session, k::Keyexpr;
        should_close_on_error::Bool=true,
        allowed_origin::Union{Nothing, Locality} = nothing)
    opts = _make_subscriber_opts(allowed_origin)
    _open_callback_sub(Subscriber, f, k;
            should_close_on_error=should_close_on_error) do sub, closure
        GC.@preserve opts LibZenohC.z_declare_subscriber(_loan(s), sub, _loan(k),
            _move(closure), _sub_opts_arg(opts))
    end
end

"""
Subscribe to keyexpr `k` in session `s` with a buffered channel handler.
Returns a `SubscriberHandler` that can be iterated or polled with
`take!`/`tryrecv!`. Call `close(sub)` to undeclare the subscriber;
iteration will then terminate once buffered samples are drained.

`allowed_origin` accepts a `Locality` singleton (`Localities.ANY` etc.).
"""
function Base.open(s::Session, k::Keyexpr;
        channel::Symbol = :fifo, capacity::Integer = 16,
        allowed_origin::Union{Nothing, Locality} = nothing)
    opts = _make_subscriber_opts(allowed_origin)
    _open_buffered_sub(SubscriberHandler, k, channel, capacity) do sub, closure
        GC.@preserve opts LibZenohC.z_declare_subscriber(_loan(s), sub, _loan(k),
            _move(closure), _sub_opts_arg(opts))
    end
end

function Base.close(sub::AbstractCallbackSubscriber)
    sub.closed && return
    sub.closed = true

    signal_closing!(sub.ctx, sub.async_cond)

    # Blocks until libzenohc has drained any in-flight callbacks (they
    # bail on the closing flag) and invoked our drop trampoline. The
    # trampoline never blocks, so this returns promptly.
    _handle_result(LibZenohC.z_undeclare_subscriber(_move(sub.sub)))

    wait(sub.task)

    _teardown_callback(Val(:sample), sub.ctx, sub.async_cond)
    # sub.ctx (the Julia CallbackCtx) is released to GC when this
    # Subscriber becomes unreachable.
    return nothing
end
