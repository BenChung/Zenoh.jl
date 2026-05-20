# Single-slot overwrite-on-full callback subscriber. The shared
# latest-wins machinery lives in `callback.jl`; this file binds it to
# `z_loaned_sample_t` / `z_owned_sample_t` and wires up the Julia
# `Subscriber` lifecycle.

# --- Foreign-thread trampolines --------------------------------------

function sub_call_trampoline(sample::Ptr{LibZenohC.z_loaned_sample_t},
        ctx::Ptr{Cvoid})
    call_body!(sample, ctx, SAMPLE_CLONE_FP[], SAMPLE_DROP_FP[],
        LibZenohC.z_owned_sample_t, LibZenohC.z_moved_sample_t)
end

function sub_drop_trampoline(ctx::Ptr{Cvoid})
    drop_body!(ctx, LibZenohC.z_owned_sample_t)
end

# `@cfunction` and `cglobal` must run at runtime — if computed at
# module top level they bake JIT/loader addresses into the precompile
# image. Built in `__init__` via the shared hook registry.
const SUB_CALL_CB     = Ref{Ptr{Cvoid}}(C_NULL)
const SUB_DROP_CB     = Ref{Ptr{Cvoid}}(C_NULL)
const SAMPLE_CLONE_FP = Ref{Ptr{Cvoid}}(C_NULL)
const SAMPLE_DROP_FP  = Ref{Ptr{Cvoid}}(C_NULL)

_register_init!() do
    SUB_CALL_CB[] = @cfunction(sub_call_trampoline, Cvoid,
        (Ptr{LibZenohC.z_loaned_sample_t}, Ptr{Cvoid}))
    SUB_DROP_CB[] = @cfunction(sub_drop_trampoline, Cvoid, (Ptr{Cvoid},))
    SAMPLE_CLONE_FP[] = cglobal((:z_sample_clone, LibZenohC.libzenohc))
    SAMPLE_DROP_FP[]  = cglobal((:z_sample_drop,  LibZenohC.libzenohc))
end

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
    ctx = CallbackCtx{LibZenohC.z_owned_sample_t}()
    async_cond = Base.AsyncCondition()
    init_ctx!(ctx, async_cond)

    closure = Ref{LibZenohC.z_owned_closure_sample_t}()
    LibZenohC.z_closure_sample(closure, SUB_CALL_CB[], SUB_DROP_CB[], ctx_p(ctx))

    sub = Ref{LibZenohC.z_owned_subscriber_t}()
    rtc = GC.@preserve ctx declare_fn(sub, closure)
    if rtc != LibZenohC.Z_OK
        # declare failed before the closure was installed → drop cb will fire
        # via z_closure_sample's own ownership machinery. Just clean Julia-side.
        destroy_ctx!(ctx, async_cond, SAMPLE_DROP_FP[], LibZenohC.z_moved_sample_t)
        _handle_result(rtc)
    end

    task = Threads.@spawn consume(f, Sample, ctx, async_cond, should_close_on_error)
    return T(sub, ctx, async_cond, task, k, false)
end

"""
    open(f, s::Session, k::Keyexpr; should_close_on_error=true)

Subscribe to keyexpr `k` in session `s`. `f(::Sample)` is invoked on a
dedicated Julia task for each sample that fits through the single-slot
handoff. Samples that arrive while the cell still holds an unconsumed
one overwrite it — the consumer always sees the latest message; older
ones are dropped silently.

If `f` throws and `should_close_on_error` is `true`, the dispatcher
task exits; subsequent samples accumulate (and get overwritten) in
the cell until `close(sub)` is called.
"""
function Base.open(f::Function, s::Session, k::Keyexpr;
        should_close_on_error::Bool=true)
    _open_callback_sub(Subscriber, f, k;
            should_close_on_error=should_close_on_error) do sub, closure
        LibZenohC.z_declare_subscriber(_loan(s), sub, _loan(k),
            _move(closure), C_NULL)
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

    destroy_ctx!(sub.ctx, sub.async_cond,
        SAMPLE_DROP_FP[], LibZenohC.z_moved_sample_t)
    # sub.ctx (the Julia CallbackCtx) is released to GC when this
    # Subscriber becomes unreachable.
    return nothing
end
