# Querier — long-lived counterpart to `z_get`. Declared once with a
# keyexpr plus default target/consolidation/QoS, then queried repeatedly
# via `z_querier_get`. Replies arrive at a per-call reply closure (same
# `:reply` kind as `z_get`), so the Querier itself owns no Julia-side
# task — both the channel form (`get(::Querier, params; channel=…)`) and
# the callback form (`get(f, ::Querier, params)`) reuse the existing
# `GetHandler` / `_callback_get` plumbing.
#
# ═══════════════════════════════════════════════════════════════════════
# TODO(background-matching-listener): the querier-side
# `z_querier_declare_background_matching_listener` is deferred — same
# closure-lifetime issue as background liveliness / queryable.
# ═══════════════════════════════════════════════════════════════════════

# z_querier_options_t and z_querier_get_options_t have no generated
# Base.setproperty! (Clang.jl skips POD structs without padding gaps).
# Same workaround as `_make_queryable_opts` in queryable.jl: poke fields
# through the raw pointer via `fieldoffset`.
function _make_querier_opts(;
        target::Union{Nothing, Symbol} = nothing,
        consolidation::Union{Nothing, Symbol} = nothing,
        congestion_control = nothing,
        is_express::Union{Nothing, Bool} = nothing,
        allowed_destination::Union{Nothing, Locality, Symbol} = nothing,
        priority = nothing,
        timeout_ms::Integer = 0)
    opts = Ref{LibZenohC.z_querier_options_t}()
    LibZenohC.z_querier_options_default(opts)
    p = Base.unsafe_convert(Ptr{LibZenohC.z_querier_options_t}, opts)
    T = LibZenohC.z_querier_options_t
    if !isnothing(target)
        unsafe_store!(Ptr{LibZenohC.z_query_target_t}(p + fieldoffset(T, 1)),
                      _query_target(target))
    end
    if !isnothing(consolidation)
        unsafe_store!(Ptr{LibZenohC.z_query_consolidation_t}(p + fieldoffset(T, 2)),
                      _consolidation(consolidation))
    end
    if !isnothing(congestion_control)
        unsafe_store!(Ptr{LibZenohC.z_congestion_control_t}(p + fieldoffset(T, 3)),
                      congestion_control)
    end
    if !isnothing(is_express)
        unsafe_store!(Ptr{Bool}(p + fieldoffset(T, 4)), is_express)
    end
    if !isnothing(allowed_destination)
        loc_v = allowed_destination isa Locality ? allowed_destination.v :
                Locality(allowed_destination).v
        unsafe_store!(Ptr{LibZenohC.z_locality_t}(p + fieldoffset(T, 5)), loc_v)
    end
    if !isnothing(priority)
        unsafe_store!(Ptr{LibZenohC.z_priority_t}(p + fieldoffset(T, 7)), priority)
    end
    if timeout_ms > 0
        unsafe_store!(Ptr{UInt64}(p + fieldoffset(T, 8)), UInt64(timeout_ms))
    end
    return opts
end

function _make_querier_get_opts(;
        payload = nothing,
        encoding::Union{Nothing, Encoding, AbstractString, Base.MIME} = nothing,
        attachment = nothing)
    opts = Ref{LibZenohC.z_querier_get_options_t}()
    LibZenohC.z_querier_get_options_default(opts)
    p = Base.unsafe_convert(Ptr{LibZenohC.z_querier_get_options_t}, opts)
    T = LibZenohC.z_querier_get_options_t
    payload_bytes = isnothing(payload)    ? nothing : ZBytes(payload)
    attach_bytes  = isnothing(attachment) ? nothing : ZBytes(attachment)
    enc_ref       = isnothing(encoding)   ? nothing : _to_owned_encoding(_as_encoding(encoding))
    if !isnothing(payload_bytes)
        unsafe_store!(Ptr{Ptr{LibZenohC.z_moved_bytes_t}}(p + fieldoffset(T, 1)),
                      _move(payload_bytes))
    end
    if !isnothing(enc_ref)
        unsafe_store!(Ptr{Ptr{LibZenohC.z_moved_encoding_t}}(p + fieldoffset(T, 2)),
                      _move(enc_ref))
    end
    if !isnothing(attach_bytes)
        # attachment sits after the `source_info` field (index 3) in
        # z_querier_get_options_t.
        unsafe_store!(Ptr{Ptr{LibZenohC.z_moved_bytes_t}}(p + fieldoffset(T, 4)),
                      _move(attach_bytes))
    end
    return opts, payload_bytes, attach_bytes, enc_ref
end

"""
    Querier

Long-lived query handle returned by `Querier(s::Session, k::Keyexpr; …)`.
Defaults (target, consolidation, QoS, timeout) are baked in at declare
time; each `get(querier, params; …)` reuses them. Two forms:

- channel: `get(querier, params; channel=:fifo|:ring, capacity=N)` →
  `GetHandler` (iterate / `take!` / `tryrecv!` for `Reply`s)
- callback: `get(f, querier, params; …)` invokes `f(::Reply)` on a
  dedicated task per reply (single-slot latest-wins, like
  `get(f, ::Session, …)`)

Call `close(q)` to undeclare.
"""
mutable struct Querier
    querier::Base.RefValue{LibZenohC.z_owned_querier_t}
    keyexpr::Keyexpr   # GC pin
    closed::Bool
end

_loan(q::Querier) = _loan(q.querier)

"""
    Querier(s::Session, k::Keyexpr; kwargs...) -> Querier

Declare a querier on session `s` for keyexpr `k`. Keyword arguments are
baked in as defaults for every subsequent `get(::Querier, …)` call:

- `target`              — `:best_matching`, `:all`, `:all_complete`
- `consolidation`       — `:auto`, `:none`, `:monotonic`, `:latest`
- `congestion_control`  — raw `z_congestion_control_t`
- `is_express`          — `Bool`
- `allowed_destination` — `Locality` or symbol (`:any`, `:remote`, …)
- `priority`            — raw `z_priority_t`
- `timeout_ms`          — request timeout in milliseconds (`0` = none)
"""
function Querier(s::Session, k::Keyexpr; kwargs...)
    opts = _make_querier_opts(; kwargs...)
    qref = Ref{LibZenohC.z_owned_querier_t}()
    rtc = GC.@preserve opts LibZenohC.z_declare_querier(
        _loan(s), qref, _loan(k), opts)
    _handle_result(rtc)
    return Querier(qref, k, false)
end

function Base.close(q::Querier)
    q.closed && return
    q.closed = true
    _handle_result(LibZenohC.z_undeclare_querier(_move(q.querier)))
    return nothing
end

function keyexpr(q::Querier)
    ke = LibZenohC.z_querier_keyexpr(_loan(q))
    view = Ref{LibZenohC.z_view_string_t}()
    LibZenohC.z_keyexpr_as_view_string(ke, view)
    loaned = LibZenohC.z_view_string_loan(view)
    return unsafe_string(LibZenohC.z_string_data(loaned), LibZenohC.z_string_len(loaned))
end

"""
    get(q::Querier, parameters=""; kwargs...) -> GetHandler

Issue a query on `q`, returning a `GetHandler` over the replies. Mirrors
`get(::Session, ::Keyexpr, params; …)` but reuses the querier's declared
target/consolidation/QoS.

Keyword arguments: `channel` (`:fifo`/`:ring`), `capacity`, `payload`,
`encoding`, `attachment`.
"""
function get(q::Querier, parameters::AbstractString="";
        channel::Symbol = :fifo,
        capacity::Integer = 16,
        payload = nothing,
        encoding::Union{Nothing, Encoding, AbstractString, Base.MIME} = nothing,
        attachment = nothing)
    opts, payload_bytes, attach_bytes, enc_ref =
        _make_querier_get_opts(; payload, encoding, attachment)

    closure = _make_closure_ref(Val(:reply))
    handler = _new_channel(Val(:reply), Val(channel), closure, capacity)

    params = String(parameters)
    GC.@preserve payload_bytes attach_bytes enc_ref params opts begin
        rtc = LibZenohC.z_querier_get(_loan(q),
            pointer(Base.unsafe_convert(Cstring, params)),
            _move(closure), opts)
        _handle_result(rtc)
    end

    return GetHandler{eltype(typeof(handler)), channel}(handler)
end

"""
    get(f, q::Querier, parameters=""; kwargs...)

Issue a query on `q` and invoke `f(::Reply)` on a dedicated task for each
reply that fits through the single-slot handoff. Mirrors
`get(f, ::Session, ::Keyexpr, params; …)`.

Keyword arguments: `should_close_on_error`, `payload`, `encoding`,
`attachment`.
"""
function get(f::Function, q::Querier, parameters::AbstractString="";
        should_close_on_error::Bool=true,
        payload = nothing,
        encoding::Union{Nothing, Encoding, AbstractString, Base.MIME} = nothing,
        attachment = nothing)
    opts, payload_bytes, attach_bytes, enc_ref =
        _make_querier_get_opts(; payload, encoding, attachment)

    params = String(parameters)
    _callback_get(f; should_close_on_error=should_close_on_error) do closure
        GC.@preserve payload_bytes attach_bytes enc_ref params opts begin
            LibZenohC.z_querier_get(_loan(q),
                pointer(Base.unsafe_convert(Cstring, params)),
                _move(closure), opts)
        end
    end
end

export Querier
