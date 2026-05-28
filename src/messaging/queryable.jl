# Queryable / Query: the server side of get/reply. Mirrors the
# subscriber/get pair — `Queryable(f, s, k)` is the callback form,
# `Queryable(s, k; channel=…)` returns a `QueryableHandler` backed by a
# FIFO/ring channel. Per-kind closure/channel plumbing comes from
# `@closure_kind :query` in `closure_kinds.jl`.

# ═══════════════════════════════════════════════════════════════════════
# TODO(background-queryable): z_declare_background_queryable is NOT
# wrapped. It would be a small follow-up — same closure setup as
# Queryable (reuse _setup_callback(Val(:query))), but no
# z_owned_queryable_t handle: undeclaration is implicit on session
# close, so there's nothing to store. Useful for fire-and-forget
# servers that live for the session's lifetime.
# ═══════════════════════════════════════════════════════════════════════

# ── Query ───────────────────────────────────────────────────────────────

"""
    Query

A single inbound query handed to a queryable handler. Use the accessors
(`keyexpr`, `parameters`, `payload`, `encoding`, `attachment`,
`accepts_replies`) to inspect it, then `reply(q, payload)` /
`reply_err(q, err)` / `reply_del(q)` to respond.
"""
struct Query{Q <: Union{Base.RefValue{LibZenohC.z_owned_query_t},
                        Ptr{LibZenohC.z_loaned_query_t}}}
    q::Q
end
Query(p::Ptr{LibZenohC.z_loaned_query_t}) =
    Query{Ptr{LibZenohC.z_loaned_query_t}}(p)
function Query(r::Base.RefValue{LibZenohC.z_owned_query_t})
    finalizer(x -> LibZenohC.z_query_drop(_move(x)), r)
    return Query{Base.RefValue{LibZenohC.z_owned_query_t}}(r)
end

_loaned_query(q::Query{Ptr{LibZenohC.z_loaned_query_t}}) = q.q
_loaned_query(q::Query{Base.RefValue{LibZenohC.z_owned_query_t}}) = _loan(q.q)

# ── Query accessors ────────────────────────────────────────────────────

function keyexpr(q::Query)
    # The view string borrows from the query; keep `q` alive until copied.
    GC.@preserve q begin
        ke = LibZenohC.z_query_keyexpr(_loaned_query(q))
        view = Ref{LibZenohC.z_view_string_t}()
        LibZenohC.z_keyexpr_as_view_string(ke, view)
        loaned = LibZenohC.z_view_string_loan(view)
        return unsafe_string(LibZenohC.z_string_data(loaned), LibZenohC.z_string_len(loaned))
    end
end

function parameters(q::Query)
    GC.@preserve q begin
        view = Ref{LibZenohC.z_view_string_t}()
        LibZenohC.z_query_parameters(_loaned_query(q), view)
        loaned = LibZenohC.z_view_string_loan(view)
        return unsafe_string(LibZenohC.z_string_data(loaned), LibZenohC.z_string_len(loaned))
    end
end

function payload(q::Query)
    p = LibZenohC.z_query_payload(_loaned_query(q))
    # Pass `q` as owner so the loaned ZBytes keeps the query (and the
    # borrowed buffer) alive while reachable.
    return p == C_NULL ? nothing : ZBytes(p, q)
end

function encoding(q::Query)
    p = LibZenohC.z_query_encoding(_loaned_query(q))
    return p == C_NULL ? nothing : _from_loaned_encoding(p)
end

function attachment(q::Query)
    a = LibZenohC.z_query_attachment(_loaned_query(q))
    return a == C_NULL ? nothing : ZBytes(a, q)
end

accepts_replies(q::Query) = LibZenohC.z_query_accepts_replies(_loaned_query(q))

# ── Reply option builders ──────────────────────────────────────────────

function _make_reply_opts(;
        encoding=nothing, timestamp::Union{Nothing, ZTimestamp}=nothing,
        attachment=nothing,
        congestion_control::Union{Nothing, CongestionControl}=nothing,
        priority::Union{Nothing, Priority}=nothing,
        is_express::Union{Nothing, Bool}=nothing)
    opts = Ref{LibZenohC.z_query_reply_options_t}()
    LibZenohC.z_query_reply_options_default(opts)
    optsP = Base.unsafe_convert(Ptr{LibZenohC.z_query_reply_options_t}, opts)
    enc_ref    = isnothing(encoding)   ? nothing : _to_owned_encoding(_as_encoding(encoding))
    attach_ref = isnothing(attachment) ? nothing : ZBytes(attachment)
    isnothing(timestamp)          || (optsP.timestamp          = Base.unsafe_convert(Ptr{LibZenohC.z_timestamp_t}, timestamp.ts))
    isnothing(enc_ref)            || (optsP.encoding           = _move(enc_ref))
    isnothing(attach_ref)         || (optsP.attachment         = _move(attach_ref))
    isnothing(congestion_control) || (optsP.congestion_control = _raw(congestion_control))
    isnothing(priority)           || (optsP.priority           = _raw(priority))
    isnothing(is_express)         || (optsP.is_express         = is_express)
    # `timestamp` is returned so the caller can GC.@preserve it across the
    # reply: optsP.timestamp is a borrowed pointer into the ZTimestamp's
    # Ref (unlike encoding/attachment, which are moved-owned).
    return opts, enc_ref, attach_ref, timestamp
end

function _make_reply_err_opts(; encoding=nothing)
    opts = Ref{LibZenohC.z_query_reply_err_options_t}()
    LibZenohC.z_query_reply_err_options_default(opts)
    optsP = Base.unsafe_convert(Ptr{LibZenohC.z_query_reply_err_options_t}, opts)
    enc_ref = isnothing(encoding) ? nothing : _to_owned_encoding(_as_encoding(encoding))
    isnothing(enc_ref) || (optsP.encoding = _move(enc_ref))
    return opts, enc_ref
end

function _make_reply_del_opts(;
        timestamp::Union{Nothing, ZTimestamp}=nothing,
        attachment=nothing,
        congestion_control::Union{Nothing, CongestionControl}=nothing,
        priority::Union{Nothing, Priority}=nothing,
        is_express::Union{Nothing, Bool}=nothing)
    opts = Ref{LibZenohC.z_query_reply_del_options_t}()
    LibZenohC.z_query_reply_del_options_default(opts)
    optsP = Base.unsafe_convert(Ptr{LibZenohC.z_query_reply_del_options_t}, opts)
    attach_ref = isnothing(attachment) ? nothing : ZBytes(attachment)
    isnothing(timestamp)          || (optsP.timestamp          = Base.unsafe_convert(Ptr{LibZenohC.z_timestamp_t}, timestamp.ts))
    isnothing(attach_ref)         || (optsP.attachment         = _move(attach_ref))
    isnothing(congestion_control) || (optsP.congestion_control = _raw(congestion_control))
    isnothing(priority)           || (optsP.priority           = _raw(priority))
    isnothing(is_express)         || (optsP.is_express         = is_express)
    # See _make_reply_opts: timestamp is borrowed, returned for preservation.
    return opts, attach_ref, timestamp
end

# ── Public reply methods ───────────────────────────────────────────────

"""
    reply(q::Query, payload, k::Keyexpr=Keyexpr(keyexpr(q)); kwargs...)

Send a successful reply to query `q`. `payload` is anything `ZBytes`
accepts. The keyexpr defaults to the query's own — pass an explicit one
when serving wildcard keyexprs with per-key resolution.

Keyword arguments: `encoding`, `timestamp`, `attachment`,
`congestion_control`, `priority`, `is_express`.
"""
function reply(q::Query, payload, k::Keyexpr = Keyexpr(keyexpr(q)); kwargs...)
    bytes = ZBytes(payload)
    opts, enc_ref, attach_ref, ts = _make_reply_opts(; kwargs...)
    GC.@preserve enc_ref attach_ref ts begin
        rtc = LibZenohC.z_query_reply(_loaned_query(q), _loan(k), _move(bytes), opts)
        _handle_result(rtc)
    end
end

"""
    reply_err(q::Query, payload; encoding=nothing)

Send an error reply to query `q`. `payload` is anything `ZBytes` accepts.
"""
function reply_err(q::Query, payload; kwargs...)
    bytes = ZBytes(payload)
    opts, enc_ref = _make_reply_err_opts(; kwargs...)
    GC.@preserve enc_ref begin
        rtc = LibZenohC.z_query_reply_err(_loaned_query(q), _move(bytes), opts)
        _handle_result(rtc)
    end
end

"""
    reply_del(q::Query, k::Keyexpr=Keyexpr(keyexpr(q)); kwargs...)

Send a delete-notification reply to query `q`.

Keyword arguments: `timestamp`, `attachment`, `congestion_control`,
`priority`, `is_express`.
"""
function reply_del(q::Query, k::Keyexpr = Keyexpr(keyexpr(q)); kwargs...)
    opts, attach_ref, ts = _make_reply_del_opts(; kwargs...)
    GC.@preserve attach_ref ts begin
        rtc = LibZenohC.z_query_reply_del(_loaned_query(q), _loan(k), opts)
        _handle_result(rtc)
    end
end

# ── Queryable option helper ────────────────────────────────────────────

# z_queryable_options_t has no generated Base.setproperty! (Clang.jl skips
# structs with only POD fields and no padding gaps). Reconstructing the
# struct via its Julia constructor can clobber padding bytes that
# libzenohc depends on, so we poke fields through the raw pointer.
function _make_queryable_opts(;
        complete::Union{Nothing, Bool} = nothing,
        allowed_origin::Union{Nothing, Locality} = nothing)
    opts = Ref{LibZenohC.z_queryable_options_t}()
    LibZenohC.z_queryable_options_default(opts)
    p = Base.unsafe_convert(Ptr{LibZenohC.z_queryable_options_t}, opts)
    if !isnothing(complete)
        unsafe_store!(Ptr{Bool}(p + fieldoffset(LibZenohC.z_queryable_options_t, 1)),
                      complete)
    end
    if !isnothing(allowed_origin)
        unsafe_store!(Ptr{LibZenohC.z_locality_t}(p + fieldoffset(LibZenohC.z_queryable_options_t, 2)),
                      _raw(allowed_origin))
    end
    return opts
end

# ── Callback-form Queryable ────────────────────────────────────────────

"""
    Queryable

Callback-form queryable returned by `Queryable(f, s, k)`. Single-slot
latest-wins: queries arriving while the slot is still occupied overwrite
the previous one. **For real query workloads prefer the channel form**
`Queryable(s, k; channel=:fifo)` — overwriting in-flight queries means
the client gets a timeout, not a reply.
"""
mutable struct Queryable
    qable::Base.RefValue{LibZenohC.z_owned_queryable_t}
    ctx::CallbackCtx{LibZenohC.z_owned_query_t}
    async_cond::Base.AsyncCondition
    task::Task
    keyexpr::Keyexpr     # GC pin
    closed::Bool
end

"""
    Queryable(f, s::Session, k::Keyexpr; complete=nothing,
              allowed_origin=nothing, should_close_on_error=true)

Declare a queryable on keyexpr `k` and invoke `f(::Query)` on a dedicated
Julia task per query that fits through the single-slot handoff. See
`Queryable` docs for the latest-wins caveat.

`f` must finish replying (or choose not to) before returning. The `Query`
handle is dropped as soon as `f` returns, which sends the final-ack the
originating `get` is waiting on; deferring reply work past the callback
will see the query revoked. For deferred handling, use the channel form
`Queryable(s, k; channel=:fifo)`.

`allowed_origin` accepts a `Locality` singleton (`Localities.ANY`,
`SESSION_LOCAL`, `REMOTE`).
"""
function Queryable(f::Function, s::Session, k::Keyexpr;
        complete=nothing, allowed_origin=nothing,
        should_close_on_error::Bool=true)
    ctx, async_cond, closure = _setup_callback(Val(:query))

    opts  = _make_queryable_opts(; complete, allowed_origin)
    qable = Ref{LibZenohC.z_owned_queryable_t}()
    rtc = GC.@preserve ctx opts LibZenohC.z_declare_queryable(
        _loan(s), qable, _loan(k), _move(closure), opts)
    if rtc != LibZenohC.Z_OK
        _teardown_callback(Val(:query), ctx, async_cond)
        _handle_result(rtc)
    end

    # Wrap the user's callback so we drop the owned Query as soon as it
    # returns. The Query handle being dropped is what tells libzenohc
    # "this queryable is done with this query"; if we leave that to GC,
    # the originating get sees no final-ack and blocks for the entire
    # timeout window even when the reply arrived in microseconds.
    wrapped = function (query::Query)
        try
            f(query)
        finally
            finalize(query.q)
        end
    end
    task = Threads.@spawn consume(wrapped, Query, ctx, async_cond, should_close_on_error)
    return Queryable(qable, ctx, async_cond, task, k, false)
end

function Base.close(q::Queryable)
    q.closed && return
    q.closed = true

    signal_closing!(q.ctx, q.async_cond)

    # Blocks until libzenohc has drained any in-flight callbacks (they
    # bail on the closing flag) and invoked our drop trampoline.
    _handle_result(LibZenohC.z_undeclare_queryable(_move(q.qable)))

    wait(q.task)

    _teardown_callback(Val(:query), q.ctx, q.async_cond)
    return nothing
end

# ── Channel-form QueryableHandler ──────────────────────────────────────

"""
    QueryableHandler

Buffered queryable returned by `Queryable(s, k; channel=:fifo|:ring, capacity=N)`.
Iterate or use `take!`/`tryrecv!` to consume `Query`s. Iteration
terminates after `close(qh)`. Blocking recv runs on a libuv worker
thread, so other Julia tasks (including `close`) run concurrently.

**Iteration finalizes the previous `Query`** at the start of each next-call,
matching the callback-form behavior. The drop is what sends the final-ack
the originating `get` is waiting on; without it every reply looks
timeout-late. As a consequence, don't accumulate queries across iterations
(`collect(qh)` will yield handles that have already been dropped); reply
inline and let the loop continue. For deferred handling, use `take!` and
finalize manually.
"""
struct QueryableHandler{HType, Mode}
    qable::Base.RefValue{LibZenohC.z_owned_queryable_t}
    h::Base.RefValue{HType}
    keyexpr::Keyexpr
end

"""
    Queryable(s::Session, k::Keyexpr; channel=:fifo, capacity=16,
              complete=nothing, allowed_origin=nothing)

Declare a queryable with a buffered channel handler. Returns a
`QueryableHandler`. Iterate / `take!` / `tryrecv!` to receive `Query`s.

`allowed_origin` accepts a `Locality` singleton (`Localities.ANY`,
`SESSION_LOCAL`, `REMOTE`).
"""
function Queryable(s::Session, k::Keyexpr;
        channel::Symbol = :fifo, capacity::Integer = 16,
        complete=nothing, allowed_origin=nothing)
    closure = _make_closure_ref(Val(:query))
    handler = _new_channel(Val(:query), Val(channel), closure, capacity)
    opts    = _make_queryable_opts(; complete, allowed_origin)
    qable   = Ref{LibZenohC.z_owned_queryable_t}()
    rtc = GC.@preserve opts LibZenohC.z_declare_queryable(
        _loan(s), qable, _loan(k), _move(closure), opts)
    _handle_result(rtc)
    return QueryableHandler{eltype(typeof(handler)), channel}(qable, handler, k)
end

function Base.iterate(qh::QueryableHandler{H, M},
        prev::Union{Nothing, Query}=nothing) where {H, M}
    # Drop the previous query before blocking on the next recv. The
    # z_query_drop is what sends the final-ack the originating get is
    # waiting on; relying on GC to do this defers the ack until at best
    # the next allocation cycle, and in test workloads typically until
    # the query times out — making every reply look 2 s late.
    #
    # Mirrors the callback-form Queryable's `wrapped` shim that calls
    # `finalize(query.q)` immediately after the user's `f` returns.
    prev === nothing || finalize(prev.q)
    owned = Ref{LibZenohC.z_owned_query_t}()
    rtc = GC.@preserve qh owned _recv(Val(:query), Val(M), _loan(qh.h),
        Base.unsafe_convert(Ptr{LibZenohC.z_owned_query_t}, owned))
    if rtc == LibZenohC.Z_OK
        q = Query(owned)
        return (q, q)
    end
    rtc == LibZenohC.Z_CHANNEL_DISCONNECTED && return nothing
    throw(ZenohError(rtc))
end

# Unlike `iterate`, `take!` / `tryrecv!` hand the Query out without a
# follow-on call site where the previous handle can be finalized, so the
# caller owns its lifetime. To unblock the originating `get` promptly,
# call `finalize(q.q)` after replying — otherwise the final-ack waits on
# GC, and the get blocks for its full timeout window.
function Base.take!(qh::QueryableHandler{H, M}) where {H, M}
    owned = Ref{LibZenohC.z_owned_query_t}()
    rtc = GC.@preserve qh owned _recv(Val(:query), Val(M), _loan(qh.h),
        Base.unsafe_convert(Ptr{LibZenohC.z_owned_query_t}, owned))
    rtc == LibZenohC.Z_OK && return Query(owned)
    throw(ZenohError(rtc))
end

function tryrecv!(qh::QueryableHandler{H, M}) where {H, M}
    owned = Ref{LibZenohC.z_owned_query_t}()
    rtc = _try_recv(Val(:query), Val(M), _loan(qh.h), owned)
    rtc == LibZenohC.Z_OK && return Query(owned)
    rtc == LibZenohC.Z_CHANNEL_NODATA && return nothing
    throw(ZenohError(rtc))
end

function Base.close(qh::QueryableHandler)
    _handle_result(LibZenohC.z_undeclare_queryable(_move(qh.qable)))
end

Base.IteratorSize(::Type{<:QueryableHandler}) = Base.SizeUnknown()
Base.eltype(::Type{<:QueryableHandler}) = Query
