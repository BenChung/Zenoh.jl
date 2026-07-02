# Cancellation token — a libzenoh handle that bounds an in-flight get
# (`z_get` / `z_querier_get` / `z_liveliness_get`). Pass `cancellation=tok` to a
# get, then `cancel(tok)` (e.g. from a deadline timer) to abort it; the get's
# reply stream ends. It's the only per-call bound a `Querier` get has, since
# `z_querier_get_options_t` carries no `timeout_ms` (that's declare-time only).
#
# `clone` shares the underlying cancellation flag, which is what lets a get own
# one handle (moved into its options) while the caller retains another to
# cancel. Standard owned-handle lifecycle (`new`/`drop`); `_move`/`_loan` are
# auto-generated in ownership.jl.

"""
    CancellationToken()

A fresh cancellation token. Pass it to a get via `cancellation=tok`, then call
[`cancel`](@ref) to abort that get — its reply stream ends. Handles produced by
cloning (done internally when a token is handed to a get) share one flag, so
cancelling the token you hold cancels the operation it was given to. `close(tok)`
drops it early; it is also dropped on GC.
"""
mutable struct CancellationToken
    tok::Base.RefValue{LibZenohC.z_owned_cancellation_token_t}
    closed::Bool
end

_loan(t::CancellationToken) = _loan(t.tok)
_move(t::CancellationToken) = _move(t.tok)

function CancellationToken()
    ref = Ref{LibZenohC.z_owned_cancellation_token_t}()
    _handle_result(LibZenohC.z_cancellation_token_new(ref))
    # GC safety net: drop if collected without an explicit close(). No-op once
    # close() (or a consuming get) has moved the handle out.
    finalizer(t -> LibZenohC.z_cancellation_token_drop(_move(t)), ref)
    return CancellationToken(ref, false)
end

# A second owned handle to the same cancellation flag. A get *consumes* (moves)
# the token handed to it, so the get-opts builders clone: move the clone into
# the options, return the clone for the caller to GC-preserve across the get's
# declare ccall, and leave the caller's original to cancel through.
function _clone(t::CancellationToken)
    t.closed && throw(ArgumentError("cancellation token is closed"))
    dst = Ref{LibZenohC.z_owned_cancellation_token_t}()
    GC.@preserve t LibZenohC.z_cancellation_token_clone(dst, _loan(t))
    finalizer(x -> LibZenohC.z_cancellation_token_drop(_move(x)), dst)
    return CancellationToken(dst, false)
end

"""
    cancel(t::CancellationToken)

Cancel the operation `t` (or the clone handed to a get) is bound to — the get's
reply stream ends promptly. Safe to call after the operation already finished.
"""
function cancel(t::CancellationToken)
    t.closed && return nothing     # gravestoned handle: loaning it would be UB
    GC.@preserve t _handle_result(LibZenohC.z_cancellation_token_cancel(_loan(t)))
    return nothing
end

"True if `t` has been cancelled."
function is_cancelled(t::CancellationToken)
    t.closed && return false       # gravestoned handle: loaning it would be UB
    return GC.@preserve t LibZenohC.z_cancellation_token_is_cancelled(_loan(t))
end

function Base.close(t::CancellationToken)
    t.closed && return nothing
    t.closed = true
    LibZenohC.z_cancellation_token_drop(_move(t.tok))
    return nothing
end

export CancellationToken, cancel, is_cancelled
