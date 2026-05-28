# Generic single-slot overwrite-on-full callback infrastructure shared
# by the callback subscriber (`open(f, s, k)`) and callback get
# (`get(f, s, k, …)`).
#
# Zenoh delivers values on libzenohc's I/O thread. The Julia heap is
# off-limits from foreign threads, so the trampoline only does ccalls
# and pointer arithmetic: stash the incoming value into a single inline
# cell, evict the previous occupant if any (latest-wins), and wake a
# Julia consumer task via `uv_async_send`. The consumer runs the user's
# `f` on a normal Julia task.
#
# Two payload shapes share this machinery:
#   • Owned — `z_owned_<tag>_t` refcounted items (sample, reply, query):
#     `call_body!` clones into the slot and `drop`s the prior occupant on
#     overwrite or teardown via cglobal'd `z_<tag>_clone`/`_drop` fps.
#   • POD — plain `z_<tag>_t` value types (matching_status, …):
#     `call_body_pod!` byte-copies into the slot. No resource lifecycle,
#     so no clone/drop fps and `destroy_ctx_pod!` skips the drain.
#
# The cell is one item, not a queue: if the consumer is slow, older
# values are silently dropped. For queued semantics use the channel
# handlers in `channel.jl` (owned-shape kinds only — POD kinds have no
# native channel handlers in libzenohc).

# Context block — allocated by Julia, lifetime tied to the owner. The
# `mutex` field must sit at offset 0 because libuv's `uv_mutex_*` API
# operates on `uv_mutex_t*`, and we hand libzenohc the ctx pointer
# directly as the mutex handle.
mutable struct CallbackCtx{Item}
    mutex::NTuple{128, UInt8}              # uv_mutex_t storage (128B upper bound)
    item::Item                             # inline cell; owned clone or POD copy
    has::UInt8                             # 1 ⇔ slot is occupied
    closing::UInt8                         # 1 ⇔ shutting down; trampoline bails
    async::Ptr{Cvoid}                      # uv_async_t* from Base.AsyncCondition
    CallbackCtx{Item}() where {Item} = new()
end

@assert fieldoffset(CallbackCtx{LibZenohC.z_owned_sample_t}, 1) == 0

@inline ctx_p(ctx::CallbackCtx) = Ptr{Cvoid}(pointer_from_objref(ctx))
@inline item_p(ctx::Ptr{Cvoid}, ::Type{Item}) where {Item} =
    Ptr{Item}(ctx + fieldoffset(CallbackCtx{Item}, 2))
@inline has_p(ctx::Ptr{Cvoid}, ::Type{Item}) where {Item} =
    Ptr{UInt8}(ctx + fieldoffset(CallbackCtx{Item}, 3))
@inline closing_p(ctx::Ptr{Cvoid}, ::Type{Item}) where {Item} =
    Ptr{UInt8}(ctx + fieldoffset(CallbackCtx{Item}, 4))
@inline async_handle(ctx::Ptr{Cvoid}, ::Type{Item}) where {Item} =
    unsafe_load(Ptr{Ptr{Cvoid}}(ctx + fieldoffset(CallbackCtx{Item}, 5)))

# --- Foreign-thread trampoline bodies --------------------------------
#
# These run on libzenohc's I/O thread; restricted to ccalls and
# pointer arithmetic. The per-type trampoline (in subscriber.jl /
# get_callback.jl) is a thin wrapper that forwards to these with
# the right type parameters and clone/drop function pointers.

@inline function call_body!(item_ptr::Ptr{Loaned}, ctx::Ptr{Cvoid},
        clone_fp::Ptr{Cvoid}, drop_fp::Ptr{Cvoid},
        ::Type{Owned}, ::Type{Moved}) where {Loaned, Owned, Moved}
    ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), ctx)
    if unsafe_load(closing_p(ctx, Owned)) != 0
        ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), ctx)
        return nothing
    end
    if unsafe_load(has_p(ctx, Owned)) != 0
        # Overwrite: drop the stale value the consumer never picked up.
        ccall(drop_fp, Cvoid, (Ptr{Moved},),
            Ptr{Moved}(item_p(ctx, Owned)))
    end
    # Refcount bump into the inline slot — no malloc, no payload copy.
    ccall(clone_fp, Cvoid, (Ptr{Owned}, Ptr{Loaned}),
        item_p(ctx, Owned), item_ptr)
    unsafe_store!(has_p(ctx, Owned), UInt8(1))
    async = async_handle(ctx, Owned)
    ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), ctx)
    ccall(:uv_async_send, Cint, (Ptr{Cvoid},), async)
    return nothing
end

# POD variant: payload is a plain `z_<tag>_t` value (e.g.
# `z_matching_status_t`). No clone/drop fns exist for these, so the
# slot write is a byte copy and overwrite is in-place — no eviction
# needed because the prior occupant owns no resources.
@inline function call_body_pod!(item_ptr::Ptr{Item}, ctx::Ptr{Cvoid},
        ::Type{Item}) where {Item}
    ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), ctx)
    if unsafe_load(closing_p(ctx, Item)) != 0
        ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), ctx)
        return nothing
    end
    unsafe_copyto!(item_p(ctx, Item), item_ptr, 1)
    unsafe_store!(has_p(ctx, Item), UInt8(1))
    async = async_handle(ctx, Item)
    ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), ctx)
    ccall(:uv_async_send, Cint, (Ptr{Cvoid},), async)
    return nothing
end

# Fires once libzenohc is done with the closure. Flag closing so any
# IO callback that hasn't yet acquired the cell will bail, and wake
# the consumer so it sees the flag and exits. Item-type-agnostic — the
# only thing it touches in the ctx is the closing flag and async
# handle, both at fixed offsets.
@inline function drop_body!(ctx::Ptr{Cvoid}, ::Type{Item}) where {Item}
    ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), ctx)
    unsafe_store!(closing_p(ctx, Item), UInt8(1))
    ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), ctx)
    ccall(:uv_async_send, Cint, (Ptr{Cvoid},), async_handle(ctx, Item))
    return nothing
end

# --- Julia-side helpers ----------------------------------------------

function init_ctx!(ctx::CallbackCtx, async_cond::Base.AsyncCondition)
    ctx.has = 0
    ctx.closing = 0
    ctx.async = Base.unsafe_convert(Ptr{Cvoid}, async_cond)
    rc = ccall(:uv_mutex_init, Cint, (Ptr{Cvoid},), ctx_p(ctx))
    rc == 0 || error("uv_mutex_init failed: $rc")
    return ctx
end

# Signal closing under the mutex so the IO trampoline observes the
# update atomically with its other cell reads, then wake the consumer.
function signal_closing!(ctx::CallbackCtx{Item},
        async_cond::Base.AsyncCondition) where {Item}
    cp = ctx_p(ctx)
    ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), cp)
    unsafe_store!(closing_p(cp, Item), UInt8(1))
    ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), cp)
    ccall(:uv_async_send, Cint, (Ptr{Cvoid},),
        Base.unsafe_convert(Ptr{Cvoid}, async_cond))
end

# Drain any residual occupant of the cell (a cb fired after the
# consumer last drained but before it observed closing), then destroy
# the mutex and close the async condition.
function destroy_ctx!(ctx::CallbackCtx{Owned},
        async_cond::Base.AsyncCondition,
        drop_fp::Ptr{Cvoid}, ::Type{Moved}) where {Owned, Moved}
    cp = ctx_p(ctx)
    if unsafe_load(has_p(cp, Owned)) != 0
        ccall(drop_fp, Cvoid, (Ptr{Moved},),
            Ptr{Moved}(item_p(cp, Owned)))
    end
    ccall(:uv_mutex_destroy, Cvoid, (Ptr{Cvoid},), cp)
    close(async_cond)
end

# POD variant: no resource to free, so destroy is just mutex + async.
function destroy_ctx_pod!(ctx::CallbackCtx{Item},
        async_cond::Base.AsyncCondition) where {Item}
    ccall(:uv_mutex_destroy, Cvoid, (Ptr{Cvoid},), ctx_p(ctx))
    close(async_cond)
end

# Consumer loop. Yields the cell value — wrapped via `wrap(::Ref{Item})`
# into a user-facing Julia value (Sample, Reply, Bool, …) — to `f`. For
# owned items the wrap step is typically a constructor (Sample/Reply)
# that attaches a finalizer so the value drops on GC; for POD items it
# extracts the relevant field (e.g. `r -> r[].matching`). `DataType`
# doesn't subtype `Function`, so `wrap` is untyped here.
function consume(f, wrap,
        ctx::CallbackCtx{Item}, async_cond::Base.AsyncCondition,
        should_close_on_error::Bool) where {Item}
    cp = ctx_p(ctx)
    while true
        try
            wait(async_cond)
        catch
            return                          # async_cond closed
        end

        ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), cp)
        has     = unsafe_load(has_p(cp, Item)) != 0
        closing = unsafe_load(closing_p(cp, Item)) != 0
        if has
            # memcpy the cell value out of the slot into a local Ref
            # and clear `has`. For owned items ownership transfers to
            # the Ref (its finalizer drops on GC); for POD items the
            # copy is just a value move. The slot is empty for the
            # next IO callback either way.
            local_item = Ref{Item}()
            GC.@preserve local_item ctx begin
                unsafe_copyto!(
                    Base.unsafe_convert(Ptr{Item}, local_item),
                    item_p(cp, Item), 1)
            end
            unsafe_store!(has_p(cp, Item), UInt8(0))
            ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), cp)

            wrapped = wrap(local_item)
            user_threw = false
            try
                f(wrapped)
            catch e
                @error "Zenoh callback failed" exception=(e, catch_backtrace())
                user_threw = true
            end
            user_threw && should_close_on_error && return
        else
            ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), cp)
        end
        closing && return
    end
end

# Module-level cfunction pointer registry. Each callback type
# (subscriber/get/…) appends its (call, drop) pair here and reads
# clone/drop function pointers via cglobal. Populated by `__init__`.
const _CB_INIT_HOOKS = Function[]
_register_init!(f::Function) = (push!(_CB_INIT_HOOKS, f); f)
