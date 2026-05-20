# Single-slot overwrite-on-full callback get. Shared latest-wins
# machinery lives in `callback.jl`; the per-kind trampolines and
# `cglobal` lookups are stamped out by `@closure_kind :reply` in
# `closure_kinds.jl`. This file wires up the blocking `get(f, s, k, …)`
# form (and the parallel liveliness-get callback form, via
# `_callback_get`).

# --- Callback-form get ----------------------------------------------

# Shared callback-get lifecycle. `call_fn(closure) -> rtc` performs
# whichever C entrypoint (`z_get` / `z_liveliness_get`) consumes the
# closure. The consume task is spawned before the C call so it's
# already waiting when libzenohc starts delivering replies. On error
# the closure's drop callback fires regardless (libzenohc owns it),
# so we always wait for the task before destroying the ctx.
function _callback_get(call_fn::F, f::Function;
        should_close_on_error::Bool=true) where F
    ctx, async_cond, closure = _setup_callback(Val(:reply))

    task = Threads.@spawn consume(f, Reply, ctx, async_cond, should_close_on_error)

    rtc = GC.@preserve ctx call_fn(closure)

    # Whether rtc is Z_OK or not, libzenohc has either delivered every
    # reply or already invoked the drop callback (which flips closing
    # → wakes the consumer). Either way, wait then destroy.
    wait(task)
    _teardown_callback(Val(:reply), ctx, async_cond)
    rtc == LibZenohC.Z_OK || _handle_result(rtc)
    return nothing
end

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

    params = String(parameters)
    _callback_get(f; should_close_on_error=should_close_on_error) do closure
        GC.@preserve payload_bytes attach_bytes enc_ref params opts begin
            LibZenohC.z_get(_loan(s), _loan(k),
                pointer(Base.unsafe_convert(Cstring, params)),
                _move(closure), opts)
        end
    end
end
