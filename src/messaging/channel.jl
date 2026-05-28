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

is_ok(r::Reply) = LibZenohC.z_reply_is_ok(_loaned_reply(r))

function sample(r::Reply)
    is_ok(r) || error("Reply is error; check is_ok(r) first")
    # Pass `r` as owner: the returned Sample borrows from the reply, so it
    # must keep the reply alive while reachable.
    return Sample(LibZenohC.z_reply_ok(_loaned_reply(r)), r)
end

function error_payload(r::Reply)
    is_ok(r) && error("Reply is ok; no error payload")
    return ZBytes(LibZenohC.z_reply_err_payload(LibZenohC.z_reply_err(_loaned_reply(r))), r)
end

function error_encoding(r::Reply)
    is_ok(r) && error("Reply is ok; no error encoding")
    return _from_loaned_encoding(LibZenohC.z_reply_err_encoding(LibZenohC.z_reply_err(_loaned_reply(r))))
end

# ── Channel handler dispatch ─────────────────────────────────────────
#
# The per-kind channel constructors and recv/try_recv methods live in
# `closure_kinds.jl` (`_new_channel`, `_recv`, `_try_recv`), stamped
# out by `@closure_kind :sample` and `@closure_kind :reply`. This file
# composes them into the user-facing `SubscriberHandler` / `GetHandler`
# iteration interface.
#
# Mode is a Symbol type parameter on the handler struct, so Val(M) at
# the call site resolves to a singleton at compile time and the right
# ccall is inlined — no runtime dispatch.
#
# The blocking _recv methods use @threadcall: the C function runs on a
# libuv worker thread and the calling Julia task asynchronously waits
# for completion, so other Julia tasks (including `close(handler)`)
# continue to run. The default libuv pool is 4 threads — bump
# UV_THREADPOOL_SIZE (set before Julia starts) if you need more
# concurrent in-flight recvs.

# ── Channel-handler subscriber ───────────────────────────────────────

# Abstract supertype shared with LivelinessSubscriberHandler. Both
# subtypes wrap the same `z_owned_subscriber_t` + channel handler, only
# the declare entrypoint differs; the recv/iterate machinery is shared
# via dispatch on this supertype.
abstract type AbstractSubscriberHandler{HType, Mode} end

"""
    SubscriberHandler

Buffered subscriber returned by `Base.open(s, k; channel=:fifo|:ring, capacity=N)`.
Iterate or use `take!`/`tryrecv!` to consume `Sample`s. Iteration
terminates when the channel disconnects (e.g. after `close(sub)`).
Blocking recv runs on a libuv worker thread (`@threadcall`), so other
Julia tasks — including `close(sub)` from a sibling task — run
concurrently while iteration waits.
"""
struct SubscriberHandler{HType, Mode} <: AbstractSubscriberHandler{HType, Mode}
    sub::Base.RefValue{LibZenohC.z_owned_subscriber_t}
    h::Base.RefValue{HType}
    keyexpr::Keyexpr
end

# Shared buffered-subscriber construction. `declare_fn(sub, closure) -> rtc`
# picks the C declare entrypoint and supplies any extra options. `T`
# is the concrete handler type (a UnionAll with two type parameters)
# to construct on success.
function _open_buffered_sub(declare_fn::F, ::Type{T}, k::Keyexpr,
        channel::Symbol, capacity::Integer) where {F, T<:AbstractSubscriberHandler}
    closure = _make_closure_ref(Val(:sample))
    handler = _new_channel(Val(:sample), Val(channel), closure, capacity)
    sub = Ref{LibZenohC.z_owned_subscriber_t}()
    rtc = declare_fn(sub, closure)
    _handle_result(rtc)
    return T{eltype(typeof(handler)), channel}(sub, handler, k)
end

function Base.iterate(sh::AbstractSubscriberHandler{H, M}, ::Any=nothing) where {H, M}
    owned = Ref{LibZenohC.z_owned_sample_t}()
    rtc = GC.@preserve sh owned _recv(Val(:sample), Val(M), _loan(sh.h),
        Base.unsafe_convert(Ptr{LibZenohC.z_owned_sample_t}, owned))
    rtc == LibZenohC.Z_OK && return (Sample(owned), nothing)
    rtc == LibZenohC.Z_CHANNEL_DISCONNECTED && return nothing
    throw(ZenohError(rtc))
end

function Base.take!(sh::AbstractSubscriberHandler{H, M}) where {H, M}
    owned = Ref{LibZenohC.z_owned_sample_t}()
    rtc = GC.@preserve sh owned _recv(Val(:sample), Val(M), _loan(sh.h),
        Base.unsafe_convert(Ptr{LibZenohC.z_owned_sample_t}, owned))
    rtc == LibZenohC.Z_OK && return Sample(owned)
    throw(ZenohError(rtc))
end

function tryrecv!(sh::AbstractSubscriberHandler{H, M}) where {H, M}
    owned = Ref{LibZenohC.z_owned_sample_t}()
    rtc = _try_recv(Val(:sample), Val(M), _loan(sh.h), owned)
    rtc == LibZenohC.Z_OK && return Sample(owned)
    rtc == LibZenohC.Z_CHANNEL_NODATA && return nothing
    throw(ZenohError(rtc))
end

function Base.close(sh::AbstractSubscriberHandler)
    _handle_result(LibZenohC.z_undeclare_subscriber(_move(sh.sub)))
end

Base.IteratorSize(::Type{<:AbstractSubscriberHandler}) = Base.SizeUnknown()
Base.eltype(::Type{<:AbstractSubscriberHandler}) = Sample

# ── Channel-handler get / reply consumer ─────────────────────────────

"""
    GetHandler

Reply consumer returned by `Zenoh.get(s, k, params; ...)`. Iterate or use
`take!`/`tryrecv!` to consume `Reply`s. Iteration terminates once the
remote side stops sending — no explicit close needed.
"""
struct GetHandler{HType, Mode}
    h::Base.RefValue{HType}
end

function Base.iterate(gh::GetHandler{H, M}, ::Any=nothing) where {H, M}
    owned = Ref{LibZenohC.z_owned_reply_t}()
    rtc = GC.@preserve gh owned _recv(Val(:reply), Val(M), _loan(gh.h),
        Base.unsafe_convert(Ptr{LibZenohC.z_owned_reply_t}, owned))
    rtc == LibZenohC.Z_OK && return (Reply(owned), nothing)
    rtc == LibZenohC.Z_CHANNEL_DISCONNECTED && return nothing
    throw(ZenohError(rtc))
end

function Base.take!(gh::GetHandler{H, M}) where {H, M}
    owned = Ref{LibZenohC.z_owned_reply_t}()
    rtc = GC.@preserve gh owned _recv(Val(:reply), Val(M), _loan(gh.h),
        Base.unsafe_convert(Ptr{LibZenohC.z_owned_reply_t}, owned))
    rtc == LibZenohC.Z_OK && return Reply(owned)
    throw(ZenohError(rtc))
end

function tryrecv!(gh::GetHandler{H, M}) where {H, M}
    owned = Ref{LibZenohC.z_owned_reply_t}()
    rtc = _try_recv(Val(:reply), Val(M), _loan(gh.h), owned)
    rtc == LibZenohC.Z_OK && return Reply(owned)
    rtc == LibZenohC.Z_CHANNEL_NODATA && return nothing
    throw(ZenohError(rtc))
end

Base.close(::GetHandler) = nothing  # finalizer cleans up; no-op for symmetry

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

# Populate a Ref{z_get_options_t} from the shared `get` kwargs. Returns
# `(opts, payload_bytes, attach_bytes, enc_ref)`; callers GC.@preserve
# the three trailing values across the z_get call.
function _make_get_opts(;
        target::Union{Nothing, Symbol} = nothing,
        consolidation::Union{Nothing, Symbol} = nothing,
        timeout_ms::Integer = 0,
        payload = nothing,
        encoding::Union{Nothing, Encoding, AbstractString, Base.MIME} = nothing,
        attachment = nothing,
        congestion_control::Union{Nothing, CongestionControl} = nothing,
        priority::Union{Nothing, Priority}                    = nothing,
        is_express::Union{Nothing, Bool}                      = nothing,
        allowed_destination::Union{Nothing, Locality}         = nothing,
        accept_replies::Union{Nothing, ReplyKeyexpr}          = nothing)
    opts = Ref{LibZenohC.z_get_options_t}()
    LibZenohC.z_get_options_default(opts)
    optsP = Base.unsafe_convert(Ptr{LibZenohC.z_get_options_t}, opts)
    isnothing(target)        || (optsP.target        = _query_target(target))
    isnothing(consolidation) || (optsP.consolidation = _consolidation(consolidation))
    timeout_ms > 0           && (optsP.timeout_ms    = UInt64(timeout_ms))

    payload_bytes = isnothing(payload)    ? nothing : ZBytes(payload)
    attach_bytes  = isnothing(attachment) ? nothing : ZBytes(attachment)
    enc_ref       = isnothing(encoding)   ? nothing : _to_owned_encoding(_as_encoding(encoding))
    isnothing(payload_bytes) || (optsP.payload    = _move(payload_bytes))
    isnothing(attach_bytes)  || (optsP.attachment = _move(attach_bytes))
    isnothing(enc_ref)       || (optsP.encoding   = _move(enc_ref))

    isnothing(congestion_control)  || (optsP.congestion_control  = _raw(congestion_control))
    isnothing(priority)            || (optsP.priority            = _raw(priority))
    isnothing(is_express)          || (optsP.is_express          = is_express)
    isnothing(allowed_destination) || (optsP.allowed_destination = _raw(allowed_destination))
    isnothing(accept_replies)      || (optsP.accept_replies      = _raw(accept_replies))

    return opts, payload_bytes, attach_bytes, enc_ref
end

"""
    get(s::Session, k::Keyexpr, parameters=""; kwargs...) -> GetHandler

Issue a query on key expression `k`, returning a `GetHandler` over the
replies. Iterate it to consume each `Reply`.

Keyword arguments:
- `channel`            — `:fifo` (default) or `:ring`
- `capacity`           — channel buffer size (default 16)
- `target`             — `:best_matching`, `:all`, `:all_complete`
- `consolidation`      — `:auto`, `:none`, `:monotonic`, `:latest`
- `timeout_ms`         — request timeout in milliseconds (`0` = no timeout)
- `payload`            — optional payload bytes (anything `ZBytes` accepts)
- `encoding`           — payload encoding (`Encoding`, MIME, or string)
- `attachment`         — optional attachment bytes
- `congestion_control` — `CongestionControls.BLOCK` or `DROP`
- `priority`           — `Priorities.REAL_TIME` … `BACKGROUND`
- `is_express`         — `Bool`; bypass batching
- `allowed_destination`— `Localities.ANY` / `SESSION_LOCAL` / `REMOTE`
- `accept_replies`     — `ReplyKeyexprs.ANY` or `MATCHING_QUERY`
"""
function get(s::Session, k::Keyexpr, parameters::AbstractString="";
        channel::Symbol = :fifo,
        capacity::Integer = 16,
        kwargs...)
    opts, payload_bytes, attach_bytes, enc_ref = _make_get_opts(; kwargs...)

    closure = _make_closure_ref(Val(:reply))
    handler = _new_channel(Val(:reply), Val(channel), closure, capacity)

    params = String(parameters)
    GC.@preserve payload_bytes attach_bytes enc_ref params opts begin
        rtc = LibZenohC.z_get(_loan(s), _loan(k),
            pointer(Base.unsafe_convert(Cstring, params)),
            _move(closure), opts)
        _handle_result(rtc)
    end

    return GetHandler{eltype(typeof(handler)), channel}(handler)
end
