# ReusableGet — a synchronous, allocation-free request/reply primitive over a
# `Querier`. It pools the per-get apparatus (`CallbackCtx` ring + `uv_mutex`,
# `AsyncCondition`, reply closure box, options struct, payload box, reply slot) so
# that, at steady state, a `call!` issues a query and settles on the first reply with
# ZERO Julia-side allocation — no `Channel`, no spawned drain task, no per-call
# `Timer`/`CancellationToken`, no per-reply `Ref`. The request payload and the response
# decode are the caller's (and they can be made zero-alloc too: alias a reused encode
# buffer here, copy out on decode).
#
# How it stays correct (the invariants `call!` enforces):
#  • Re-arm, not re-init. `rearm_ctx!` zeroes the ring counters under the mutex and
#    keeps buf/ring/mutex/async; it never reallocs or re-inits the mutex.
#  • Drop-is-the-last-callback. libzenohc drops a get's reply closure exactly once,
#    after every reply callback and never concurrently. So observing `:closed` proves
#    the closure is gone and no foreign callback can touch the ctx. `call!` drains to
#    `:closed` before returning, so the *next* `call!` can re-arm race-free.
#  • Single-in-flight is enforced (atomic CAS that THROWS on reentry), not merely
#    documented — two concurrent gets would share one ring/closing flag and corrupt or
#    use-after-free. For concurrency, hold one `ReusableGet` per task (or a pool).
#  • Timeout lives on the querier (declare it with `timeout_ms > 0`): a timed-out get
#    still drops the closure, which both unblocks the caller and bounds the re-arm.
#  • The borrowed reply is valid only until the next `call!` (it lives in a reused
#    slot); the recycle epoch turns a use-after-recycle into a `BorrowError`.

"""
    ConcurrentUseError(msg)

Thrown by [`call!`](@ref) when a second call is attempted on a [`ReusableGet`](@ref)
that is already servicing one. A `ReusableGet` is single-in-flight by design — use one
per caller task, or a pool, for concurrency.
"""
struct ConcurrentUseError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ConcurrentUseError) = print(io, "ConcurrentUseError: ", e.msg)

"""
    ReusableGet(q::Querier; capacity::Integer=1)

A reusable, allocation-free request/reply handle over querier `q`. Allocates its whole
apparatus once; each [`call!`](@ref) re-arms it in place and settles on the first reply.

Declare `q` with an explicit `timeout_ms > 0` and (for the single-slot default)
`target = QueryTargets.BEST_MATCHING`: the timeout bounds how long `call!` waits for a
slow/absent server, and a single-reply target keeps the receive zero-alloc and the
returned reply unambiguous.

A `ReusableGet` is **single-in-flight**: concurrent `call!`s on the same instance throw
[`ConcurrentUseError`](@ref). For concurrency, use one per task or a small pool. It does
**not** own `q` — close the querier yourself. `close(rg)` tears down the apparatus.
"""
mutable struct ReusableGet
    querier    :: Querier
    ctx        :: CallbackCtx{LibZenohC.z_owned_reply_t}            # ring + mutex, allocated once
    async      :: Base.AsyncCondition                              # allocated once
    closurebox :: Base.RefValue{LibZenohC.z_owned_closure_reply_t} # reused; re-installed per get
    holder     :: ReplyHolder                                      # reused reply slot
    optsref    :: Base.RefValue{LibZenohC.z_querier_get_options_t}  # reused; re-poked per get
    payloadbox :: Base.RefValue{LibZenohC.z_owned_bytes_t}         # re-armed via z_bytes_from_buf
    attachbox  :: Base.RefValue{LibZenohC.z_owned_bytes_t}
    inflight   :: Threads.Atomic{Bool}                             # single-in-flight guard
    closed     :: Bool
end

function ReusableGet(q::Querier; capacity::Integer=1)
    ctx   = _make_callback_ctx(Val(:reply))         # CallbackCtx{z_owned_reply_t}
    async = Base.AsyncCondition()
    init_ctx!(ctx, async, capacity)                 # one-time: ring buffer + uv_mutex_init
    closurebox = _make_closure_ref(Val(:reply))     # Ref{z_owned_closure_reply_t}, no finalizer
    holder  = ReplyHolder()
    optsref = Ref{LibZenohC.z_querier_get_options_t}()
    LibZenohC.z_querier_get_options_default(optsref)
    payloadbox = Ref{LibZenohC.z_owned_bytes_t}(); LibZenohC.z_internal_bytes_null(payloadbox)
    attachbox  = Ref{LibZenohC.z_owned_bytes_t}(); LibZenohC.z_internal_bytes_null(attachbox)
    rg = ReusableGet(q, ctx, async, closurebox, holder, optsref,
                     payloadbox, attachbox, Threads.Atomic{Bool}(false), false)
    finalizer(_finalize_reusable_get, rg)
    return rg
end

# No-op deleter for the aliasing payload/attachment. Unlike `ZBytes(::Vector)` we register
# NO real deleter and do NOT `preserve_handle` the buffer: `call!` keeps the buffer alive
# (via `GC.@preserve`) until the get reaches `:closed`, i.e. past the send, after which
# zenoh no longer references it. Skipping `preserve_handle` removes its per-call IdDict
# bookkeeping — the last Julia-heap allocation on the payload path. zenoh still invokes
# this once when it drops its owned-bytes (post-send); doing nothing is safe on any thread.
_noop_release(::Ptr{Cvoid}, ::Ptr{Cvoid}) = C_NULL

# Re-arm a held owned-bytes box to ALIAS `buf[1:len]` zero-copy with the no-op deleter.
# The buffer's lifetime is the CALLER's responsibility — `call!` guarantees it via a
# `GC.@preserve` spanning the get + drain. Allocation-free (no `preserve_handle`; the
# `@cfunction` of a top-level function is a constant pointer).
function _arm_bytes!(box::Base.RefValue{LibZenohC.z_owned_bytes_t},
                     buf::Vector{UInt8}, len::Integer)
    0 <= len <= length(buf) || throw(BoundsError(buf, len))   # caller-supplied len
    _handle_result(GC.@preserve buf LibZenohC.z_bytes_from_buf(box, buf, Csize_t(len),
        @cfunction(_noop_release, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid})), C_NULL))
    return nothing
end

"""
    call!(rg::ReusableGet, parameters=""; payload=nothing, attachment=nothing,
          payload_len=length(payload), attachment_len=length(attachment),
          cancellation=nothing) -> ReplyHolder | nothing

Issue one query on `rg` and block until the first reply, returned as the pooled
[`ReplyHolder`](@ref) (`rg`'s reusable reply slot) — or `nothing` if the get completed
with no reply (timeout / no matching queryable / cancelled). Read it with [`is_ok`](@ref)
and [`sample`](@ref)/[`error_payload`](@ref) and **decode it (copying out) before the next
`call!`** — the slot is reused on the next call, so the holder and anything borrowed from
it (its `sample`, the sample's payload) are valid only until then (a zero-copy view held
across a `call!` throws `BorrowError`).

`payload` and `attachment`, when given as `Vector{UInt8}`, are aliased zero-copy (the
first `*_len` bytes) for the duration of the call — **do not mutate those buffers until
`call!` returns**. Returning the pooled holder (not a fresh wrapper) and aliasing the
buffers is what keeps a steady-state `call!` allocation-free on the Zenoh.jl side.

`cancellation` is an optional per-call deadline lever: pass a [`CancellationToken`](@ref)
(typically armed by a `Base.Timer`) and `cancel` it to abort this call — the get ends and
`call!` returns `nothing`. The querier's declared `timeout_ms` is the default bound; use
`cancellation` only when a call needs a different deadline (it allocates a token clone, so
the no-`cancellation` path stays allocation-free).

Single-in-flight: a concurrent `call!` on the same `rg` throws
[`ConcurrentUseError`](@ref).
"""
function call!(rg::ReusableGet, parameters::AbstractString="";
        payload::Union{Nothing,Vector{UInt8}}=nothing,
        attachment::Union{Nothing,Vector{UInt8}}=nothing,
        payload_len::Integer    = payload    === nothing ? 0 : length(payload),
        attachment_len::Integer = attachment === nothing ? 0 : length(attachment),
        cancellation::Union{Nothing,CancellationToken}=nothing)
    rg.closed && throw(ArgumentError("call! on a closed ReusableGet"))
    # Single-in-flight: claim the slot or bail. THROW (not block) — blocking would hide
    # the misuse, and two gets on one ctx is a use-after-free, not just contention.
    Threads.atomic_cas!(rg.inflight, false, true) == false ||
        throw(ConcurrentUseError("ReusableGet is single-in-flight; use one per task or a pool"))
    try
        # Safe to re-arm: any prior get drained to :closed below before returning, so its
        # closure is dropped and no foreign callback can race this reset.
        rearm_ctx!(rg.ctx)
        LibZenohC.z_querier_get_options_default(rg.optsref)   # clear stale moved-ptr fields
        params = parameters isa Union{String,SubString{String}} ? parameters : String(parameters)
        payload_armed = false
        attach_armed  = false
        # Optional per-call deadline. The get CONSUMES (moves) the token, so clone it — the
        # clone shares cancellation state with the caller's token (cancel it, e.g. from a
        # Base.Timer, to abort this call → :closed → call! returns nothing). The clone carries
        # its own finalizer, so a failed/never-issued get cleans up on GC; only the default
        # (no-token) path stays allocation-free. z_querier_get_options_default cleared field 5
        # above, so omitting it leaves no stale token.
        cancel_clone = cancellation === nothing ? nothing : _clone(cancellation)
        # The aliased payload/attachment carry a no-op deleter, so their buffers MUST stay
        # live until zenoh has sent the query — no later than :closed. This GC.@preserve
        # spans the whole arming + get + drain, guaranteeing that without preserve_handle.
        got = GC.@preserve payload attachment params rg cancel_clone begin
            try
                if payload !== nothing
                    _arm_bytes!(rg.payloadbox, payload, payload_len); payload_armed = true
                    _store_field!(rg.optsref, 1, _move(rg.payloadbox))      # field 1: payload
                end
                if attachment !== nothing
                    _arm_bytes!(rg.attachbox, attachment, attachment_len); attach_armed = true
                    _store_field!(rg.optsref, 4, _move(rg.attachbox))       # field 4: attachment
                end
                cancel_clone === nothing ||
                    _store_field!(rg.optsref, 5, _move(cancel_clone))       # field 5: cancellation_token
                # Hold the querier's lock across the loan + get so a concurrent close can't gravestone the
                # handle; scoped to just the C call, not the wait/drain below — blocking under
                # the lock would serialize calls and deadlock close. Uncontended @lock is
                # alloc-free, so the hot path stays zero-alloc.
                @lock rg.querier.lock begin
                    if rg.querier.closed
                        # Undeclared concurrently → the get is moot. Drain returns :closed below.
                        payload_armed && LibZenohC.z_bytes_drop(_move(rg.payloadbox))
                        attach_armed  && LibZenohC.z_bytes_drop(_move(rg.attachbox))
                        payload_armed = false; attach_armed = false
                        signal_closing!(rg.ctx, rg.async)                   # so _ring_take_into! / drain see :closed
                    else
                        _install_closure!(Val(:reply), rg.closurebox, rg.ctx)  # fresh closure into reused box
                        rtc = LibZenohC.z_querier_get_with_parameters_substr(
                            _loan(rg.querier), Ptr{Cchar}(pointer(params)), ncodeunits(params),
                            _move(rg.closurebox), rg.optsref)
                        rtc == LibZenohC.Z_OK || _handle_result(rtc)
                        payload_armed = false; attach_armed = false         # consumed (moved into the get)
                    end
                end
            catch
                # Reclaim any armed-but-unconsumed bytes. A drop of an already-consumed/null
                # box is a no-op (gravestone), so this is safe whether or not the failed get
                # consumed them.
                payload_armed && LibZenohC.z_bytes_drop(_move(rg.payloadbox))
                attach_armed  && LibZenohC.z_bytes_drop(_move(rg.attachbox))
                rethrow()
            end
            # Settle on the first reply: drop the previous call's occupant (recycle —
            # invalidates any view held past here), then block for the first reply or for
            # :closed (timeout / no queryable, bounded by the querier's timeout_ms).
            _drop_current!(rg.holder)
            g = _ring_take_into!(rg.holder.r, rg.ctx, rg.async)
            # Drain to :closed so libzenohc has dropped this get's closure before the next
            # call! re-arms the ctx — and so the payload buffer is done being sent. For
            # BEST_MATCHING the only post-reply event is the terminal drop, so this just
            # awaits :closed (zero-alloc — no extra replies).
            _drain_to_closed!(rg)
            g
        end
        # Return the pooled holder (already allocated — no Reply wrapper) or nothing.
        return got ? rg.holder : nothing
    finally
        rg.inflight[] = false
    end
end

# Await this get's completion — the closure drop sets `closing`, surfaced as `:closed`.
# Discards any further replies (redundant servers under non-BEST_MATCHING targets)
# without touching the holder, so the settled reply stays intact. Zero-alloc on the
# BEST_MATCHING path: with no extra replies `_ring_pop!` only yields `:empty`/`:closed`.
function _drain_to_closed!(rg::ReusableGet)
    while true
        r = _ring_pop!(rg.ctx)
        if r isa Base.RefValue
            LibZenohC.z_reply_drop(_move(r))            # extra reply: discard
        elseif r === :closed
            return
        else                                            # :empty — wait for the next wake
            try
                wait(rg.async)
            catch
                return                                  # async closed (teardown)
            end
        end
    end
end

"""
    close(rg::ReusableGet)

Tear down the reusable apparatus (drops the last settled reply, destroys the ring mutex,
closes the async condition). The caller must ensure no `call!` is in flight. Does not
close the underlying `Querier`.
"""
function Base.close(rg::ReusableGet)
    rg.closed && return nothing
    rg.closed = true
    _drop_current!(rg.holder)                           # drop the last settled reply (gravestones the box)
    # The last call! drained to :closed, so the closure is gone and the ring is quiescent —
    # safe to destroy the mutex on the caller's task. `close_async=false` because the drop
    # trampoline's terminal `uv_async_send` may still be in flight on a foreign thread; closing
    # the uv handle here would race it, so leave it to the AsyncCondition's own finalizer.
    _teardown_callback(Val(:reply), rg.ctx, rg.async; close_async=false)
    return nothing
end

# GC safety net for an abandoned ReusableGet. Spawn the teardown on a normal task so
# close(async) is legal (vs. finalizer task-switch limits), mirroring the buffered
# subscriber's finalizer.
_finalize_reusable_get(rg::ReusableGet) =
    rg.closed || Threads.@spawn _teardown_reusable_get!(rg)
function _teardown_reusable_get!(rg::ReusableGet)
    rg.closed && return nothing
    rg.closed = true
    _teardown_callback(Val(:reply), rg.ctx, rg.async)
    return nothing
end

export ReusableGet, call!, ConcurrentUseError
