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
        attachment = nothing,
        cancellation::Union{Nothing, CancellationToken} = nothing)
    opts = Ref{LibZenohC.z_querier_get_options_t}()
    LibZenohC.z_querier_get_options_default(opts)
    # payload/attachment ZBytes carry no finalizer, so a throw mid-build would orphan any
    # already built — release them on this task. enc_ref self-cleans via its finalizer, and
    # the token clone is built last, so the catch covers only these two.
    payload_bytes = nothing
    attach_bytes  = nothing
    enc_ref       = nothing
    cancel_clone  = nothing
    try
        payload_bytes = isnothing(payload)    ? nothing : ZBytes(payload)
        attach_bytes  = isnothing(attachment) ? nothing : ZBytes(attachment)
        enc_ref       = isnothing(encoding)   ? nothing : _to_owned_encoding(_as_encoding(encoding))
        # The get consumes (moves) the token; clone so the caller keeps theirs to
        # cancel. The clone is returned for the caller to GC-preserve across the get.
        cancel_clone  = isnothing(cancellation) ? nothing : _clone(cancellation)
    catch
        payload_bytes === nothing || close(payload_bytes)
        attach_bytes  === nothing || close(attach_bytes)
        rethrow()
    end
    isnothing(payload_bytes) || _store_field!(opts, 1, _move(payload_bytes))
    isnothing(enc_ref)       || _store_field!(opts, 2, _move(enc_ref))
    # attachment sits after the `source_info` field (index 3); cancellation last.
    isnothing(attach_bytes)  || _store_field!(opts, 4, _move(attach_bytes))
    isnothing(cancel_clone)  || _store_field!(opts, 5, _move(cancel_clone))
    return opts, payload_bytes, attach_bytes, enc_ref, cancel_clone
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
    keyexpr::AbstractKeyexpr   # GC pin
    closed::Bool
    # Serializes `close` (which undeclares → gravestones `querier`) against every op that loans
    # `querier` — `get`, `keyexpr`, `querier_id`, `matching_status`, `MatchingListener`,
    # `ReusableGet.call!` — so a concurrent close can't gravestone the handle mid-loan (a UAF on
    # a libzenoh thread). Any new op that loans `querier` must take this lock. `ReentrantLock` so
    # a waiter yields while `z_querier_get` blocks; uncontended it is alloc-free.
    lock::Base.ReentrantLock
    Querier(querier::Base.RefValue{LibZenohC.z_owned_querier_t}, k::Keyexpr, closed::Bool) =
        new(querier, k, closed, Base.ReentrantLock())
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
    @lock q.lock begin
        q.closed && return nothing
        q.closed = true
        _handle_result(LibZenohC.z_undeclare_querier(_move(q.querier)))
    end
    return nothing
end

function keyexpr(q::Querier)
    @lock q.lock begin
        q.closed && throw(ArgumentError("keyexpr on a closed Querier"))
        # The view string borrows from q; keep q rooted until unsafe_string copies the bytes out.
        GC.@preserve q begin
            ke = LibZenohC.z_querier_keyexpr(_loan(q))
            view = Ref{LibZenohC.z_view_string_t}()
            LibZenohC.z_keyexpr_as_view_string(ke, view)
            loaned = LibZenohC.z_view_string_loan(view)
            return unsafe_string(LibZenohC.z_string_data(loaned), LibZenohC.z_string_len(loaned))
        end
    end
end

"""
    querier_id(q::Querier) -> (; zid, eid)

The querier's global entity id: the Zenoh id of its session (`zid`, a
`z_id_t` printable via `show`) paired with the session-local entity id
(`eid::UInt32`).
"""
function querier_id(q::Querier)
    @lock q.lock begin
        q.closed && throw(ArgumentError("querier_id on a closed Querier"))
        GC.@preserve q begin
            gid = Ref{LibZenohC.z_entity_global_id_t}(LibZenohC.z_querier_id(_loan(q)))
            GC.@preserve gid begin
                return (zid = LibZenohC.z_entity_global_id_zid(gid),
                        eid = LibZenohC.z_entity_global_id_eid(gid))
            end
        end
    end
end

"""
    get(q::Querier, parameters=""; kwargs...) -> GetHandler

Issue a query on `q`, returning a `GetHandler` over the replies. Mirrors
`get(::Session, ::Keyexpr, params; …)` but reuses the querier's declared
target/consolidation/QoS.

Keyword arguments: `channel` (`:fifo`/`:ring`), `capacity`, `payload`,
`encoding`, `attachment`, `cancellation` (a [`CancellationToken`](@ref);
`cancel` it to abort this get — the only per-call bound a querier get has).
"""
function Base.get(q::Querier, parameters::AbstractString="";
        channel::Symbol = :fifo,
        capacity::Integer = 16,
        payload = nothing,
        encoding::Union{Nothing, Encoding, AbstractString, Base.MIME} = nothing,
        attachment = nothing,
        cancellation::Union{Nothing, CancellationToken} = nothing)
    # Hold q.lock across opts-build + `_open_buffered_get` so a concurrent close can't
    # gravestone the handle, and the closed-check throws before any finalizer-less owned ZBytes
    # are built (no leak). `_open_buffered_get` never takes q.lock, so the hold can't deadlock;
    # `get` allocates a handler/channel/task anyway, so the wider scope costs nothing.
    @lock q.lock begin
        q.closed && throw(ArgumentError("get on a closed Querier"))
        opts, payload_bytes, attach_bytes, enc_ref, cancel_clone =
            _make_querier_get_opts(; payload, encoding, attachment, cancellation)

        # _substr takes (ptr, len) rather than a null-terminated string, so a
        # `SubString` view threads through without an intermediate copy.
        params = parameters isa Union{String, SubString{String}} ? parameters : String(parameters)
        # The ring delivers :fifo and :ring identically; channel has no effect here.
        _open_buffered_get(capacity) do closure
            GC.@preserve payload_bytes attach_bytes enc_ref cancel_clone params opts begin
                LibZenohC.z_querier_get_with_parameters_substr(_loan(q),
                    Ptr{Cchar}(pointer(params)), ncodeunits(params),
                    _move(closure), opts)
            end
        end
    end
end

"""
    get(f, q::Querier, parameters=""; kwargs...)

Issue a query on `q` and invoke `f(::Reply)` on a dedicated task for each
reply that fits through the single-slot handoff. Mirrors
`get(f, ::Session, ::Keyexpr, params; …)`.

Keyword arguments: `should_close_on_error`, `payload`, `encoding`,
`attachment`, `cancellation` (a [`CancellationToken`](@ref)).
"""
function Base.get(f::Function, q::Querier, parameters::AbstractString="";
        should_close_on_error::Bool=true,
        payload = nothing,
        encoding::Union{Nothing, Encoding, AbstractString, Base.MIME} = nothing,
        attachment = nothing,
        cancellation::Union{Nothing, CancellationToken} = nothing)
    # Hold q.lock from the closed-check through issuing the get so a concurrent close can't
    # gravestone the querier between them. Release it inside the get-closure the moment
    # z_querier_get returns, before `_callback_get`'s `wait(task)`: the reply handler `f` runs on
    # that task, so holding across the wait would deadlock an `f` that re-enters close(q)/get(q)
    # and would block a concurrent close for the whole query. The outer `finally` covers a throw
    # before the get-closure runs.
    lock(q.lock)
    locked = true
    try
        q.closed && throw(ArgumentError("get on a closed Querier"))
        opts, payload_bytes, attach_bytes, enc_ref, cancel_clone =
            _make_querier_get_opts(; payload, encoding, attachment, cancellation)

        params = parameters isa Union{String, SubString{String}} ? parameters : String(parameters)
        _callback_get(f; should_close_on_error=should_close_on_error) do closure
            try
                GC.@preserve payload_bytes attach_bytes enc_ref cancel_clone params opts begin
                    LibZenohC.z_querier_get_with_parameters_substr(_loan(q),
                        Ptr{Cchar}(pointer(params)), ncodeunits(params),
                        _move(closure), opts)
                end
            finally
                locked = false
                unlock(q.lock)
            end
        end
    finally
        locked && unlock(q.lock)
    end
end

export Querier, querier_id
