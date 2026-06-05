# Single-slot overwrite-on-full callback get. Shared latest-wins
# machinery lives in `callback.jl`; the per-kind trampolines and
# `cglobal` lookups are stamped out by `@closure_kind :reply` in
# `closure_kinds.jl`. This file wires up the blocking `get(f, s, k, …)`
# form (and the parallel liveliness-get callback form, via
# `_callback_get`).

# --- Callback-form get ----------------------------------------------

# Shared callback-get lifecycle. `call_fn(closure) -> rtc` performs
# whichever C entrypoint (`z_get` / `z_liveliness_get`) consumes the
# closure. Thin shim over `_callback_one_shot` in `closure_kinds.jl`.
_callback_get(call_fn::F, f::Function; kwargs...) where F =
    _callback_one_shot(call_fn, Val(:reply), Reply, f; kwargs...)

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
`consolidation`, `timeout_ms`, `payload`, `encoding`, `attachment`,
`congestion_control`, `priority`, `express`, `allowed_destination`,
`accept_replies`. Plus `should_close_on_error::Bool=true` — if `f`
throws, abandon the remaining replies.
"""
function Base.get(f::Function, s::Session, k::Keyexpr,
        parameters::AbstractString="";
        should_close_on_error::Bool=true,
        kwargs...)
    opts, payload_bytes, attach_bytes, enc_ref, cancel_clone = _make_get_opts(; kwargs...)

    params = String(parameters)
    _callback_get(f; should_close_on_error=should_close_on_error) do closure
        GC.@preserve payload_bytes attach_bytes enc_ref cancel_clone params opts begin
            LibZenohC.z_get(_loan(s), _loan(k),
                pointer(Base.unsafe_convert(Cstring, params)),
                _move(closure), opts)
        end
    end
end
