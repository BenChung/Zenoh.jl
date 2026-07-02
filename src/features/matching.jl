# Matching listener — notification when a publisher's keyexpr starts /
# stops having subscribers, or when a querier's keyexpr starts / stops
# having matching queryables.
#
# Payload type is the POD `z_matching_status_t` (one Bool), so this
# rides the `:pod`-shape `@closure_kind :matching_status` in
# `closure_kinds.jl` — no clone/drop, no channel handlers. The
# foreground lifecycle mirrors `LivelinessSubscriber` / `Queryable`:
# signal closing → undeclare → wait task → teardown.
#
# ═══════════════════════════════════════════════════════════════════════
# TODO(background-matching-listener):
# `z_publisher_declare_background_matching_listener` and
# `z_querier_declare_background_matching_listener` aren't wrapped. Same
# reasoning as background liveliness / background queryable: no handle
# is returned, so the closure lifetime must be tied to the publisher /
# querier (or session); a small follow-up once a unified
# background-callback pin policy exists.
# ═══════════════════════════════════════════════════════════════════════

@inline _matching_unwrap(r::Base.RefValue{LibZenohC.z_matching_status_t}) =
    r[].matching

"""
    MatchingListener

Foreground matching listener returned by
`MatchingListener(f, ::Publisher)` or `MatchingListener(f, ::Querier)`.
`f(::Bool)` is invoked on a dedicated Julia task each time the matching
set transitions between empty and non-empty:

- `f(true)`  — at least one matching peer now exists
- `f(false)` — the last matching peer went away

For a Publisher the peers are subscribers; for a Querier they are
queryables.

Single-slot latest-wins semantics — see [`Subscriber`](@ref). For
matching status this is rarely a concern (transitions are infrequent
and idempotent), and the slow-consumer worst case is just seeing the
final state rather than every intermediate flip.

Call `close(ml)` to undeclare. A finalizer drops an abandoned listener as a
safety net.
"""
mutable struct MatchingListener
    handle::Base.RefValue{LibZenohC.z_owned_matching_listener_t}
    ctx::CallbackCtx{LibZenohC.z_matching_status_t}
    async_cond::Base.AsyncCondition
    task::Task
    target::Union{AbstractPublisher, Querier}  # GC pin — listener references the target internally
    closed::Bool
end

# Shared declare-and-spawn machinery. `declare_fn(handle, closure) -> rtc`
# picks the C entrypoint (publisher vs querier variant).
function _matching_listener_setup(declare_fn::F, f::Function, target,
        should_close_on_error::Bool) where F
    ctx, async_cond, closure = _setup_callback(Val(:matching_status))

    handle = Ref{LibZenohC.z_owned_matching_listener_t}()
    rtc = GC.@preserve ctx declare_fn(handle, closure)
    if rtc != LibZenohC.Z_OK
        # declare failed before the closure was installed → its drop
        # trampoline fires via z_closure_matching_status's own
        # ownership machinery. Just clean Julia-side.
        _teardown_callback(Val(:matching_status), ctx, async_cond)
        _handle_result(rtc)
    end

    task = Threads.@spawn consume(f, _matching_unwrap, ctx, async_cond,
        should_close_on_error)
    ml = MatchingListener(handle, ctx, async_cond, task, target, false)
    finalizer(_finalize_matching_listener, ml)
    return ml
end

# GC safety net for an abandoned MatchingListener: its ctx cluster gets collected while the
# still-installed C closure keeps firing match transitions into the freed ctx from a foreign
# thread. Drop the listener handle first to stop that delivery, then tear down in close(ml)'s
# order. Spawn on a normal task — finalizers can't `wait`/`close`.
_finalize_matching_listener(ml::MatchingListener) =
    ml.closed || Threads.@spawn _teardown_matching_listener!(ml)

function _teardown_matching_listener!(ml::MatchingListener)
    ml.closed && return nothing
    ml.closed = true
    signal_closing!(ml.ctx, ml.async_cond)
    LibZenohC.z_matching_listener_drop(_move(ml.handle))   # stop foreign delivery (drop, not undeclare)
    wait(ml.task)
    _teardown_callback(Val(:matching_status), ml.ctx, ml.async_cond)
    return nothing
end

"""
    MatchingListener(f, pub::Publisher; should_close_on_error=true)

Declare a matching listener on `pub` and invoke `f(::Bool)` on each
matching-status transition (i.e. when a subscriber arrives or the last
subscriber departs). See [`MatchingListener`](@ref) for semantics.
"""
function MatchingListener(f::Function, pub::Publisher;
        should_close_on_error::Bool=true)
    # Hold `pub.lock` across the declare so a concurrent close can't undeclare `pub.pub`
    # mid-declare; bail if already closed. The consume task spawned under the lock never takes
    # `pub.lock`, so the hold can't deadlock.
    @lock pub.lock begin
        pub.closed && throw(ArgumentError("MatchingListener on a closed Publisher"))
        _matching_listener_setup(f, pub, should_close_on_error) do handle, closure
            LibZenohC.z_publisher_declare_matching_listener(
                _loan(pub.pub), handle, _move(closure))
        end
    end
end

"""
    MatchingListener(f, q::Querier; should_close_on_error=true)

Declare a matching listener on querier `q` and invoke `f(::Bool)` on
each matching-status transition (i.e. when a queryable arrives or the
last queryable departs). See [`MatchingListener`](@ref) for semantics.
"""
function MatchingListener(f::Function, q::Querier;
        should_close_on_error::Bool=true)
    # Hold `q.lock` across the declare so a concurrent close can't undeclare `q.querier`
    # mid-declare; bail if already closed. The consume task spawned under the lock never takes
    # `q.lock`, so the hold can't deadlock.
    @lock q.lock begin
        q.closed && throw(ArgumentError("MatchingListener on a closed Querier"))
        _matching_listener_setup(f, q, should_close_on_error) do handle, closure
            LibZenohC.z_querier_declare_matching_listener(
                _loan(q), handle, _move(closure))
        end
    end
end

# NB: the AdvancedPublisher methods for MatchingListener / matching_status
# live in features/advanced_pubsub.jl — that type is declared there, after
# this file, so its method signatures can't be written here.

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
    @lock pub.lock begin
        pub.closed && return false       # a closed publisher has no matching peers
        _handle_result(LibZenohC.z_publisher_get_matching_status(_loan(pub.pub), status))
    end
    return status[].matching
end

"""
    matching_status(q::Querier) -> Bool

One-shot poll of `q`'s current matching status. Returns `true` iff at
least one matching queryable exists right now. For change notifications
use [`MatchingListener`](@ref).
"""
function matching_status(q::Querier)
    status = Ref{LibZenohC.z_matching_status_t}()
    @lock q.lock begin
        q.closed && return false         # a closed querier has no matching peers
        _handle_result(LibZenohC.z_querier_get_matching_status(_loan(q), status))
    end
    return status[].matching
end

export MatchingListener, matching_status
