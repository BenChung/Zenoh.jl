# Per-kind plumbing for Zenoh closure families.
#
# libzenohc's closure ABI is identical across `sample`, `reply`, `query`,
# `hello`, `matching_status`, … only the underlying type names change.
# Two payload shapes are supported:
#
#   • `:owned` (default) — payload is a refcounted `z_owned_<tag>_t`
#     accessed via `z_loaned_<tag>_t`. clone/drop fps come from cglobal'd
#     `z_<tag>_clone` / `z_<tag>_drop`. Native FIFO/ring channel handlers
#     (`z_{fifo,ring}_channel_<tag>_new`, …) are wired through too.
#   • `:pod` — payload is a plain `z_<tag>_t` value type with no
#     lifecycle (matching_status, …). No clone/drop, no channel handlers
#     — those C entrypoints simply don't exist for POD payloads.
#
# `@closure_kind :tag [:shape]` stamps out:
#
#   • foreign-thread call/drop trampolines that delegate to the generic
#     `call_body!` / `call_body_pod!` / `drop_body!` in `callback.jl`
#   • module-level `Ref{Ptr{Cvoid}}` slots for the trampoline `@cfunction`
#     pointers (and, for `:owned`, the `z_<tag>_clone` / `z_<tag>_drop`
#     `cglobal` lookups)
#   • an init hook (registered via `_register_init!`) that populates
#     the slots in `__init__` — `@cfunction` / `cglobal` cannot be
#     evaluated at module top level because they bake JIT / loader
#     addresses into the precompile image
#   • per-kind method bodies for the generic dispatch hooks below
#     (channel hooks `_new_channel` / `_recv` / `_try_recv` only for
#     `:owned` kinds)
#
# Adding a new kind to the binding is one macro line (plus a `Sample` /
# `Reply`-style wrapper type in its own file if the data needs one).

# ── Generic dispatch hooks ──────────────────────────────────────────────
# Per-kind methods are added by `@closure_kind`. Declaring the names up
# front so every orchestrator file (subscriber.jl, get_callback.jl,
# channel.jl, liveliness.jl, …) sees the same function object.

function _make_callback_ctx end
function _make_closure_ref end
function _install_closure! end
function _teardown_callback end
function _new_channel end
function _recv end
function _try_recv end

"""
    @closure_kind :tag
    @closure_kind :tag :owned
    @closure_kind :tag :pod
    @closure_kind :tag :owned channels=false

Generate the per-kind closure plumbing for libzenohc family `tag`
(`sample`, `reply`, `query`, `matching_status`, `hello`, …). Shape
defaults to `:owned`; pass `:pod` for value-type payloads with no
clone/drop and no channel handlers. See file header for the full
expansion.

For `:owned` kinds with no native FIFO/ring channel handlers in
libzenohc (e.g. `:hello`), pass `channels=false` to suppress the
channel-handler methods — they reference `z_{fifo,ring}_*_<tag>_t`
type names that Julia resolves at parse time, so they cannot be
emitted as dead code. `:pod` kinds always skip channels.

Naming follows libzenohc convention exactly:
`:owned` →  `z_owned_<tag>_t`, `z_<tag>_clone`, `z_closure_<tag>`,
            `z_fifo_channel_<tag>_new`, `z_fifo_handler_<tag>_recv`, …
`:pod`   →  `z_<tag>_t`, `z_closure_<tag>` (no clone/drop, no channels).
"""
macro closure_kind(tag_expr, args...)
    tag = tag_expr isa QuoteNode ? tag_expr.value : tag_expr
    tag isa Symbol || throw(ArgumentError(
        "@closure_kind expects a literal symbol tag, got $(tag_expr)"))

    shape = :owned
    channels = true
    channels_seen = false
    for a in args
        if a isa QuoteNode && a.value isa Symbol
            shape = a.value
        elseif a isa Expr && a.head === :(=) && a.args[1] === :channels
            channels = a.args[2]::Bool
            channels_seen = true
        else
            throw(ArgumentError(
                "unexpected @closure_kind arg: $(a) (want a :shape literal or channels=true|false)"))
        end
    end
    if shape === :pod && channels_seen && channels
        throw(ArgumentError("@closure_kind :pod does not support channels=true"))
    end
    shape === :pod && (channels = false)

    closure_owned_t = Symbol("z_owned_closure_",  tag, "_t")
    closure_install = Symbol("z_closure_",        tag)

    upper = uppercase(string(tag))
    call_cb_ref = Symbol("_CALL_CB_",   upper)
    drop_cb_ref = Symbol("_DROP_CB_",   upper)
    call_tramp  = Symbol("_call_tramp_", tag)
    drop_tramp  = Symbol("_drop_tramp_", tag)

    val_t = :(Val{$(QuoteNode(tag))})

    if shape === :owned
        loaned_t       = Symbol("z_loaned_", tag, "_t")
        owned_t        = Symbol("z_owned_",  tag, "_t")
        moved_t        = Symbol("z_moved_",  tag, "_t")
        item_clone_sym = Symbol("z_", tag, "_clone")
        item_drop_sym  = Symbol("z_", tag, "_drop")
        item_clone_fp  = Symbol("_CLONE_FP_", upper)
        item_drop_fp   = Symbol("_DROP_FP_",  upper)

        channel_block = if channels
            fifo_owned  = Symbol("z_owned_fifo_handler_",  tag, "_t")
            fifo_loaned = Symbol("z_loaned_fifo_handler_", tag, "_t")
            fifo_new    = Symbol("z_fifo_channel_",        tag, "_new")
            fifo_recv   = Symbol("z_fifo_handler_",        tag, "_recv")
            fifo_try    = Symbol("z_fifo_handler_",        tag, "_try_recv")
            fifo_drop   = Symbol("z_fifo_handler_",        tag, "_drop")

            ring_owned  = Symbol("z_owned_ring_handler_",  tag, "_t")
            ring_loaned = Symbol("z_loaned_ring_handler_", tag, "_t")
            ring_new    = Symbol("z_ring_channel_",        tag, "_new")
            ring_recv   = Symbol("z_ring_handler_",        tag, "_recv")
            ring_try    = Symbol("z_ring_handler_",        tag, "_try_recv")
            ring_drop   = Symbol("z_ring_handler_",        tag, "_drop")

            quote
                function _new_channel(::$val_t, ::Val{:fifo},
                        closure::Ref{LibZenohC.$closure_owned_t},
                        capacity::Integer)
                    h = Ref{LibZenohC.$fifo_owned}()
                    LibZenohC.$fifo_new(closure, h, Csize_t(capacity))
                    finalizer(x -> LibZenohC.$fifo_drop(_move(x)), h)
                    return h
                end
                function _new_channel(::$val_t, ::Val{:ring},
                        closure::Ref{LibZenohC.$closure_owned_t},
                        capacity::Integer)
                    h = Ref{LibZenohC.$ring_owned}()
                    LibZenohC.$ring_new(closure, h, Csize_t(capacity))
                    finalizer(x -> LibZenohC.$ring_drop(_move(x)), h)
                    return h
                end

                # `@gc_safe_threadcall` (not `@threadcall`): the blocking recv runs on
                # a libuv worker thread that the runtime adopts (GC-tracks). Base's
                # `@threadcall` leaves that worker GC-*unsafe* while parked in the recv,
                # so a stop-the-world GC on another thread (e.g. JIT during live
                # traffic) waits for it forever — a deadlock. The gc_safe variant marks
                # the worker GC-safe for the blocking call's duration (it touches no
                # Julia heap), so GC never waits on it. See core/gc_safe_threadcall.jl.
                @inline _recv(::$val_t, ::Val{:fifo},
                        h::Ptr{LibZenohC.$fifo_loaned},
                        o::Ptr{LibZenohC.$owned_t}) =
                    @gc_safe_threadcall(($(QuoteNode(fifo_recv)), LibZenohC.libzenohc),
                        LibZenohC.z_result_t,
                        (Ptr{LibZenohC.$fifo_loaned}, Ptr{LibZenohC.$owned_t}),
                        h, o)
                @inline _recv(::$val_t, ::Val{:ring},
                        h::Ptr{LibZenohC.$ring_loaned},
                        o::Ptr{LibZenohC.$owned_t}) =
                    @gc_safe_threadcall(($(QuoteNode(ring_recv)), LibZenohC.libzenohc),
                        LibZenohC.z_result_t,
                        (Ptr{LibZenohC.$ring_loaned}, Ptr{LibZenohC.$owned_t}),
                        h, o)

                @inline _try_recv(::$val_t, ::Val{:fifo}, h, o) =
                    LibZenohC.$fifo_try(h, o)
                @inline _try_recv(::$val_t, ::Val{:ring}, h, o) =
                    LibZenohC.$ring_try(h, o)
            end
        else
            quote end
        end

        return esc(quote
            const $call_cb_ref   = Ref{Ptr{Cvoid}}(C_NULL)
            const $drop_cb_ref   = Ref{Ptr{Cvoid}}(C_NULL)
            const $item_clone_fp = Ref{Ptr{Cvoid}}(C_NULL)
            const $item_drop_fp  = Ref{Ptr{Cvoid}}(C_NULL)

            function $call_tramp(item::Ptr{LibZenohC.$loaned_t},
                    ctx::Ptr{Cvoid})
                call_body!(item, ctx, $item_clone_fp[], $item_drop_fp[],
                    LibZenohC.$owned_t, LibZenohC.$moved_t)
            end
            function $drop_tramp(ctx::Ptr{Cvoid})
                drop_body!(ctx, LibZenohC.$owned_t)
            end

            _register_init!() do
                $call_cb_ref[] = @cfunction($call_tramp, Cvoid,
                    (Ptr{LibZenohC.$loaned_t}, Ptr{Cvoid}))
                $drop_cb_ref[] = @cfunction($drop_tramp, Cvoid, (Ptr{Cvoid},))
                $item_clone_fp[] = cglobal(
                    ($(QuoteNode(item_clone_sym)), LibZenohC.libzenohc))
                $item_drop_fp[]  = cglobal(
                    ($(QuoteNode(item_drop_sym)),  LibZenohC.libzenohc))
            end

            _make_callback_ctx(::$val_t) = CallbackCtx{LibZenohC.$owned_t}()
            _make_closure_ref(::$val_t)  = Ref{LibZenohC.$closure_owned_t}()

            function _install_closure!(::$val_t,
                    closure::Ref{LibZenohC.$closure_owned_t},
                    ctx::CallbackCtx{LibZenohC.$owned_t})
                LibZenohC.$closure_install(closure,
                    $call_cb_ref[], $drop_cb_ref[], ctx_p(ctx))
            end

            function _teardown_callback(::$val_t,
                    ctx::CallbackCtx{LibZenohC.$owned_t},
                    async_cond::Base.AsyncCondition; close_async::Bool=true)
                destroy_ctx!(ctx, async_cond,
                    $item_drop_fp[], LibZenohC.$moved_t; close_async)
            end

            $channel_block
        end)
    elseif shape === :pod
        item_t = Symbol("z_", tag, "_t")
        return esc(quote
            const $call_cb_ref = Ref{Ptr{Cvoid}}(C_NULL)
            const $drop_cb_ref = Ref{Ptr{Cvoid}}(C_NULL)

            function $call_tramp(item::Ptr{LibZenohC.$item_t},
                    ctx::Ptr{Cvoid})
                call_body_pod!(item, ctx, LibZenohC.$item_t)
            end
            function $drop_tramp(ctx::Ptr{Cvoid})
                drop_body!(ctx, LibZenohC.$item_t)
            end

            _register_init!() do
                $call_cb_ref[] = @cfunction($call_tramp, Cvoid,
                    (Ptr{LibZenohC.$item_t}, Ptr{Cvoid}))
                $drop_cb_ref[] = @cfunction($drop_tramp, Cvoid, (Ptr{Cvoid},))
            end

            _make_callback_ctx(::$val_t) = CallbackCtx{LibZenohC.$item_t}()
            _make_closure_ref(::$val_t)  = Ref{LibZenohC.$closure_owned_t}()

            function _install_closure!(::$val_t,
                    closure::Ref{LibZenohC.$closure_owned_t},
                    ctx::CallbackCtx{LibZenohC.$item_t})
                LibZenohC.$closure_install(closure,
                    $call_cb_ref[], $drop_cb_ref[], ctx_p(ctx))
            end

            function _teardown_callback(::$val_t,
                    ctx::CallbackCtx{LibZenohC.$item_t},
                    async_cond::Base.AsyncCondition; close_async::Bool=true)
                destroy_ctx_pod!(ctx, async_cond; close_async)
            end
        end)
    else
        throw(ArgumentError(
            "@closure_kind shape must be :owned or :pod, got :$(shape)"))
    end
end

# ── Shared callback lifecycle helper ────────────────────────────────────
#
# Build the ctx + async + closure trio for a callback of the given kind.
# Once the closure is handed to libzenohc via the kind-specific
# declare/get entrypoint, samples / replies / queries / … start landing
# in the ctx's inline cell. Tear down with `_teardown_callback(kind, …)`.

function _setup_callback(kind::Val, capacity::Integer=1)
    ctx        = _make_callback_ctx(kind)
    async_cond = Base.AsyncCondition()
    init_ctx!(ctx, async_cond, capacity)
    closure    = _make_closure_ref(kind)
    _install_closure!(kind, closure, ctx)
    return ctx, async_cond, closure
end

# ── Shared one-shot callback driver ─────────────────────────────────────
#
# Wraps a C entrypoint that consumes a closure and delivers a finite
# series of items, then drops the closure. The consume task is spawned
# before the C call so it's already waiting when libzenohc starts
# delivering items. On error the closure's drop callback fires regardless
# (libzenohc owns it), so we always wait for the task before destroying
# the ctx. Used by `_callback_get` (replies) and the callback form of
# `scout` (hellos).
#
# `call_fn` is first so `do` syntax composes: `_callback_one_shot(kind,
# wrap, f; …) do closure … end` passes the lambda as `call_fn`.
function _callback_one_shot(call_fn::F, kind::Val, wrap, f::Function;
        should_close_on_error::Bool=true) where F
    ctx, async_cond, closure = _setup_callback(kind)

    task = Threads.@spawn consume(f, wrap, ctx, async_cond, should_close_on_error)

    rtc = GC.@preserve ctx call_fn(closure)

    wait(task)
    _teardown_callback(kind, ctx, async_cond)
    rtc == LibZenohC.Z_OK || _handle_result(rtc)
    return nothing
end

# ── Standard kinds ──────────────────────────────────────────────────────

@closure_kind :sample
@closure_kind :reply
@closure_kind :query
@closure_kind :matching_status :pod
@closure_kind :hello :owned channels=false
