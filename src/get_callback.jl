# Single-slot overwrite-on-full callback get. Shared latest-wins
# machinery lives in `callback.jl`; this file binds it to
# `z_loaned_reply_t` / `z_owned_reply_t` and wires up the blocking
# `get(f, s, k, params; …)` form.

# --- Foreign-thread trampolines --------------------------------------

function reply_call_trampoline(reply::Ptr{LibZenohC.z_loaned_reply_t},
        ctx::Ptr{Cvoid})
    call_body!(reply, ctx, REPLY_CLONE_FP[], REPLY_DROP_FP[],
        LibZenohC.z_owned_reply_t, LibZenohC.z_moved_reply_t)
end

function reply_drop_trampoline(ctx::Ptr{Cvoid})
    drop_body!(ctx, LibZenohC.z_owned_reply_t)
end

const GET_CALL_CB    = Ref{Ptr{Cvoid}}(C_NULL)
const GET_DROP_CB    = Ref{Ptr{Cvoid}}(C_NULL)
const REPLY_CLONE_FP = Ref{Ptr{Cvoid}}(C_NULL)
const REPLY_DROP_FP  = Ref{Ptr{Cvoid}}(C_NULL)

_register_init!() do
    GET_CALL_CB[] = @cfunction(reply_call_trampoline, Cvoid,
        (Ptr{LibZenohC.z_loaned_reply_t}, Ptr{Cvoid}))
    GET_DROP_CB[] = @cfunction(reply_drop_trampoline, Cvoid, (Ptr{Cvoid},))
    REPLY_CLONE_FP[] = cglobal((:z_reply_clone, LibZenohC.libzenohc))
    REPLY_DROP_FP[]  = cglobal((:z_reply_drop,  LibZenohC.libzenohc))
end

# --- Callback-form get ----------------------------------------------

"""
    get(f, s::Session, k::Keyexpr, parameters=""; kwargs...)

Issue a query on key expression `k` and invoke `f(::Reply)` on a
dedicated Julia task for each reply that fits through the single-slot
handoff. Replies that arrive while the cell still holds an unconsumed
one overwrite it — slow consumers see only the latest reply.

Blocks until libzenohc finishes delivering replies (i.e. all peers
responded or the timeout elapsed). For queued semantics use the
channel form: `get(s, k, params; channel=:fifo|:ring, capacity=N)`.

Keyword arguments mirror the channel-form `get`: `target`,
`consolidation`, `timeout_ms`, `payload`, `encoding`, `attachment`.
Plus `should_close_on_error::Bool=true` — if `f` throws, abandon the
remaining replies.
"""
function get(f::Function, s::Session, k::Keyexpr,
        parameters::AbstractString="";
        should_close_on_error::Bool=true,
        target::Union{Nothing, Symbol} = nothing,
        consolidation::Union{Nothing, Symbol} = nothing,
        timeout_ms::Integer = 0,
        payload = nothing,
        encoding::Union{Nothing, Encoding, AbstractString, Base.MIME} = nothing,
        attachment = nothing)
    ctx = CallbackCtx{LibZenohC.z_owned_reply_t}()
    async_cond = Base.AsyncCondition()
    init_ctx!(ctx, async_cond)

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
    LibZenohC.z_closure_reply(closure, GET_CALL_CB[], GET_DROP_CB[], ctx_p(ctx))

    task = Threads.@spawn consume(f, Reply, ctx, async_cond, should_close_on_error)

    params = String(parameters)
    rtc = GC.@preserve ctx payload_bytes attach_bytes enc_ref params opts begin
        LibZenohC.z_get(_loan(s), _loan(k),
            pointer(Base.unsafe_convert(Cstring, params)),
            _move(closure), opts)
    end
    if rtc != LibZenohC.Z_OK
        # z_get took ownership of the closure even on error: its drop
        # callback will fire and the consume task will see closing.
        # Wait for it, then surface the error.
        wait(task)
        destroy_ctx!(ctx, async_cond, REPLY_DROP_FP[], LibZenohC.z_moved_reply_t)
        _handle_result(rtc)
    end

    # The consume task exits once libzenohc drops the closure (all
    # replies delivered or timeout). No explicit close needed.
    wait(task)
    destroy_ctx!(ctx, async_cond, REPLY_DROP_FP[], LibZenohC.z_moved_reply_t)
    return nothing
end
