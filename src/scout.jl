# Scouting — discover nearby Zenoh nodes without opening a session.
#
# libzenohc's `z_scout` consumes a config and a `z_closure_hello`, then
# fires the closure once per peer it hears from within `timeout_ms` (or
# its default). The closure-side plumbing (trampolines, ctx, teardown)
# is stamped out by `@closure_kind :hello` in `closure_kinds.jl`; no
# FIFO/ring channel variants exist in libzenohc for hello — the macro's
# generated `_new_channel` / `_recv` / `_try_recv` methods reference
# nonexistent symbols and are inert dead code unless invoked.

# ── Hello ────────────────────────────────────────────────────────────

"""
    Hello

A peer announcement delivered by `scout`. Fields:

- `zid::z_id_t` — the peer's Zenoh ID.
- `whatami::z_whatami_t` — `Z_WHATAMI_ROUTER`, `_PEER`, or `_CLIENT`.
- `locators::Vector{String}` — endpoints the peer is reachable at.

Use `whatami_string(h.whatami)` for a human-readable role.
"""
struct Hello
    zid::LibZenohC.z_id_t
    whatami::LibZenohC.z_whatami_t
    locators::Vector{String}
end

# Eager extract from the owned hello the consume task memcpy'd out of
# the callback slot: the underlying `z_loaned_string_t` locators are
# owned by the hello, so we materialize them into Julia Strings here
# rather than holding the owned hello until the user finalizes.
function Hello(r::Base.RefValue{LibZenohC.z_owned_hello_t})
    loaned = LibZenohC.z_hello_loan(r)
    zid_v     = LibZenohC.z_hello_zid(loaned)
    whatami_v = LibZenohC.z_hello_whatami(loaned)

    arr = Ref{LibZenohC.z_owned_string_array_t}()
    LibZenohC.z_hello_locators(loaned, arr)
    arr_loaned = LibZenohC.z_string_array_loan(arr)
    n = LibZenohC.z_string_array_len(arr_loaned)
    locators = Vector{String}(undef, n)
    for i in 0:(n - 1)
        sp = LibZenohC.z_string_array_get(arr_loaned, Csize_t(i))
        locators[i + 1] = unsafe_string(
            LibZenohC.z_string_data(sp), LibZenohC.z_string_len(sp))
    end
    LibZenohC.z_string_array_drop(_move(arr))
    LibZenohC.z_hello_drop(_move(r))

    return Hello(zid_v, whatami_v, locators)
end

# ── whatami helpers ──────────────────────────────────────────────────

"""
    whatami_string(w::z_whatami_t) -> String

Human-readable name for a `z_whatami_t` value (lowercase: `"router"`,
`"peer"`, `"client"` — matches what libzenohc returns).
"""
function whatami_string(w::LibZenohC.z_whatami_t)
    view = Ref{LibZenohC.z_view_string_t}()
    _handle_result(LibZenohC.z_whatami_to_view_string(w, view))
    loaned = LibZenohC.z_view_string_loan(view)
    return unsafe_string(
        LibZenohC.z_string_data(loaned), LibZenohC.z_string_len(loaned))
end

function Base.show(io::IO, h::Hello)
    print(io, "Hello(", whatami_string(h.whatami), " ", h.zid,
        ", locators=", h.locators, ")")
end

# ── `what` keyword ───────────────────────────────────────────────────

const _WHAT_BITS = (
    router = UInt32(LibZenohC.Z_WHAT_ROUTER),
    peer   = UInt32(LibZenohC.Z_WHAT_PEER),
    client = UInt32(LibZenohC.Z_WHAT_CLIENT),
)

function _what_bits(atom::Symbol)
    bits = UInt32(0)
    for part in split(String(atom), '_')
        sym = Symbol(part)
        haskey(_WHAT_BITS, sym) ||
            throw(ArgumentError("unknown scout `what` atom: $(part)"))
        bits |= _WHAT_BITS[sym]
    end
    return bits
end

_what_value(::Nothing) = nothing
_what_value(s::Symbol) = LibZenohC.z_what_t(_what_bits(s))
function _what_value(xs::Union{Tuple, AbstractVector})
    bits = UInt32(0)
    for x in xs
        x isa Symbol || throw(ArgumentError(
            "scout `what` collection must contain Symbols, got $(typeof(x))"))
        bits |= _what_bits(x)
    end
    return LibZenohC.z_what_t(bits)
end

function _scout_opts(what)
    opts = Ref{LibZenohC.z_scout_options_t}()
    LibZenohC.z_scout_options_default(opts)
    w = _what_value(what)
    if !isnothing(w)
        Base.unsafe_convert(Ptr{LibZenohC.z_scout_options_t}, opts).what = w
    end
    return opts
end

# `z_scout` consumes its config (it takes `z_moved_config_t`), so we
# clone the caller's Config first — mirror of `Base.open(::Config)`.
function _clone_config(c::Config)
    copy = Ref{LibZenohC.z_owned_config_t}()
    LibZenohC.z_config_clone(copy, LibZenohC.z_config_loan(c.c))
    return copy
end

# ── scout ────────────────────────────────────────────────────────────

"""
    scout(f, config::Config; what=nothing, timeout_ms=0,
          should_close_on_error=true) -> Nothing

Invoke `f(::Hello)` on a dedicated Julia task for each peer announcement
heard during a scouting round. Blocks until libzenohc finishes the round
(timeout elapsed or scout otherwise terminated).

`what` filters which node roles to scout for; accepts a `Symbol`, a
collection of symbols, or `nothing` to use the libzenohc default.
Recognised atoms: `:router`, `:peer`, `:client`. Compound symbols are
split on `_`, so `:router_peer` and `(:router, :peer)` are equivalent.

`config` is cloned — `z_scout` consumes its config, so the caller's
`Config` remains usable.
"""
function scout(f::Function, config::Config;
        what=nothing, timeout_ms::Integer=0,
        should_close_on_error::Bool=true)
    opts = _scout_opts(what)
    if timeout_ms > 0
        Base.unsafe_convert(Ptr{LibZenohC.z_scout_options_t}, opts).timeout_ms =
            UInt64(timeout_ms)
    end
    cfg = _clone_config(config)
    _callback_one_shot(Val(:hello), Hello, f;
            should_close_on_error=should_close_on_error) do closure
        GC.@preserve opts cfg LibZenohC.z_scout(
            _move(cfg), _move(closure), opts)
    end
end

"""
    scout(config::Config; what=nothing, timeout_ms=0) -> Vector{Hello}

Block until scouting completes and return every `Hello` heard. See the
callback form for the meaning of `what` and `timeout_ms`.
"""
function scout(config::Config; what=nothing, timeout_ms::Integer=0)
    hellos = Hello[]
    # consume runs on a spawned thread; `wait(task)` inside
    # `_callback_one_shot` establishes happens-before, but the lock
    # documents the cross-task transfer.
    lock = ReentrantLock()
    scout(config; what=what, timeout_ms=timeout_ms,
            should_close_on_error=false) do h
        @lock lock push!(hellos, h)
    end
    return hellos
end
