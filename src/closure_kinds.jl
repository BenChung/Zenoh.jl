# Per-kind plumbing for Zenoh closure families.
#
# libzenohc's closure ABI is identical across `sample`, `reply`, `query`,
# `hello`, `matching_status`, … only the underlying owned/loaned/moved
# type names change. `@closure_kind :tag` stamps out:
#
#   • foreign-thread call/drop trampolines that delegate to the generic
#     `call_body!` / `drop_body!` in `callback.jl`
#   • module-level `Ref{Ptr{Cvoid}}` slots for the trampoline `@cfunction`
#     pointers and the `z_<tag>_clone` / `z_<tag>_drop` `cglobal` lookups
#   • an init hook (registered via `_register_init!`) that populates the
#     four slots in `__init__` — `@cfunction` / `cglobal` cannot be
#     evaluated at module top level because they bake JIT / loader
#     addresses into the precompile image
#   • per-kind method bodies for the generic dispatch hooks below
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

Generate the per-kind closure / channel plumbing for libzenohc family
`tag` (`sample`, `reply`, `query`, …). See file header for the list of
generated bindings. Naming follows libzenohc convention exactly:
`z_owned_<tag>_t`, `z_<tag>_clone`, `z_closure_<tag>`,
`z_fifo_channel_<tag>_new`, `z_fifo_handler_<tag>_recv`, etc.
"""
macro closure_kind(tag_expr)
    tag = tag_expr isa QuoteNode ? tag_expr.value : tag_expr
    tag isa Symbol || throw(ArgumentError(
        "@closure_kind expects a literal symbol, got $(tag_expr)"))

    # libzenohc type / function names derived from the tag.
    loaned_t        = Symbol("z_loaned_",         tag, "_t")
    owned_t         = Symbol("z_owned_",          tag, "_t")
    moved_t         = Symbol("z_moved_",          tag, "_t")
    item_clone_sym  = Symbol("z_",                tag, "_clone")
    item_drop_sym   = Symbol("z_",                tag, "_drop")
    closure_owned_t = Symbol("z_owned_closure_",  tag, "_t")
    closure_install = Symbol("z_closure_",        tag)

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

    # Module-level slot + trampoline function names (unique per tag).
    upper = uppercase(string(tag))
    call_cb_ref   = Symbol("_CALL_CB_",   upper)
    drop_cb_ref   = Symbol("_DROP_CB_",   upper)
    item_clone_fp = Symbol("_CLONE_FP_",  upper)
    item_drop_fp  = Symbol("_DROP_FP_",   upper)
    call_tramp    = Symbol("_call_tramp_", tag)
    drop_tramp    = Symbol("_drop_tramp_", tag)

    val_t = :(Val{$(QuoteNode(tag))})

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
                async_cond::Base.AsyncCondition)
            destroy_ctx!(ctx, async_cond,
                $item_drop_fp[], LibZenohC.$moved_t)
        end

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

        @inline _recv(::$val_t, ::Val{:fifo},
                h::Ptr{LibZenohC.$fifo_loaned},
                o::Ptr{LibZenohC.$owned_t}) =
            @threadcall(($(QuoteNode(fifo_recv)), LibZenohC.libzenohc),
                LibZenohC.z_result_t,
                (Ptr{LibZenohC.$fifo_loaned}, Ptr{LibZenohC.$owned_t}),
                h, o)
        @inline _recv(::$val_t, ::Val{:ring},
                h::Ptr{LibZenohC.$ring_loaned},
                o::Ptr{LibZenohC.$owned_t}) =
            @threadcall(($(QuoteNode(ring_recv)), LibZenohC.libzenohc),
                LibZenohC.z_result_t,
                (Ptr{LibZenohC.$ring_loaned}, Ptr{LibZenohC.$owned_t}),
                h, o)

        @inline _try_recv(::$val_t, ::Val{:fifo}, h, o) =
            LibZenohC.$fifo_try(h, o)
        @inline _try_recv(::$val_t, ::Val{:ring}, h, o) =
            LibZenohC.$ring_try(h, o)
    end)
end

# ── Shared callback lifecycle helper ────────────────────────────────────
#
# Build the ctx + async + closure trio for a callback of the given kind.
# Once the closure is handed to libzenohc via the kind-specific
# declare/get entrypoint, samples / replies / queries / … start landing
# in the ctx's inline cell. Tear down with `_teardown_callback(kind, …)`.

function _setup_callback(kind::Val)
    ctx        = _make_callback_ctx(kind)
    async_cond = Base.AsyncCondition()
    init_ctx!(ctx, async_cond)
    closure    = _make_closure_ref(kind)
    _install_closure!(kind, closure, ctx)
    return ctx, async_cond, closure
end

# ── Standard kinds ──────────────────────────────────────────────────────

@closure_kind :sample
@closure_kind :reply
