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
# Base.setproperty! (Clang.jl skips POD structs without padding gaps), so
# fields are poked at their `fieldoffset` via `_store_field!`. The QoS /
# target / consolidation arguments are the same typed singletons every
# other entrypoint takes (`Priorities.REAL_TIME`, `QueryTargets.ALL`, …),
# with the same `Symbol` shorthand for target/consolidation as `get`.
function _make_querier_opts(;
        target::Union{Nothing, QueryTarget, Symbol} = nothing,
        consolidation::Union{Nothing, QueryConsolidation, Symbol} = nothing,
        congestion_control::Union{Nothing, CongestionControl} = nothing,
        express::Union{Nothing, Bool} = nothing,
        allowed_destination::Union{Nothing, Locality} = nothing,
        priority::Union{Nothing, Priority} = nothing,
        timeout_ms::Integer = 0)
    opts = Ref{LibZenohC.z_querier_options_t}()
    LibZenohC.z_querier_options_default(opts)
    isnothing(target)             || _store_field!(opts, 1, _as_query_target(target))
    isnothing(consolidation)      || _store_field!(opts, 2, _as_consolidation(consolidation))
    isnothing(congestion_control) || _store_field!(opts, 3, _raw(congestion_control))
    isnothing(express)            || _store_field!(opts, 4, express)
    isnothing(allowed_destination)|| _store_field!(opts, 5, _raw(allowed_destination))
    isnothing(priority)           || _store_field!(opts, 7, _raw(priority))
    timeout_ms > 0                && _store_field!(opts, 8, UInt64(timeout_ms))
    return opts
end

function _make_querier_get_opts(;
        payload = nothing,
        encoding::Union{Nothing, Encoding, AbstractString, Base.MIME} = nothing,
        attachment = nothing)
    opts = Ref{LibZenohC.z_querier_get_options_t}()
    LibZenohC.z_querier_get_options_default(opts)
    payload_bytes = isnothing(payload)    ? nothing : ZBytes(payload)
    attach_bytes  = isnothing(attachment) ? nothing : ZBytes(attachment)
    enc_ref       = isnothing(encoding)   ? nothing : _to_owned_encoding(_as_encoding(encoding))
    isnothing(payload_bytes) || _store_field!(opts, 1, _move(payload_bytes))
    isnothing(enc_ref)       || _store_field!(opts, 2, _move(enc_ref))
    # attachment sits after the `source_info` field (index 3).
    isnothing(attach_bytes)  || _store_field!(opts, 4, _move(attach_bytes))
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

- `target`              — `QueryTargets.BEST_MATCHING` / `ALL` / `ALL_COMPLETE`
                          (or `:best_matching` / `:all` / `:all_complete`)
- `consolidation`       — `QueryConsolidations.AUTO` / `NONE` / `MONOTONIC` / `LATEST`
                          (or `:auto` / `:none` / `:monotonic` / `:latest`)
- `congestion_control`  — `CongestionControls.BLOCK` or `DROP`
- `express`             — `Bool`
- `allowed_destination` — `Localities.ANY` / `SESSION_LOCAL` / `REMOTE`
- `priority`            — `Priorities.REAL_TIME` … `BACKGROUND`
- `timeout_ms`          — request timeout in milliseconds (`0` = none)
"""
function Querier(s::Session, k::Keyexpr; kwargs...)
    opts = _make_querier_opts(; kwargs...)
    qref = Ref{LibZenohC.z_owned_querier_t}()
    rtc = GC.@preserve opts LibZenohC.z_declare_querier(
        _loan(s), qref, _loan(k), opts)
    _handle_result(rtc)
    # GC safety net: drop the C handle if the Querier is dropped without an
    # explicit close(). The Querier owns no callback ctx/task (replies ride
    # per-get closures), so a plain drop is safe; no-op once close() has
    # moved the handle out.
    finalizer(q -> LibZenohC.z_querier_drop(_move(q)), qref)
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
    querier_id(q::Querier) -> (; zid, eid)

The querier's global entity id: the Zenoh id of its session (`zid`, a
`z_id_t` printable via `show`) paired with the session-local entity id
(`eid::UInt32`).
"""
function querier_id(q::Querier)
    gid = Ref{LibZenohC.z_entity_global_id_t}(LibZenohC.z_querier_id(_loan(q)))
    GC.@preserve gid begin
        return (zid = LibZenohC.z_entity_global_id_zid(gid),
                eid = LibZenohC.z_entity_global_id_eid(gid))
    end
end

"""
    get(q::Querier, parameters=""; kwargs...) -> GetHandler

Issue a query on `q`, returning a `GetHandler` over the replies. Mirrors
`get(::Session, ::Keyexpr, params; …)` but reuses the querier's declared
target/consolidation/QoS.

Keyword arguments: `channel` (`:fifo`/`:ring`), `capacity`, `payload`,
`encoding`, `attachment`.
"""
function Base.get(q::Querier, parameters::AbstractString="";
        channel::Symbol = :fifo,
        capacity::Integer = 16,
        payload = nothing,
        encoding::Union{Nothing, Encoding, AbstractString, Base.MIME} = nothing,
        attachment = nothing)
    opts, payload_bytes, attach_bytes, enc_ref =
        _make_querier_get_opts(; payload, encoding, attachment)

    closure = _make_closure_ref(Val(:reply))
    handler = _new_channel(Val(:reply), Val(channel), closure, capacity)

    # _substr takes (ptr, len) rather than a null-terminated string, so a
    # `SubString` view threads through without an intermediate copy.
    params = parameters isa Union{String, SubString{String}} ? parameters : String(parameters)
    GC.@preserve payload_bytes attach_bytes enc_ref params opts begin
        rtc = LibZenohC.z_querier_get_with_parameters_substr(_loan(q),
            Ptr{Cchar}(pointer(params)), ncodeunits(params),
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
function Base.get(f::Function, q::Querier, parameters::AbstractString="";
        should_close_on_error::Bool=true,
        payload = nothing,
        encoding::Union{Nothing, Encoding, AbstractString, Base.MIME} = nothing,
        attachment = nothing)
    opts, payload_bytes, attach_bytes, enc_ref =
        _make_querier_get_opts(; payload, encoding, attachment)

    params = parameters isa Union{String, SubString{String}} ? parameters : String(parameters)
    _callback_get(f; should_close_on_error=should_close_on_error) do closure
        GC.@preserve payload_bytes attach_bytes enc_ref params opts begin
            LibZenohC.z_querier_get_with_parameters_substr(_loan(q),
                Ptr{Cchar}(pointer(params)), ncodeunits(params),
                _move(closure), opts)
        end
    end
end

export Querier, querier_id
