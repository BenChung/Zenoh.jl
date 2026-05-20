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
    return Sample(LibZenohC.z_reply_ok(_loaned_reply(r)))
end

function error_payload(r::Reply)
    is_ok(r) && error("Reply is ok; no error payload")
    return ZBytes(LibZenohC.z_reply_err_payload(LibZenohC.z_reply_err(_loaned_reply(r))))
end

function error_encoding(r::Reply)
    is_ok(r) && error("Reply is ok; no error encoding")
    return _from_loaned_encoding(LibZenohC.z_reply_err_encoding(LibZenohC.z_reply_err(_loaned_reply(r))))
end

# ── Channel handler dispatch ─────────────────────────────────────────
#
# Mode is a Symbol type parameter on the handler struct, so Val(M) at
# the call site resolves to a singleton at compile time and the right
# ccall is inlined — no runtime dispatch.
#
# The blocking *_recv calls use @threadcall: the C function runs on a
# libuv worker thread and the calling Julia task asynchronously waits
# for completion, so other Julia tasks (including `close(handler)`)
# continue to run. The default libuv pool is 4 threads — bump
# UV_THREADPOOL_SIZE (set before Julia starts) if you need more
# concurrent in-flight recvs.
#
# The non-blocking *_try_recv calls return immediately and stay as
# direct ccalls.

@inline _sample_recv(::Val{:fifo}, h::Ptr{LibZenohC.z_loaned_fifo_handler_sample_t},
                     o::Ptr{LibZenohC.z_owned_sample_t}) =
    @threadcall((:z_fifo_handler_sample_recv, LibZenohC.libzenohc),
        LibZenohC.z_result_t,
        (Ptr{LibZenohC.z_loaned_fifo_handler_sample_t}, Ptr{LibZenohC.z_owned_sample_t}),
        h, o)
@inline _sample_recv(::Val{:ring}, h::Ptr{LibZenohC.z_loaned_ring_handler_sample_t},
                     o::Ptr{LibZenohC.z_owned_sample_t}) =
    @threadcall((:z_ring_handler_sample_recv, LibZenohC.libzenohc),
        LibZenohC.z_result_t,
        (Ptr{LibZenohC.z_loaned_ring_handler_sample_t}, Ptr{LibZenohC.z_owned_sample_t}),
        h, o)

@inline _reply_recv(::Val{:fifo}, h::Ptr{LibZenohC.z_loaned_fifo_handler_reply_t},
                    o::Ptr{LibZenohC.z_owned_reply_t}) =
    @threadcall((:z_fifo_handler_reply_recv, LibZenohC.libzenohc),
        LibZenohC.z_result_t,
        (Ptr{LibZenohC.z_loaned_fifo_handler_reply_t}, Ptr{LibZenohC.z_owned_reply_t}),
        h, o)
@inline _reply_recv(::Val{:ring}, h::Ptr{LibZenohC.z_loaned_ring_handler_reply_t},
                    o::Ptr{LibZenohC.z_owned_reply_t}) =
    @threadcall((:z_ring_handler_reply_recv, LibZenohC.libzenohc),
        LibZenohC.z_result_t,
        (Ptr{LibZenohC.z_loaned_ring_handler_reply_t}, Ptr{LibZenohC.z_owned_reply_t}),
        h, o)

@inline _sample_try_recv(::Val{:fifo}, h, o) = LibZenohC.z_fifo_handler_sample_try_recv(h, o)
@inline _sample_try_recv(::Val{:ring}, h, o) = LibZenohC.z_ring_handler_sample_try_recv(h, o)
@inline _reply_try_recv(::Val{:fifo}, h, o) = LibZenohC.z_fifo_handler_reply_try_recv(h, o)
@inline _reply_try_recv(::Val{:ring}, h, o) = LibZenohC.z_ring_handler_reply_try_recv(h, o)

# Build the handler + finalizer for a given mode. Returns the handler
# Ref so callers can move() it into the channel ctor and stash it on the
# returned handler struct.

function _new_sample_channel(closure::Ref{LibZenohC.z_owned_closure_sample_t}, ::Val{:fifo}, capacity::Integer)
    h = Ref{LibZenohC.z_owned_fifo_handler_sample_t}()
    LibZenohC.z_fifo_channel_sample_new(closure, h, Csize_t(capacity))
    finalizer(x -> LibZenohC.z_fifo_handler_sample_drop(_move(x)), h)
    return h
end
function _new_sample_channel(closure::Ref{LibZenohC.z_owned_closure_sample_t}, ::Val{:ring}, capacity::Integer)
    h = Ref{LibZenohC.z_owned_ring_handler_sample_t}()
    LibZenohC.z_ring_channel_sample_new(closure, h, Csize_t(capacity))
    finalizer(x -> LibZenohC.z_ring_handler_sample_drop(_move(x)), h)
    return h
end

function _new_reply_channel(closure::Ref{LibZenohC.z_owned_closure_reply_t}, ::Val{:fifo}, capacity::Integer)
    h = Ref{LibZenohC.z_owned_fifo_handler_reply_t}()
    LibZenohC.z_fifo_channel_reply_new(closure, h, Csize_t(capacity))
    finalizer(x -> LibZenohC.z_fifo_handler_reply_drop(_move(x)), h)
    return h
end
function _new_reply_channel(closure::Ref{LibZenohC.z_owned_closure_reply_t}, ::Val{:ring}, capacity::Integer)
    h = Ref{LibZenohC.z_owned_ring_handler_reply_t}()
    LibZenohC.z_ring_channel_reply_new(closure, h, Csize_t(capacity))
    finalizer(x -> LibZenohC.z_ring_handler_reply_drop(_move(x)), h)
    return h
end

# ── Channel-handler subscriber ───────────────────────────────────────

"""
    SubscriberHandler

Buffered subscriber returned by `Base.open(s, k; channel=:fifo|:ring, capacity=N)`.
Iterate or use `take!`/`tryrecv!` to consume `Sample`s. Iteration
terminates when the channel disconnects (e.g. after `close(sub)`).
Blocking recv runs on a libuv worker thread (`@threadcall`), so other
Julia tasks — including `close(sub)` from a sibling task — run
concurrently while iteration waits.
"""
struct SubscriberHandler{HType, Mode}
    sub::Base.RefValue{LibZenohC.z_owned_subscriber_t}
    h::Base.RefValue{HType}
    keyexpr::Keyexpr
end

function Base.iterate(sh::SubscriberHandler{H, M}, ::Any=nothing) where {H, M}
    owned = Ref{LibZenohC.z_owned_sample_t}()
    rtc = GC.@preserve sh owned _sample_recv(Val(M), _loan(sh.h),
        Base.unsafe_convert(Ptr{LibZenohC.z_owned_sample_t}, owned))
    rtc == LibZenohC.Z_OK && return (Sample(owned), nothing)
    rtc == LibZenohC.Z_CHANNEL_DISCONNECTED && return nothing
    throw(ZenohError(rtc))
end

function Base.take!(sh::SubscriberHandler{H, M}) where {H, M}
    owned = Ref{LibZenohC.z_owned_sample_t}()
    rtc = GC.@preserve sh owned _sample_recv(Val(M), _loan(sh.h),
        Base.unsafe_convert(Ptr{LibZenohC.z_owned_sample_t}, owned))
    rtc == LibZenohC.Z_OK && return Sample(owned)
    throw(ZenohError(rtc))
end

function tryrecv!(sh::SubscriberHandler{H, M}) where {H, M}
    owned = Ref{LibZenohC.z_owned_sample_t}()
    rtc = _sample_try_recv(Val(M), _loan(sh.h), owned)
    rtc == LibZenohC.Z_OK && return Sample(owned)
    rtc == LibZenohC.Z_CHANNEL_NODATA && return nothing
    throw(ZenohError(rtc))
end

function Base.close(sh::SubscriberHandler)
    _handle_result(LibZenohC.z_undeclare_subscriber(_move(sh.sub)))
end

Base.IteratorSize(::Type{<:SubscriberHandler}) = Base.SizeUnknown()
Base.eltype(::Type{<:SubscriberHandler}) = Sample

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
    rtc = GC.@preserve gh owned _reply_recv(Val(M), _loan(gh.h),
        Base.unsafe_convert(Ptr{LibZenohC.z_owned_reply_t}, owned))
    rtc == LibZenohC.Z_OK && return (Reply(owned), nothing)
    rtc == LibZenohC.Z_CHANNEL_DISCONNECTED && return nothing
    throw(ZenohError(rtc))
end

function Base.take!(gh::GetHandler{H, M}) where {H, M}
    owned = Ref{LibZenohC.z_owned_reply_t}()
    rtc = GC.@preserve gh owned _reply_recv(Val(M), _loan(gh.h),
        Base.unsafe_convert(Ptr{LibZenohC.z_owned_reply_t}, owned))
    rtc == LibZenohC.Z_OK && return Reply(owned)
    throw(ZenohError(rtc))
end

function tryrecv!(gh::GetHandler{H, M}) where {H, M}
    owned = Ref{LibZenohC.z_owned_reply_t}()
    rtc = _reply_try_recv(Val(M), _loan(gh.h), owned)
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

"""
    get(s::Session, k::Keyexpr, parameters=""; kwargs...) -> GetHandler

Issue a query on key expression `k`, returning a `GetHandler` over the
replies. Iterate it to consume each `Reply`.

Keyword arguments:
- `channel`     — `:fifo` (default) or `:ring`
- `capacity`    — channel buffer size (default 16)
- `target`      — `:best_matching`, `:all`, `:all_complete`
- `consolidation` — `:auto`, `:none`, `:monotonic`, `:latest`
- `timeout_ms`  — request timeout in milliseconds (`0` = no timeout)
- `payload`     — optional payload bytes (anything `ZBytes` accepts)
- `encoding`    — payload encoding (`Encoding`, MIME, or string)
- `attachment`  — optional attachment bytes
"""
function get(s::Session, k::Keyexpr, parameters::AbstractString="";
        channel::Symbol = :fifo,
        capacity::Integer = 16,
        target::Union{Nothing, Symbol} = nothing,
        consolidation::Union{Nothing, Symbol} = nothing,
        timeout_ms::Integer = 0,
        payload = nothing,
        encoding::Union{Nothing, Encoding, AbstractString, Base.MIME} = nothing,
        attachment = nothing)
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

    closure = Ref{LibZenohC.z_owned_closure_reply_t}()
    handler = _new_reply_channel(closure, Val(channel), capacity)

    params = String(parameters)
    GC.@preserve payload_bytes attach_bytes enc_ref params opts begin
        rtc = LibZenohC.z_get(_loan(s), _loan(k),
            pointer(Base.unsafe_convert(Cstring, params)),
            _move(closure), opts)
        _handle_result(rtc)
    end

    return GetHandler{eltype(typeof(handler)), channel}(handler)
end
