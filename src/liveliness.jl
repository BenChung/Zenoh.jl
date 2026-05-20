# Liveliness — token-based presence signalling.
#
# Three constructable entities, each its own type so dispatch is on
# the name (no `open` overloads, no submodule):
#   • LivelinessToken              — announce presence on a keyexpr
#   • LivelinessSubscriber         — callback form, latest-wins single slot
#   • LivelinessSubscriberHandler  — buffered form, :fifo / :ring channel
#
# Plus the verb `liveliness_get` for a one-shot snapshot — replies
# come back through the existing `GetHandler` plumbing, so no new
# type is needed there.
#
# All three reuse the data-plane callback/channel machinery
# (`_open_callback_sub`, `_open_buffered_sub`, `_callback_get`) by
# passing a declare/call function that targets the
# `z_liveliness_*` entrypoint with the right options struct.

# --- Token -----------------------------------------------------------

"""
    LivelinessToken(s::Session, k::Keyexpr)

Declare a liveliness token on `k`. The token signals "alive" to every
liveliness subscriber matching `k` for as long as it lives. Call
`close(t)` to withdraw explicitly; the finalizer drops on GC as a
safety net (a no-op on the null slot left by `close`).
"""
mutable struct LivelinessToken
    t::Base.RefValue{LibZenohC.z_owned_liveliness_token_t}
    keyexpr::Keyexpr  # GC pin
    closed::Bool
    function LivelinessToken(s::Session, k::Keyexpr)
        opts = Ref{LibZenohC.z_liveliness_token_options_t}()
        LibZenohC.z_liveliness_token_options_default(opts)
        tok = Ref{LibZenohC.z_owned_liveliness_token_t}()
        rtc = LibZenohC.z_liveliness_declare_token(_loan(s), tok, _loan(k), opts)
        _handle_result(rtc)
        finalizer(t -> LibZenohC.z_liveliness_token_drop(_move(t)), tok)
        return new(tok, k, false)
    end
end

function Base.close(t::LivelinessToken)
    t.closed && return
    t.closed = true
    _handle_result(LibZenohC.z_liveliness_undeclare_token(_move(t.t)))
    return nothing
end

# --- Shared options helpers ------------------------------------------

function _liveliness_sub_opts(history::Bool)
    opts = Ref{LibZenohC.z_liveliness_subscriber_options_t}()
    LibZenohC.z_liveliness_subscriber_options_default(opts)
    Base.unsafe_convert(Ptr{LibZenohC.z_liveliness_subscriber_options_t},
        opts).history = history
    return opts
end

function _liveliness_get_opts(timeout_ms::Integer)
    opts = Ref{LibZenohC.z_liveliness_get_options_t}()
    LibZenohC.z_liveliness_get_options_default(opts)
    if timeout_ms > 0
        Base.unsafe_convert(Ptr{LibZenohC.z_liveliness_get_options_t},
            opts).timeout_ms = UInt64(timeout_ms)
    end
    return opts
end

# --- Callback subscriber --------------------------------------------

"""
    LivelinessSubscriber(f, s::Session, k::Keyexpr; history=false,
                          should_close_on_error=true)

Callback form. `f(::Sample)` runs on a dedicated Julia task for each
token announcement/withdrawal on `k`:

- `kind(sample) == Z_SAMPLE_KIND_PUT` — token appeared
- `kind(sample) == Z_SAMPLE_KIND_DELETE` — token withdrew

`history=true` replays existing tokens at subscribe time so a late
subscriber sees the current set of live tokens.

Latest-wins single-slot semantics — see [`Subscriber`](@ref).
"""
mutable struct LivelinessSubscriber <: AbstractCallbackSubscriber
    sub::Base.RefValue{LibZenohC.z_owned_subscriber_t}
    ctx::CallbackCtx{LibZenohC.z_owned_sample_t}
    async_cond::Base.AsyncCondition
    task::Task
    keyexpr::Keyexpr  # GC pin
    closed::Bool
end

function LivelinessSubscriber(f::Function, s::Session, k::Keyexpr;
        history::Bool=false, should_close_on_error::Bool=true)
    opts = _liveliness_sub_opts(history)
    _open_callback_sub(LivelinessSubscriber, f, k;
            should_close_on_error=should_close_on_error) do sub, closure
        GC.@preserve opts LibZenohC.z_liveliness_declare_subscriber(
            _loan(s), sub, _loan(k), _move(closure), opts)
    end
end

# --- Buffered subscriber ---------------------------------------------

"""
    LivelinessSubscriberHandler(s::Session, k::Keyexpr;
                                 channel=:fifo, capacity=16, history=false)

Buffered form. Iterate / `take!` / `tryrecv!` to consume token samples.
See [`SubscriberHandler`](@ref) for queue semantics.
"""
struct LivelinessSubscriberHandler{HType, Mode} <: AbstractSubscriberHandler{HType, Mode}
    sub::Base.RefValue{LibZenohC.z_owned_subscriber_t}
    h::Base.RefValue{HType}
    keyexpr::Keyexpr
end

function LivelinessSubscriberHandler(s::Session, k::Keyexpr;
        channel::Symbol=:fifo, capacity::Integer=16, history::Bool=false)
    opts = _liveliness_sub_opts(history)
    _open_buffered_sub(LivelinessSubscriberHandler, k, channel, capacity) do sub, closure
        GC.@preserve opts LibZenohC.z_liveliness_declare_subscriber(
            _loan(s), sub, _loan(k), _move(closure), opts)
    end
end

# --- liveliness_get --------------------------------------------------

"""
    liveliness_get(s::Session, k::Keyexpr;
                   channel=:fifo, capacity=16, timeout_ms=0) -> GetHandler

One-shot snapshot of currently live tokens matching `k`. Iterate the
returned `GetHandler` to consume replies; each `sample(reply)` carries
the token's keyexpr.
"""
function liveliness_get(s::Session, k::Keyexpr;
        channel::Symbol=:fifo, capacity::Integer=16, timeout_ms::Integer=0)
    opts = _liveliness_get_opts(timeout_ms)
    closure = Ref{LibZenohC.z_owned_closure_reply_t}()
    handler = _new_reply_channel(closure, Val(channel), capacity)
    rtc = GC.@preserve opts LibZenohC.z_liveliness_get(
        _loan(s), _loan(k), _move(closure), opts)
    _handle_result(rtc)
    return GetHandler{eltype(typeof(handler)), channel}(handler)
end

"""
    liveliness_get(f, s::Session, k::Keyexpr;
                   timeout_ms=0, should_close_on_error=true)

Callback form. Blocks until libzenohc finishes delivering replies
(every peer responded or the timeout elapsed). Latest-wins
single-slot semantics — see [`get`](@ref).
"""
function liveliness_get(f::Function, s::Session, k::Keyexpr;
        timeout_ms::Integer=0, should_close_on_error::Bool=true)
    opts = _liveliness_get_opts(timeout_ms)
    _callback_get(f; should_close_on_error=should_close_on_error) do closure
        GC.@preserve opts LibZenohC.z_liveliness_get(
            _loan(s), _loan(k), _move(closure), opts)
    end
end

export LivelinessToken, LivelinessSubscriber, LivelinessSubscriberHandler,
    liveliness_get
