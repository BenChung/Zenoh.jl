"""
    Reply

A response to a `get` call. Use `is_ok(r)` to discriminate, then
`sample(r)` for success or `error_payload(r)`/`error_encoding(r)` for the
error branch.
"""
struct Reply{R <: Union{Base.RefValue{LibZenohC.z_owned_reply_t},
                        Ptr{LibZenohC.z_loaned_reply_t}}}
    r::R
end
Reply(p::Ptr{LibZenohC.z_loaned_reply_t}) =
    Reply{Ptr{LibZenohC.z_loaned_reply_t}}(p)
function Reply(r::Base.RefValue{LibZenohC.z_owned_reply_t})
    finalizer(x -> LibZenohC.z_reply_drop(_move(x)), r)
    return Reply{Base.RefValue{LibZenohC.z_owned_reply_t}}(r)
end

_loaned_reply(r::Reply{Ptr{LibZenohC.z_loaned_reply_t}}) = r.r
_loaned_reply(r::Reply{Base.RefValue{LibZenohC.z_owned_reply_t}}) = _loan(r.r)

"""
    is_ok(r::Reply) -> Bool

Discriminates a [`Reply`](@ref): `true` when it carries a successful
[`Sample`](@ref) (read it with [`sample`](@ref)), `false` when it carries an
error (read it with [`error_payload`](@ref) / [`error_encoding`](@ref)).
"""
is_ok(r::Reply) = LibZenohC.z_reply_is_ok(_loaned_reply(r))

"""
    sample(r::Reply) -> Sample

The [`Sample`](@ref) carried by a successful [`Reply`](@ref). The returned
sample borrows from `r`, which it keeps alive while reachable. Throws
`ArgumentError` on an error reply — guard with [`is_ok`](@ref) first.
"""
function sample(r::Reply)
    is_ok(r) || throw(ArgumentError("Reply is an error; check is_ok(r) first"))
    # Pass `r` as owner: the returned Sample borrows from the reply, so it
    # must keep the reply alive while reachable.
    return Sample(LibZenohC.z_reply_ok(_loaned_reply(r)), r)
end

"""
    error_payload(r::Reply) -> ZBytes

The error payload of an error [`Reply`](@ref), as a [`ZBytes`](@ref) borrowing
`r`. Throws `ArgumentError` on a successful reply — guard with [`is_ok`](@ref)
first; pair with [`error_encoding`](@ref) to interpret the bytes.
"""
function error_payload(r::Reply)
    is_ok(r) && throw(ArgumentError("Reply is ok; no error payload"))
    return ZBytes(LibZenohC.z_reply_err_payload(LibZenohC.z_reply_err(_loaned_reply(r))), r)
end

"""
    error_encoding(r::Reply) -> Encoding

The [`Encoding`](@ref) of an error [`Reply`](@ref)'s payload, describing how to
interpret [`error_payload`](@ref). Throws `ArgumentError` on a successful
reply — guard with [`is_ok`](@ref) first.
"""
function error_encoding(r::Reply)
    is_ok(r) && throw(ArgumentError("Reply is ok; no error encoding"))
    return _from_loaned_encoding(LibZenohC.z_reply_err_encoding(LibZenohC.z_reply_err(_loaned_reply(r))))
end

# ── Reusable reply slot (zero-allocation receive for ReusableGet) ─────
#
# The Reply analogue of `SampleHolder`: one caller-owned `z_owned_reply_t` box,
# refilled in place by `_ring_take_into!` (no per-reply `Ref`), with a recycle epoch
# so a borrowed `Reply` over it detects a later in-place refill. Driven by
# `ReusableGet` (features/reusable_get.jl).

"""
    ReplyHolder

The pooled reply slot a [`ReusableGet`](@ref) settles into. [`call!`](@ref) returns the same
`ReplyHolder` every call and refills it in place, so a steady-state get allocates nothing on the
receive side. Read the settled reply with [`is_ok`](@ref), then [`sample`](@ref) on success or
[`error_payload`](@ref) / [`error_encoding`](@ref) on error.

Its contents — and anything borrowed from them (the [`sample`](@ref)'s payload, key expression, and
attachment) — stay valid only until the next [`call!`](@ref) reuses the slot. Copy out what you need
before then; a borrowed view used across a `call!` throws a `BorrowError`, caught by the slot's
recycle epoch.
"""
mutable struct ReplyHolder
    r::Base.RefValue{LibZenohC.z_owned_reply_t}
    epoch::_RecycleEpoch     # bumped on each in-place refill; borrowed replies capture it
end
function ReplyHolder()
    r = Ref{LibZenohC.z_owned_reply_t}()
    LibZenohC.z_internal_reply_null(r)              # gravestone: drop of a null reply is a no-op
    h = ReplyHolder(r, _RecycleEpoch())
    # Bump in the finalizer too: a borrow built via `_borrow_reply(h.r, h.epoch)` pins
    # h.r/h.epoch but not `h`, so a finalize-time drop must invalidate it.
    finalizer(hh -> (_bump!(hh.epoch); LibZenohC.z_reply_drop(_move(hh.r))), h)
    return h
end
# Drop the holder's current occupant (no-op on the gravestone), bumping the epoch
# FIRST so a borrow still held over the previous occupant fails `_check_token` rather
# than reading the recycled slot. `z_reply_drop` gravestones the box, so the
# finalizer's later drop is a no-op (no double free).
@inline _drop_current!(h::ReplyHolder) = (_bump!(h.epoch); LibZenohC.z_reply_drop(_move(h.r)))

# Accessors on a settled `ReplyHolder` — what `call!` returns. They read the held reply
# in place (no new owned handle, no `Reply` wrapper allocation). A `Sample`/`ZBytes`
# borrowed from the holder pins it and rides its recycle epoch, so a zero-copy view over
# the payload throws `BorrowError` if used after the next `call!` refills the slot. The
# holder handle itself is valid only until the next `call!` — decode out before then.
is_ok(h::ReplyHolder) = LibZenohC.z_reply_is_ok(_loan(h.r))
function sample(h::ReplyHolder)
    is_ok(h) || throw(ArgumentError("Reply is an error; check is_ok(h) first"))
    return Sample(LibZenohC.z_reply_ok(_loan(h.r)), h)
end
function error_payload(h::ReplyHolder)
    is_ok(h) && throw(ArgumentError("Reply is ok; no error payload"))
    return ZBytes(LibZenohC.z_reply_err_payload(LibZenohC.z_reply_err(_loan(h.r))), h)
end
function error_encoding(h::ReplyHolder)
    is_ok(h) && throw(ArgumentError("Reply is ok; no error encoding"))
    return _from_loaned_encoding(LibZenohC.z_reply_err_encoding(LibZenohC.z_reply_err(_loan(h.r))))
end
@inline _token(h::ReplyHolder) = (h.epoch, h.epoch.gen)
@inline _token_owner(h::ReplyHolder) = _token(h)

# ── Buffered (ring) delivery ──────────────────────────────────────────
#
# `open(s, k; channel=:fifo)`, `Queryable(s, k; channel=…)`, and the channel
# `get` are all delivered by the capacity-bounded callback ring in
# `callback.jl` (filled on libzenohc's I/O thread, drained on a Julia task) —
# NOT by a blocking libzenohc FIFO/ring handler pulled on a `@threadcall`
# worker. The ring is slot-free: an arbitrary number of buffered endpoints can
# coexist without exhausting the `Base.threadcall_restrictor` (sem_size 4).
#
# Overflow is drop-oldest (ROS `KEEP_LAST`): when the consumer falls behind,
# the oldest buffered item is evicted and counted in `dropped_count`. The I/O
# thread never blocks. For lossless backpressure (block the publisher, at the
# cost of stalling the shared RX thread), the native libzenohc FIFO handlers in
# `closure_kinds.jl` are available, but nothing routes to them by default.
#
# Two consumption shapes:
#   • Buffered subscriber/queryable (infinite stream, keep-last-N): the caller
#     pulls the ring directly via `_ring_take` / `_ring_pop!` — one bounded
#     buffer, clean drop-oldest. Teardown is deferred to a finalizer (a
#     concurrent iterate may still touch the ctx; reachability is the interlock).
#   • Channel `get` (finite reply set): a consume task drains the ring into a
#     `Base.Channel{Reply}`; the task owns the ctx lifetime until the get
#     completes (drop trampoline fires), which makes abandonment safe (no
#     undeclare exists for a get).

# ── Buffered subscriber handler ───────────────────────────────────────

# Abstract supertype shared with AdvancedSubscriberHandler /
# LivelinessSubscriberHandler. Concrete subtypes hold the same fields
# (sub, ctx, async_cond, keyexpr, closed); only the owned-handle type of `sub`
# differs (z_owned_subscriber_t vs ze_owned_advanced_subscriber_t), which
# `_handler_sub_handle` / `_drop_sub_handle` / `_undeclare_sub_handle` adapt.
abstract type AbstractSubscriberHandler end

"""
    SubscriberHandler

Buffered subscriber returned by `Base.open(s, k; channel=:fifo, capacity=N)`.
Iterate or use `take!`/`tryrecv!` to consume `Sample`s. Iteration terminates
once the subscriber is closed and the buffer is drained.

Delivery is the slot-free callback ring: samples land in a Julia-side
capacity-`N` ring on libzenohc's I/O thread and are pulled here on the
consuming task. When the consumer falls behind, the oldest buffered sample is
dropped (`dropped_count(sub)` counts evictions). Other Julia tasks — including
`close(sub)` from a sibling task — run concurrently while iteration waits.

!!! note "Iteration lifetime"
    `for s in sub` reuses one buffer per loop for zero per-sample allocation, so
    a yielded `Sample` is valid **only until the next iteration** — don't stash
    it across iterations or `collect` it. Use `take!` (or a `:keep_all`
    subscriber) when you need to hold a sample beyond the current step.
"""
mutable struct SubscriberHandler <: AbstractSubscriberHandler
    sub::Base.RefValue{LibZenohC.z_owned_subscriber_t}
    ctx::CallbackCtx{LibZenohC.z_owned_sample_t}
    async_cond::Base.AsyncCondition
    keyexpr::AbstractKeyexpr     # GC pin
    closed::Bool
end

# The owned-handle C type backing a buffered handler `T` — read off its `sub`
# field so the shared `_open_buffered_sub` allocates the right Ref without a
# hardcoded type.
_handler_sub_handle(::Type{T}) where {T<:AbstractSubscriberHandler} =
    eltype(fieldtype(T, :sub))

# Drop / undeclare for a buffered handler's owned `sub`, dispatched on the
# handle's Ref type. Default targets the data-plane subscriber;
# AdvancedSubscriberHandler's ze_owned_advanced_subscriber_t variants live in
# advanced_pubsub.jl.
_drop_sub_handle(s::Base.RefValue{LibZenohC.z_owned_subscriber_t}) =
    LibZenohC.z_subscriber_drop(_move(s))
_undeclare_sub_handle(s::Base.RefValue{LibZenohC.z_owned_subscriber_t}) =
    LibZenohC.z_undeclare_subscriber(_move(s))

# Shared buffered-subscriber construction. `declare_fn(sub, closure) -> rtc`
# picks the C declare entrypoint (data vs. liveliness vs. advanced) and
# supplies any extra options. `T` is the concrete handler type to construct;
# its `sub` handle type is derived from `T`.
function _open_buffered_sub(declare_fn::F, ::Type{T}, k::AbstractKeyexpr,
        capacity::Integer, channel::Symbol) where {F, T<:AbstractSubscriberHandler}
    # KEEP_ALL routes to the heap-backed consume-task form (no drop-oldest).
    channel === :keep_all &&
        return _open_keepall_sub(declare_fn, _handler_sub_handle(T), k, capacity)
    ctx, async_cond, closure = _setup_callback(Val(:sample), capacity)
    sub = Ref{_handler_sub_handle(T)}()
    rtc = GC.@preserve ctx declare_fn(sub, closure)
    if rtc != LibZenohC.Z_OK
        # declare failed before the closure was installed → its drop cb fires
        # via z_closure_sample's own ownership machinery. Just clean Julia-side.
        _teardown_callback(Val(:sample), ctx, async_cond)
        _handle_result(rtc)
    end
    sh = T(sub, ctx, async_cond, k, false)
    finalizer(_finalize_buffered_sub, sh)
    return sh
end

# Iteration reuses a single owned box (the iterate state), refilled in place
# each step — no per-item finalizer (the box carries one finalizer as a
# break-safety net, per loop not per item; each step drops the previous
# occupant first, so the drop is also prompt). It yields a concrete `Sample`
# borrowing that box, so `::Sample` call sites keep working. The yielded sample
# is valid only until the next iteration — don't stash it or `collect` it (use
# `take!`, or `:keep_all`, for owned samples; `recv!` for a zero-alloc loop).
# Mirrors the channel `Queryable` query contract.
# Iterate state carrier: the reusable owned-sample box plus its recycle epoch.
# The epoch is bumped each step so a view held over the previous occupant fails
# `_check_token` (BorrowError) instead of reading the recycled slot.
mutable struct _IterBox
    s::Base.RefValue{LibZenohC.z_owned_sample_t}
    epoch::_RecycleEpoch
end

function Base.iterate(sh::AbstractSubscriberHandler, box=nothing)
    if box === nothing
        # Fresh box: `Ref{z_owned_sample_t}()` is UNINITIALISED memory. Take first and
        # arm the break-safety finalizer only once the box owns a real sample — if the
        # take fails before any item (closed/drained), the Ref is dropped by GC as plain
        # memory with no `z_sample_drop`, never as a garbage owned-sample (which would
        # segfault `drop_in_place` at finalize/atexit).
        s = Ref{LibZenohC.z_owned_sample_t}()
        _ring_take_into!(s, sh.ctx, sh.async_cond) || return nothing
        box = _IterBox(s, _RecycleEpoch())
        # Bump in the break-safety finalizer too: a zero-copy view held past a
        # `break` pins box.s/box.epoch but NOT this _IterBox wrapper, so when the
        # wrapper is finalized it must invalidate that view — every recycle site
        # bumps before dropping, or the freed buffer would be read silently.
        finalizer(b -> (_bump!(b.epoch); LibZenohC.z_sample_drop(_move(b.s))), box)
        return (_borrow_sample(box.s, box.epoch), box)
    end
    _bump!(box.epoch)                               # invalidate views over the previous occupant
    LibZenohC.z_sample_drop(_move(box.s))           # drop previous occupant promptly
    # `_move` left the box in the null gravestone, so the finalizer is safe even if the
    # refill below fails (drop of a null owned sample is a no-op).
    _ring_take_into!(box.s, sh.ctx, sh.async_cond) || return nothing
    return (_borrow_sample(box.s, box.epoch), box)
end

"""
    take!(sh::AbstractSubscriberHandler) -> Sample

Block until the next buffered sample arrives and return it as an owned
[`Sample`](@ref). Throws [`ZenohError`](@ref) once the subscriber is closed and
its buffer is drained. [`tryrecv!`](@ref) is the non-blocking counterpart;
[`recv!`](@ref) with a [`SampleHolder`](@ref) is the allocation-free loop.
"""
function Base.take!(sh::AbstractSubscriberHandler)
    r = _ring_take(sh.ctx, sh.async_cond)
    r === nothing && throw(ZenohError(LibZenohC.Z_CHANNEL_DISCONNECTED))
    return Sample(r)
end

"""
    tryrecv!(sub) -> Sample | Reply | nothing
    tryrecv!(sub::AbstractSubscriberHandler, h::SampleHolder) -> h | nothing

Non-blocking receive: returns the next buffered item — a [`Sample`](@ref) from a
buffered subscriber, a [`Reply`](@ref) from a [`GetHandler`](@ref) — or `nothing`
when nothing is buffered (or the endpoint is closed and drained). The
[`SampleHolder`](@ref) method fills `h` in place (dropping its previous occupant)
for an allocation-free poll loop, returning `h` or `nothing`.

The non-blocking counterpart to [`take!`](@ref) / [`recv!`](@ref): poll it when
you want to do other work rather than park waiting for an item.
"""
function tryrecv!(sh::AbstractSubscriberHandler)
    r = _ring_pop!(sh.ctx)
    r isa Base.RefValue && return Sample(r)
    return nothing                                  # :empty or :closed
end

"""
    recv!(sub, holder::SampleHolder) -> holder | nothing

Zero-allocation receive: block for the next sample and fill `holder` in place
(dropping its previous occupant), returning `holder`, or `nothing` once the
subscriber is closed and drained. Reuse one `holder` across calls for an
allocation-free receive loop:

    h = SampleHolder()
    while (s = recv!(sub, h)) !== nothing
        # process s now — it (and its payload/keyexpr/…) is valid only until the
        # next recv!; don't stash it
    end
"""
function recv!(sh::AbstractSubscriberHandler, h::SampleHolder)
    _drop_current!(h)
    _ring_take_into!(h.s, sh.ctx, sh.async_cond) || return nothing
    return h
end

# Non-blocking in-place variant: fills `holder` and returns it, or `nothing` if
# nothing is buffered.
function tryrecv!(sh::AbstractSubscriberHandler, h::SampleHolder)
    _drop_current!(h)
    _ring_pop_into!(h.s, sh.ctx) || return nothing
    return h
end

# Advisory: samples dropped to ring overflow since declare.
dropped_count(sh::AbstractSubscriberHandler) = dropped_count(sh.ctx)

function Base.close(sh::AbstractSubscriberHandler)
    sh.closed && return
    sh.closed = true
    signal_closing!(sh.ctx, sh.async_cond)          # closing=1 + wake any parked pull
    _handle_result(_undeclare_sub_handle(sh.sub))   # foreign side quiescent after this
    # ctx teardown deferred to the finalizer: a concurrent iterate on another
    # task may still be inside _ring_take. After close, closing=1 means it
    # drains remnants then returns nothing (it never parks again).
    return nothing
end

# Finalizer: runs only when nothing references `sh`, so no iterate can be in
# flight (a parked pull holds `sh`). Spawns the teardown on a normal task so
# `close(async_cond)` is legal (vs. finalizer task-switch limits) and so the
# AsyncCondition stays alive across the safety-net undeclare's drop trampoline.
_finalize_buffered_sub(sh::AbstractSubscriberHandler) =
    Threads.@spawn _teardown_buffered_sub!(sh)

function _teardown_buffered_sub!(sh::AbstractSubscriberHandler)
    if !sh.closed
        sh.closed = true
        _drop_sub_handle(sh.sub)                    # GC safety net: stop foreign side
    end
    _teardown_callback(Val(:sample), sh.ctx, sh.async_cond)
    return nothing
end

Base.IteratorSize(::Type{<:AbstractSubscriberHandler}) = Base.SizeUnknown()
# Both `for s in sub` and `take!` yield a `Sample`; `recv!` fills a `SampleHolder`.
Base.eltype(::Type{<:AbstractSubscriberHandler}) = Sample

# ── KEEP_ALL buffered subscriber ─────────────────────────────────────
#
# History KEEP_ALL: no drop-oldest. A consume task drains the bounded ring
# (slot-free) into an unbounded, heap-backed `Channel{Sample}`. The task's
# pop+`put!` far outpaces zenoh delivery, so the ring stays near-empty (it
# never blocks the IO thread and effectively never drops); the backlog
# accumulates on the Julia heap, bounded only by memory — which is exactly
# ROS2 KEEP_ALL's "keep all up to resource limits" (OOM, not deadlock, under
# sustained overload). Generic over the subscriber handle type `H` (data /
# advanced / liveliness) so one type serves all three.
#
# Buffering is reimplemented in Julia because libzenohc's FIFO handler exposes
# no push notification to drive a slot-free drain.
"""
    KeepAllSubscriber

Lossless buffered subscriber returned by `Base.open(s, k; channel=:keep_all)`.
Iterate or use [`take!`](@ref)/[`tryrecv!`](@ref) to consume [`Sample`](@ref)s;
iteration terminates once the subscriber is closed and the backlog is drained.

Keeps every matching sample (ROS `KEEP_ALL`): a consume task drains the
slot-free callback ring into an unbounded, heap-backed `Channel{Sample}`, so the
ring stays near-empty and the I/O thread never blocks. The backlog accumulates
on the Julia heap, bounded only by memory — sustained overload exhausts memory
rather than deadlocking. Yielded samples are owned and safe to hold across
iterations, unlike the per-step samples of a drop-oldest
[`SubscriberHandler`](@ref).
"""
mutable struct KeepAllSubscriber{H}
    sub::Base.RefValue{H}
    ctx::CallbackCtx{LibZenohC.z_owned_sample_t}
    async_cond::Base.AsyncCondition
    ch::Channel{Sample}
    task::Task
    keyexpr::AbstractKeyexpr     # GC pin
    closed::Bool
end

# Drain the ring into `ch` until the subscriber is closed (drop trampoline sets
# closing → `_ring_pop!` returns :closed). Owns the ctx lifetime: keeps it
# alive while the foreign side may push, tears it down only after the closure
# is dropped. Abandonment is safe — the finalizer drops the sub handle, which
# fires the trampoline → :closed → we drain remnants, close `ch`, free the ctx.
function _drain_samples(ctx::CallbackCtx{LibZenohC.z_owned_sample_t},
        async_cond::Base.AsyncCondition, ch::Channel{Sample})
    completed = false
    try
        while !completed
            try
                wait(async_cond)
            catch
                break
            end
            while true
                r = _ring_pop!(ctx)
                if r isa Base.RefValue
                    try
                        put!(ch, Sample(r))     # unbounded → never blocks; throws iff ch closed
                    catch
                        # ch closed by abandonment: discard, keep draining to :closed.
                    end
                elseif r === :closed
                    completed = true
                    break
                else                            # :empty
                    break
                end
            end
        end
    finally
        isopen(ch) && close(ch)
        _teardown_callback(Val(:sample), ctx, async_cond; close_async=false)
    end
    return nothing
end

# Handoff-ring floor for KEEP_ALL. The user's `capacity` bounds nothing here
# (the heap Channel is unbounded), but the fixed foreign→Julia handoff ring
# must absorb a delivery burst before the consume task drains it, or it would
# drop. Size it generously; loss is still possible (and counted) only if a
# burst exceeds this before the task runs — strict no-loss awaits a Rust-side
# notifying FIFO handler.
const _KEEPALL_HANDOFF = 8192

function _open_keepall_sub(declare_fn::F, ::Type{H}, k::AbstractKeyexpr,
        capacity::Integer) where {F, H}
    ctx, async_cond, closure =
        _setup_callback(Val(:sample), max(capacity, _KEEPALL_HANDOFF))
    sub = Ref{H}()
    rtc = GC.@preserve ctx declare_fn(sub, closure)
    if rtc != LibZenohC.Z_OK
        _teardown_callback(Val(:sample), ctx, async_cond)
        _handle_result(rtc)
    end
    ch = Channel{Sample}(typemax(Int))          # unbounded (heap-backed)
    task = Threads.@spawn _drain_samples(ctx, async_cond, ch)
    sh = KeepAllSubscriber{H}(sub, ctx, async_cond, ch, task, k, false)
    finalizer(_finalize_keepall_sub, sh)
    return sh
end

Base.iterate(sh::KeepAllSubscriber, st=nothing) = iterate(sh.ch, st)
Base.take!(sh::KeepAllSubscriber) = take!(sh.ch)
tryrecv!(sh::KeepAllSubscriber) = isready(sh.ch) ? take!(sh.ch) : nothing
# KEEP_ALL never drops at the ring (the task keeps it drained); kept for a
# uniform handler API.
dropped_count(sh::KeepAllSubscriber) = dropped_count(sh.ctx)
Base.IteratorSize(::Type{<:KeepAllSubscriber}) = Base.SizeUnknown()
Base.eltype(::Type{<:KeepAllSubscriber}) = Sample

function Base.close(sh::KeepAllSubscriber)
    sh.closed && return
    sh.closed = true
    signal_closing!(sh.ctx, sh.async_cond)
    _handle_result(_undeclare_sub_handle(sh.sub))
    # The consume task observes :closed, drains remnants into ch, closes ch,
    # and tears down the ctx. Iteration ends when ch drains.
    return nothing
end

_finalize_keepall_sub(sh::KeepAllSubscriber) =
    sh.closed || Threads.@spawn _abandon_keepall_sub!(sh)

function _abandon_keepall_sub!(sh::KeepAllSubscriber)
    sh.closed && return
    sh.closed = true
    _drop_sub_handle(sh.sub)        # stop foreign side → trampoline → task sees :closed → teardown
    return nothing
end

# ── Channel-handler get / reply consumer ─────────────────────────────

"""
    GetHandler

Reply consumer returned by `Zenoh.get(s, k, params; ...)`. Iterate or use
`take!`/`tryrecv!` to consume `Reply`s. Iteration terminates once the remote
side stops sending (all peers replied or the timeout elapsed) — no explicit
close needed.

Replies are delivered by the callback ring (slot-free), drained on an internal
task into a `Channel`; that task also owns teardown once the get completes.
"""
mutable struct GetHandler
    ch::Channel{Reply}
    task::Task
end

# Consume task for the channel get: drain the ring into `ch` until the get
# completes (drop trampoline sets closing → `_ring_pop!` returns :closed). The
# task owns the ctx lifetime — it keeps it alive while libzenohc may still push
# replies, and tears it down only after the closure has been dropped, which is
# why an abandoned get (Channel closed by the finalizer) is still safe: we keep
# draining/discarding until :closed before freeing the ctx.
function _drain_replies(ctx::CallbackCtx{LibZenohC.z_owned_reply_t},
        async_cond::Base.AsyncCondition, ch::Channel{Reply})
    completed = false
    try
        while !completed
            try
                wait(async_cond)
            catch
                break                               # async_cond closed (unexpected pre-completion)
            end
            while true
                r = _ring_pop!(ctx)
                if r isa Base.RefValue
                    rep = Reply(r)
                    try
                        put!(ch, rep)               # blocks if full; throws if ch closed (abandoned)
                    catch
                        # ch closed by abandonment: discard `rep`, keep draining to :closed.
                    end
                elseif r === :closed
                    completed = true
                    break
                else                                # :empty
                    break
                end
            end
        end
    finally
        isopen(ch) && close(ch)
        # `close_async=false`: the GetHandler/Channel keep no live waiter on the
        # AsyncCondition once `ch` is closed, and the task may be torn down via
        # the finalizer; let the AsyncCondition's own finalizer close the handle.
        _teardown_callback(Val(:reply), ctx, async_cond; close_async=false)
    end
    return nothing
end

# Shared channel-get construction. `call_fn(closure) -> rtc` performs the C
# entrypoint (`z_get` / `z_querier_get` / `z_liveliness_get`) that consumes the
# reply closure. Mirrors `_open_buffered_sub` for the get side.
function _open_buffered_get(call_fn::F, capacity::Integer) where F
    ctx, async_cond, closure = _setup_callback(Val(:reply), capacity)
    rtc = call_fn(closure)
    if rtc != LibZenohC.Z_OK
        _teardown_callback(Val(:reply), ctx, async_cond)
        _handle_result(rtc)
    end
    ch = Channel{Reply}(capacity)
    task = Threads.@spawn _drain_replies(ctx, async_cond, ch)
    gh = GetHandler(ch, task)
    finalizer(g -> (isopen(g.ch) && close(g.ch)), gh)
    return gh
end

Base.iterate(gh::GetHandler, st=nothing) = iterate(gh.ch, st)
Base.take!(gh::GetHandler) = take!(gh.ch)
tryrecv!(gh::GetHandler) = isready(gh.ch) ? take!(gh.ch) : nothing
Base.close(::GetHandler) = nothing  # task self-tears-down on completion; finalizer covers abandonment

Base.IteratorSize(::Type{<:GetHandler}) = Base.SizeUnknown()
Base.eltype(::Type{<:GetHandler}) = Reply

# ── Get ──────────────────────────────────────────────────────────────

_query_target(::Val{:best_matching}) = LibZenohC.Z_QUERY_TARGET_BEST_MATCHING
_query_target(::Val{:all})           = LibZenohC.Z_QUERY_TARGET_ALL
_query_target(::Val{:all_complete})  = LibZenohC.Z_QUERY_TARGET_ALL_COMPLETE
_query_target(s::Symbol) = _query_target(Val(s))

_consolidation(::Val{:auto})      = LibZenohC.z_query_consolidation_auto()
_consolidation(::Val{:none})      = LibZenohC.z_query_consolidation_none()
_consolidation(::Val{:monotonic}) = LibZenohC.z_query_consolidation_monotonic()
_consolidation(::Val{:latest})    = LibZenohC.z_query_consolidation_latest()
_consolidation(s::Symbol) = _consolidation(Val(s))

# Coerce a `target=` / `consolidation=` argument to its raw libzenoh value.
# Accepts the typed singletons (`QueryTargets.ALL`) — the canonical,
# dispatch-checked form, consistent with the QoS enums — or a `Symbol`
# shorthand (`:all`), mirroring how `_as_encoding` accepts both an `Encoding`
# and a bare string.
_as_query_target(t::QueryTarget) = _raw(t)
_as_query_target(s::Symbol)      = _query_target(s)

_as_consolidation(c::QueryConsolidation) = _raw(c)
_as_consolidation(s::Symbol)             = _consolidation(s)

# Populate a Ref{z_get_options_t} from the shared `get` kwargs. Returns
# `(opts, payload_bytes, attach_bytes, enc_ref)`; callers GC.@preserve the
# three trailing values across the z_get call.
function _make_get_opts(;
        target::Union{Nothing, QueryTarget, Symbol} = nothing,
        consolidation::Union{Nothing, QueryConsolidation, Symbol} = nothing,
        timeout_ms::Integer = 0,
        payload = nothing,
        encoding::Union{Nothing, Encoding, AbstractString, Base.MIME} = nothing,
        attachment = nothing,
        congestion_control::Union{Nothing, CongestionControl} = nothing,
        priority::Union{Nothing, Priority}                    = nothing,
        express::Union{Nothing, Bool}                         = nothing,
        allowed_destination::Union{Nothing, Locality}         = nothing,
        accept_replies::Union{Nothing, ReplyKeyexpr}          = nothing,
        cancellation::Union{Nothing, CancellationToken}       = nothing)
    opts = Ref{LibZenohC.z_get_options_t}()
    LibZenohC.z_get_options_default(opts)
    optsP = Base.unsafe_convert(Ptr{LibZenohC.z_get_options_t}, opts)
    isnothing(target)        || (optsP.target        = _as_query_target(target))
    isnothing(consolidation) || (optsP.consolidation = _as_consolidation(consolidation))
    timeout_ms > 0           && (optsP.timeout_ms    = UInt64(timeout_ms))

    # Build the owned inputs; if a later build throws (e.g. a wrong-typed
    # attachment after a good payload), release the already-built finalizer-less
    # owned payload/attachment ZBytes on this task so they can't be orphaned
    # (enc_ref self-cleans via its finalizer; the token clone is built last).
    payload_bytes = nothing
    attach_bytes  = nothing
    enc_ref       = nothing
    cancel_clone  = nothing
    try
        payload_bytes = isnothing(payload)    ? nothing : ZBytes(payload)
        attach_bytes  = isnothing(attachment) ? nothing : ZBytes(attachment)
        enc_ref       = isnothing(encoding)   ? nothing : _to_owned_encoding(_as_encoding(encoding))
        # The get consumes (moves) the token; clone so the caller keeps theirs to cancel.
        cancel_clone  = isnothing(cancellation) ? nothing : _clone(cancellation)
    catch
        payload_bytes === nothing || close(payload_bytes)
        attach_bytes  === nothing || close(attach_bytes)
        rethrow()
    end
    isnothing(payload_bytes) || (optsP.payload    = _move(payload_bytes))
    isnothing(attach_bytes)  || (optsP.attachment = _move(attach_bytes))
    isnothing(enc_ref)       || (optsP.encoding   = _move(enc_ref))
    isnothing(cancel_clone)  || (optsP.cancellation_token = _move(cancel_clone))

    isnothing(congestion_control)  || (optsP.congestion_control  = _raw(congestion_control))
    isnothing(priority)            || (optsP.priority            = _raw(priority))
    isnothing(express)             || (optsP.is_express          = express)
    isnothing(allowed_destination) || (optsP.allowed_destination = _raw(allowed_destination))
    isnothing(accept_replies)      || (optsP.accept_replies      = _raw(accept_replies))

    return opts, payload_bytes, attach_bytes, enc_ref, cancel_clone
end

"""
    get(s::Session, k::Keyexpr, parameters=""; kwargs...) -> GetHandler

Issue a query on key expression `k`, returning a `GetHandler` over the
replies. Iterate it to consume each `Reply`.

Keyword arguments:
- `channel`            — accepted for compatibility; delivery is the callback
                         ring either way (drop-oldest on overflow)
- `capacity`           — channel buffer size (default 16)
- `target`             — `QueryTargets.BEST_MATCHING` / `ALL` / `ALL_COMPLETE`
                         (or the `:best_matching` / `:all` / `:all_complete` shorthand)
- `consolidation`      — `QueryConsolidations.AUTO` / `NONE` / `MONOTONIC` / `LATEST`
                         (or the `:auto` / `:none` / `:monotonic` / `:latest` shorthand)
- `timeout_ms`         — request timeout in milliseconds (`0` = no timeout)
- `payload`            — optional payload bytes (anything `ZBytes` accepts)
- `encoding`           — payload encoding (`Encoding`, MIME, or string)
- `attachment`         — optional attachment bytes
- `congestion_control` — `CongestionControls.BLOCK` or `DROP`
- `priority`           — `Priorities.REAL_TIME` … `BACKGROUND`
- `express`            — `Bool`; bypass batching
- `allowed_destination`— `Localities.ANY` / `SESSION_LOCAL` / `REMOTE`
- `accept_replies`     — `ReplyKeyexprs.ANY` or `MATCHING_QUERY`
- `cancellation`       — a [`CancellationToken`](@ref); `cancel` it to abort this get
"""
function Base.get(s::Session, k::AbstractKeyexpr, parameters::AbstractString="";
        channel::Symbol = :fifo,
        capacity::Integer = 16,
        kwargs...)
    opts, payload_bytes, attach_bytes, enc_ref, cancel_clone = _make_get_opts(; kwargs...)
    params = String(parameters)
    _open_buffered_get(capacity) do closure
        GC.@preserve payload_bytes attach_bytes enc_ref cancel_clone params opts begin
            LibZenohC.z_get(_loan(s), _loan(k),
                pointer(Base.unsafe_convert(Cstring, params)),
                _move(closure), opts)
        end
    end
end

export Reply, ReplyHolder, SubscriberHandler, KeepAllSubscriber, GetHandler, tryrecv!, recv!,
    is_ok, sample, error_payload, error_encoding
