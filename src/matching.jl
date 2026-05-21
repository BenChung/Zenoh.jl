# Matching listener — notification when a publisher's keyexpr starts /
# stops having subscribers (or, eventually, when a querier's keyexpr
# starts/stops having queryables; currently blocked on the `Querier`
# wrapper, which isn't in the codebase yet).
#
# Payload type is the POD `z_matching_status_t` (one Bool), so this
# rides the `:pod`-shape `@closure_kind :matching_status` in
# `closure_kinds.jl` — no clone/drop, no channel handlers. The
# foreground lifecycle mirrors `LivelinessSubscriber` / `Queryable`:
# signal closing → undeclare → wait task → teardown.
#
# ═══════════════════════════════════════════════════════════════════════
# TODO(background-matching-listener):
# `z_publisher_declare_background_matching_listener` and the querier
# counterpart aren't wrapped. Same reasoning as background liveliness /
# background queryable: no handle is returned, so the closure lifetime
# must be tied to the publisher (or session); a small follow-up once a
# unified background-callback pin policy exists.
# ═══════════════════════════════════════════════════════════════════════

# `wrap` for the consume() loop: extract the Bool from the POD struct.
@inline _matching_unwrap(r::Base.RefValue{LibZenohC.z_matching_status_t}) =
    r[].matching

"""
    MatchingListener

Foreground matching listener returned by
`MatchingListener(f, pub::Publisher)`. `f(::Bool)` is invoked on a
dedicated Julia task each time the publisher's set of matching
subscribers transitions between empty and non-empty:

- `f(true)`  — at least one matching subscriber now exists
- `f(false)` — the last matching subscriber went away

Single-slot latest-wins semantics — see [`Subscriber`](@ref). For
matching status this is rarely a concern (transitions are infrequent
and idempotent), and the slow-consumer worst case is just seeing the
final state rather than every intermediate flip.

Call `close(ml)` to undeclare; the listener is also dropped on GC as a
safety net.
"""
mutable struct MatchingListener
    handle::Base.RefValue{LibZenohC.z_owned_matching_listener_t}
    ctx::CallbackCtx{LibZenohC.z_matching_status_t}
    async_cond::Base.AsyncCondition
    task::Task
    pub::Publisher  # GC pin — listener references the publisher internally
    closed::Bool
end

"""
    MatchingListener(f, pub::Publisher; should_close_on_error=true)

Declare a matching listener on `pub` and invoke `f(::Bool)` on each
matching-status transition. See [`MatchingListener`](@ref) for
semantics.
"""
function MatchingListener(f::Function, pub::Publisher;
        should_close_on_error::Bool=true)
    ctx, async_cond, closure = _setup_callback(Val(:matching_status))

    handle = Ref{LibZenohC.z_owned_matching_listener_t}()
    rtc = GC.@preserve ctx LibZenohC.z_publisher_declare_matching_listener(
        _loan(pub.pub), handle, _move(closure))
    if rtc != LibZenohC.Z_OK
        # declare failed before the closure was installed → its drop
        # trampoline fires via z_closure_matching_status's own
        # ownership machinery. Just clean Julia-side.
        _teardown_callback(Val(:matching_status), ctx, async_cond)
        _handle_result(rtc)
    end

    task = Threads.@spawn consume(f, _matching_unwrap, ctx, async_cond,
        should_close_on_error)
    return MatchingListener(handle, ctx, async_cond, task, pub, false)
end

function Base.close(ml::MatchingListener)
    ml.closed && return
    ml.closed = true

    signal_closing!(ml.ctx, ml.async_cond)

    # Blocks until libzenohc has drained any in-flight callbacks (they
    # bail on the closing flag) and invoked our drop trampoline.
    _handle_result(LibZenohC.z_undeclare_matching_listener(_move(ml.handle)))

    wait(ml.task)

    _teardown_callback(Val(:matching_status), ml.ctx, ml.async_cond)
    return nothing
end

"""
    matching_status(pub::Publisher) -> Bool

One-shot poll of `pub`'s current matching status. Returns `true` iff at
least one matching subscriber exists right now. For change
notifications use [`MatchingListener`](@ref).
"""
function matching_status(pub::Publisher)
    status = Ref{LibZenohC.z_matching_status_t}()
    rtc = LibZenohC.z_publisher_get_matching_status(_loan(pub.pub), status)
    _handle_result(rtc)
    return status[].matching
end

export MatchingListener, matching_status
