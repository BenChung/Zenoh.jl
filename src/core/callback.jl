# Capacity-bounded ring callback infrastructure shared by the callback
# subscriber (`open(f, s, k)`), the buffered subscriber/queryable handlers
# (`open(s, k; channel=:fifo)`), the channel `get`, and the matching /
# sample-miss listeners.
#
# Zenoh delivers values on libzenohc's I/O thread. The Julia heap is
# off-limits from foreign threads, so the trampoline only does ccalls and
# pointer arithmetic: clone the incoming value into a fixed-capacity ring,
# evicting the oldest occupant (drop-oldest) if the ring is full, then wake a
# Julia consumer task via `uv_async_send`. The consumer drains the ring on a
# normal Julia task.
#
# The ring storage is a Julia-managed `Vector{Item}` held by the ctx; its data
# pointer is cached into the `ring` field at declare time and the foreign
# thread indexes it via byte arithmetic. The payload bytes stay on the Zenoh
# side under their own refcount — `z_<tag>_clone` only bumps a refcount, so a
# slot holds just the small owned handle. The foreign thread NEVER allocates:
# overflow is drop-oldest (never grow), so the buffer is allocated once.
#
# `capacity == 1` reduces to the single-slot latest-wins behaviour the
# callback `open(f, …)` / matching / miss listeners rely on.
#
# Two payload shapes share this machinery:
#   • Owned — `z_owned_<tag>_t` refcounted items (sample, reply, query):
#     `call_body!` clones into a slot and `drop`s the evicted occupant via
#     cglobal'd `z_<tag>_clone`/`_drop` fps.
#   • POD — plain `z_<tag>_t` value types (matching_status, ze_miss_t):
#     `call_body_pod!` byte-copies into slot 0 (always capacity 1). No
#     resource lifecycle, so no clone/drop fps and `destroy_ctx_pod!` skips
#     the drain.

# Context block — allocated by Julia, lifetime tied to the owner. The `mutex`
# field must sit at offset 0 because libuv's `uv_mutex_*` API operates on
# `uv_mutex_t*`, and we hand libzenohc the ctx pointer directly as the mutex
# handle. The foreign thread reaches every other field it needs by
# `fieldoffset`, so each is a scalar or a `Ptr`; `buf` (the Julia ring owner)
# is never touched from the foreign thread — it only keeps `ring` alive.
mutable struct CallbackCtx{Item}
    mutex::NTuple{128, UInt8}              # field 1 — uv_mutex_t storage; offset 0
    async::Ptr{Cvoid}                      # field 2 — uv_async_t* from Base.AsyncCondition
    ring::Ptr{Item}                        # field 3 — cached pointer(buf); foreign-indexed
    cap::Csize_t                           # field 4 — slot count (≥ 1)
    head::Csize_t                          # field 5 — index of oldest occupied slot
    count::Csize_t                         # field 6 — occupied slots (0 ⇔ empty, cap ⇔ full)
    dropped::Csize_t                       # field 7 — overflow drop counter (written under mutex)
    closing::UInt8                         # field 8 — 1 ⇔ shutting down; trampoline bails
    buf::Vector{Item}                      # field 9 — GC owner of the ring storage
    destroyed::Bool                        # field 10 — idempotency guard for destroy_ctx!;
                                           #   Julia-side only, never read by the foreign thread,
                                           #   so it adds no foreign-accessed offset
    CallbackCtx{Item}() where {Item} = new()
end

@assert fieldoffset(CallbackCtx{LibZenohC.z_owned_sample_t}, 1) == 0

@inline ctx_p(ctx::CallbackCtx) = Ptr{Cvoid}(pointer_from_objref(ctx))

# Foreign-thread field accessors — raw offset loads/stores against the ctx
# pointer. These exist because the trampoline cannot touch the boxed ctx; the
# Julia-side helpers below use ordinary field access (`ctx.count`) and array
# indexing (`ctx.buf[i]`) on the same bytes instead.
@inline async_handle(ctx::Ptr{Cvoid}, ::Type{I}) where {I} =
    unsafe_load(Ptr{Ptr{Cvoid}}(ctx + fieldoffset(CallbackCtx{I}, 2)))
@inline ring_p(ctx::Ptr{Cvoid}, ::Type{I}) where {I} =
    Ptr{Ptr{I}}(ctx + fieldoffset(CallbackCtx{I}, 3))
@inline cap_p(ctx::Ptr{Cvoid}, ::Type{I}) where {I} =
    Ptr{Csize_t}(ctx + fieldoffset(CallbackCtx{I}, 4))
@inline head_p(ctx::Ptr{Cvoid}, ::Type{I}) where {I} =
    Ptr{Csize_t}(ctx + fieldoffset(CallbackCtx{I}, 5))
@inline count_p(ctx::Ptr{Cvoid}, ::Type{I}) where {I} =
    Ptr{Csize_t}(ctx + fieldoffset(CallbackCtx{I}, 6))
@inline dropped_p(ctx::Ptr{Cvoid}, ::Type{I}) where {I} =
    Ptr{Csize_t}(ctx + fieldoffset(CallbackCtx{I}, 7))
@inline closing_p(ctx::Ptr{Cvoid}, ::Type{I}) where {I} =
    Ptr{UInt8}(ctx + fieldoffset(CallbackCtx{I}, 8))

# Address of ring slot `i` (0-based). Julia Ptr arithmetic is in bytes, so the
# element stride is explicit.
@inline slot_p(ring::Ptr{I}, i::Integer) where {I} = ring + i * sizeof(I)

# --- Foreign-thread trampoline bodies --------------------------------
#
# These run on libzenohc's I/O thread; restricted to ccalls and pointer
# arithmetic. The per-type trampoline (stamped by @closure_kind) is a thin
# wrapper that forwards here with the right type parameters and clone/drop fps.

@inline function call_body!(item_ptr::Ptr{Loaned}, ctx::Ptr{Cvoid},
        clone_fp::Ptr{Cvoid}, drop_fp::Ptr{Cvoid},
        ::Type{Owned}, ::Type{Moved}) where {Loaned, Owned, Moved}
    ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), ctx)
    if unsafe_load(closing_p(ctx, Owned)) != 0
        ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), ctx)
        return nothing
    end
    ring  = unsafe_load(ring_p(ctx, Owned))
    cap   = unsafe_load(cap_p(ctx, Owned))
    head  = unsafe_load(head_p(ctx, Owned))
    count = unsafe_load(count_p(ctx, Owned))
    if count == cap
        # Full → drop-oldest: drop the head slot the consumer never picked up,
        # advance head, and account the loss.
        ccall(drop_fp, Cvoid, (Ptr{Moved},), Ptr{Moved}(slot_p(ring, head)))
        head = (head + one(head)) % cap
        count -= one(count)
        unsafe_store!(head_p(ctx, Owned), head)
        unsafe_store!(dropped_p(ctx, Owned),
            unsafe_load(dropped_p(ctx, Owned)) + one(Csize_t))
    end
    tail = (head + count) % cap
    # Refcount bump into the tail slot — no malloc, no payload copy.
    ccall(clone_fp, Cvoid, (Ptr{Owned}, Ptr{Loaned}), slot_p(ring, tail), item_ptr)
    unsafe_store!(count_p(ctx, Owned), count + one(count))
    async = async_handle(ctx, Owned)
    ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), ctx)
    ccall(:uv_async_send, Cint, (Ptr{Cvoid},), async)
    return nothing
end

# POD variant: payload is a plain `z_<tag>_t` value (e.g. z_matching_status_t,
# ze_miss_t). No clone/drop fns, so the slot write is a byte copy and the ring
# is always capacity 1 — overwrite slot 0 in place (latest-wins); the prior
# occupant owns no resources, so no eviction is needed.
@inline function call_body_pod!(item_ptr::Ptr{Item}, ctx::Ptr{Cvoid},
        ::Type{Item}) where {Item}
    ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), ctx)
    if unsafe_load(closing_p(ctx, Item)) != 0
        ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), ctx)
        return nothing
    end
    unsafe_copyto!(unsafe_load(ring_p(ctx, Item)), item_ptr, 1)
    unsafe_store!(count_p(ctx, Item), one(Csize_t))
    async = async_handle(ctx, Item)
    ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), ctx)
    ccall(:uv_async_send, Cint, (Ptr{Cvoid},), async)
    return nothing
end

# Fires once libzenohc is done with the closure. Flag closing so any IO
# callback that hasn't yet acquired the cell bails, and wake the consumer so it
# sees the flag and exits. Item-type-agnostic — only touches the closing flag
# and async handle, both at fixed offsets.
@inline function drop_body!(ctx::Ptr{Cvoid}, ::Type{Item}) where {Item}
    ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), ctx)
    unsafe_store!(closing_p(ctx, Item), UInt8(1))
    ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), ctx)
    ccall(:uv_async_send, Cint, (Ptr{Cvoid},), async_handle(ctx, Item))
    return nothing
end

# --- Julia-side helpers ----------------------------------------------

function init_ctx!(ctx::CallbackCtx{Item}, async_cond::Base.AsyncCondition,
        capacity::Integer) where {Item}
    capacity ≥ 1 || throw(ArgumentError("capacity must be ≥ 1, got $capacity"))
    buf = Vector{Item}(undef, capacity)   # Julia-managed; data buffer is non-moving
    ctx.buf     = buf
    ctx.ring     = pointer(buf)           # cached once; valid while buf is reachable & unresized
    ctx.cap     = capacity
    ctx.head    = 0
    ctx.count   = 0
    ctx.dropped = 0
    ctx.closing = 0
    ctx.destroyed = false
    ctx.async   = Base.unsafe_convert(Ptr{Cvoid}, async_cond)
    rc = ccall(:uv_mutex_init, Cint, (Ptr{Cvoid},), ctx_p(ctx))
    rc == 0 || error("uv_mutex_init failed: $rc")
    return ctx
end

# Reset a ctx for reuse across gets WITHOUT reallocating — the per-call counterpart
# to `init_ctx!`. Zero head/count/dropped/closing under the mutex (so the foreign IO
# thread observes a consistent empty, not-closing ring); KEEP buf/ring/cap/async/mutex.
# Crucially this does NOT realloc `buf` and does NOT re-run `uv_mutex_init` (which on a
# live mutex is UB). The caller MUST have observed the prior get's `:closed` — i.e.
# libzenohc dropped that get's reply closure — before re-arming, so no in-flight foreign
# callback can race the reset; `ReusableGet.call!` guarantees this by draining to
# `:closed` before each re-arm. The drained ring's slots hold already-moved-out (stale)
# handles, never re-dropped here — the next clone overwrites them.
function rearm_ctx!(ctx::CallbackCtx{Item}) where {Item}
    cp = ctx_p(ctx)
    ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), cp)
    ctx.head    = 0
    ctx.count   = 0
    ctx.dropped = 0
    ctx.closing = 0
    ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), cp)
    return ctx
end

# Number of items the ring has dropped to overflow since declare (advisory:
# read without the mutex; aligned-word load, may lag the latest push).
dropped_count(ctx::CallbackCtx) = Int(ctx.dropped)

# Signal closing under the mutex so the IO trampoline observes the update
# atomically with its other cell reads, then wake the consumer.
function signal_closing!(ctx::CallbackCtx{Item},
        async_cond::Base.AsyncCondition) where {Item}
    cp = ctx_p(ctx)
    ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), cp)
    unsafe_store!(closing_p(cp, Item), UInt8(1))
    ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), cp)
    ccall(:uv_async_send, Cint, (Ptr{Cvoid},),
        Base.unsafe_convert(Ptr{Cvoid}, async_cond))
end

# Drop every still-occupied slot exactly once (cb fired after the consumer last
# drained but before it observed closing), then destroy the mutex; close the
# async condition when `close_async` (the explicit-close path — in the
# finalizer path the AsyncCondition's own finalizer handles it).
#
# PRECONDITION: the foreign side must be quiescent — no concurrent
# `call_body!`/`drop_body!`. The slot drain and `uv_mutex_destroy` run without
# the mutex, so a concurrent callback would re-lock a destroyed mutex (UB).
# Callers establish this by first observing `:closed`: the subscriber via
# `undeclare`, the one-shot get by draining to `:closed`, the channel get in
# `_drain_replies`.
function destroy_ctx!(ctx::CallbackCtx{Owned},
        async_cond::Base.AsyncCondition,
        drop_fp::Ptr{Cvoid}, ::Type{Moved};
        close_async::Bool=true) where {Owned, Moved}
    # Idempotent: a synchronous teardown (e.g. the precompile workload) and the deferred
    # finalizer/drain-task teardown can both target one ctx; only the first runs, so the
    # foreign-unsafe `uv_mutex_destroy` never double-fires. The two callers are never
    # concurrent (the finalizer runs after the explicit teardown, or in a later process),
    # so a plain flag suffices.
    ctx.destroyed && return
    ctx.destroyed = true
    GC.@preserve ctx begin
        while ctx.count > 0
            ccall(drop_fp, Cvoid, (Ptr{Moved},),
                Ptr{Moved}(pointer(ctx.buf, ctx.head + 1)))
            ctx.head  = (ctx.head + one(ctx.head)) % ctx.cap
            ctx.count -= one(ctx.count)
        end
    end
    ccall(:uv_mutex_destroy, Cvoid, (Ptr{Cvoid},), ctx_p(ctx))
    close_async && close(async_cond)
end

# POD variant: no owned remnants to free, so destroy is just mutex + async.
function destroy_ctx_pod!(ctx::CallbackCtx{Item},
        async_cond::Base.AsyncCondition;
        close_async::Bool=true) where {Item}
    ctx.destroyed && return                  # idempotent (see destroy_ctx!)
    ctx.destroyed = true
    ccall(:uv_mutex_destroy, Cvoid, (Ptr{Cvoid},), ctx_p(ctx))
    close_async && close(async_cond)
end

# --- Pull-form ring access (buffered handlers / channel get) ---------
#
# A bare pop under the lock, shared by the blocking `_ring_take` and the
# non-blocking `tryrecv!`. Returns the dequeued `Ref{Item}` (ownership moves
# out of the slot to the Ref's finalizer), or `:empty` / `:closed`.
@inline function _ring_pop!(ctx::CallbackCtx{Item}) where {Item}
    cp = ctx_p(ctx)
    ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), cp)
    if ctx.count > 0
        item = Ref(ctx.buf[ctx.head + 1])   # copy owned bits out; slot now stale
        ctx.head  = (ctx.head + one(ctx.head)) % ctx.cap
        ctx.count -= one(ctx.count)
        ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), cp)
        return item
    end
    closed = ctx.closing != 0
    ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), cp)
    return closed ? :closed : :empty
end

# Blocking pull: drain what's queued, only parking on the async condition when
# the ring is genuinely empty. Re-checking `count` under the lock before each
# `wait` makes this coalescing-safe (uv_async_send coalesces); the
# AsyncCondition `set` latch makes it lost-wakeup-safe. Returns the `Ref{Item}`
# or `nothing` (disconnected).
function _ring_take(ctx::CallbackCtx{Item}, async_cond::Base.AsyncCondition) where {Item}
    while true
        r = _ring_pop!(ctx)
        r isa Base.RefValue && return r
        r === :closed       && return nothing
        try
            wait(async_cond)
        catch
            return nothing                  # async_cond closed
        end
    end
end

# Block until the drop trampoline fires (`_ring_pop!` returns `:closed`),
# discarding any items that land meanwhile. Establishes the quiescence
# `destroy_ctx!` requires. Returns at once on the normal-completion path, where
# the first `_ring_pop!` already returns `:closed`.
#
# `wrap` (the kind's `Reply`/`Hello` constructor) drops the owned handle — the
# popped raw `Ref` carries no finalizer — so each item is wrapped and the
# wrapper discarded.
function _drain_to_closed!(wrap, ctx::CallbackCtx, async_cond::Base.AsyncCondition)
    while true
        r = _ring_pop!(ctx)
        r === :closed && return nothing
        if r === :empty
            try
                wait(async_cond)
            catch
                return nothing              # async_cond closed
            end
        else
            wrap(r)                         # drops the owned handle
        end
    end
end

# Non-blocking in-place pop: fills `box[]` and returns `true` if an item was
# queued, else `false` (caller drops `box`'s previous occupant first).
@inline function _ring_pop_into!(box::Base.RefValue{Item}, ctx::CallbackCtx{Item}) where {Item}
    cp = ctx_p(ctx)
    ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), cp)
    if ctx.count > 0
        box[] = ctx.buf[ctx.head + 1]
        ctx.head  = (ctx.head + one(ctx.head)) % ctx.cap
        ctx.count -= one(ctx.count)
        ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), cp)
        return true
    end
    ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), cp)
    return false
end

# Like `_ring_take`, but pops the next item INTO `box` in place — no per-item
# allocation. Returns `true` once `box[]` holds a freshly dequeued item, or
# `false` on disconnect. Used by the iterate path's reusable-box optimization
# (the caller drops `box`'s previous occupant before each call).
function _ring_take_into!(box::Base.RefValue{Item}, ctx::CallbackCtx{Item},
        async_cond::Base.AsyncCondition) where {Item}
    cp = ctx_p(ctx)
    while true
        ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), cp)
        if ctx.count > 0
            box[] = ctx.buf[ctx.head + 1]   # copy owned bits into the box; slot now stale
            ctx.head  = (ctx.head + one(ctx.head)) % ctx.cap
            ctx.count -= one(ctx.count)
            ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), cp)
            return true
        end
        closed = ctx.closing != 0
        ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), cp)
        closed && return false
        try
            wait(async_cond)
        catch
            return false                    # async_cond closed
        end
    end
end

# Consumer loop (push form). Drains the ring fully on each wake — uv_async_send
# coalesces, so a single wake may cover several pushes; re-checking `count`
# under the lock before parking keeps FIFO order instead of degrading to
# latest-wins. Yields each item — wrapped via `wrap(::Ref{Item})` into a
# user-facing value (Sample, Reply, Query, Bool, …) — to `f`. `DataType`
# doesn't subtype `Function`, so `wrap` is untyped.
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
        while true
            ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), cp)
            if ctx.count == 0
                closing = ctx.closing != 0
                ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), cp)
                closing && return
                break                       # ring drained → back to wait()
            end
            # memcpy the owned handle out of the slot into a local Ref; ownership
            # transfers to the Ref (its finalizer drops on GC). Advancing head /
            # count empties the slot for the next IO callback.
            local_item = Ref(ctx.buf[ctx.head + 1])
            ctx.head  = (ctx.head + one(ctx.head)) % ctx.cap
            ctx.count -= one(ctx.count)
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
        end
    end
end

# Module-level cfunction pointer registry. Each callback type
# (subscriber/get/…) appends its (call, drop) pair here and reads clone/drop
# function pointers via cglobal. Populated by `__init__`.
const _CB_INIT_HOOKS = Function[]
_register_init!(f::Function) = (push!(_CB_INIT_HOOKS, f); f)
