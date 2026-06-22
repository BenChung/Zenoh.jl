# CompletionCell — a minimal foreign-thread completion signal for the send/lend path, built to be
# the `lent_bytes` deleter's `ctx`. It mirrors `CallbackCtx`'s discipline (callback.jl) minus the
# ring: a `done` byte the deleter flips and a cached `uv_async_t*` it pokes, both at FIXED OFFSETS
# read straight off the raw ctx pointer — so the deleter is PURE ccalls (no `unsafe_pointer_to_objref`,
# no Julia-heap touch on libzenoh's thread). The owning Julia task arms the cell before lending,
# then `wait`s on it (or polls `isdone`) and does ALL heap work — buffer/handle reclaim, pool
# return — after the wake.
#
# Correctness: the deleter does `done = 1` then `uv_async_send`; the woken `wait` carries the
# happens-before (libuv synchronises the send with the wake), so a waiter that returns sees `done == 1`
# and whatever buffer state the deleter implies. `isdone` is an advisory plain read for a non-blocking
# poll — for the reclaim decision, use `wait`.
#
# The caller MUST keep the cell GC-rooted until the deleter has fired: its raw pointer is handed to
# libzenoh as the deleter ctx, and a collected cell makes that pointer dangle.

"""
    CompletionCell()

A reusable completion signal that tells the lending task when zenoh has released a
[`lent_bytes`](@ref) buffer (transmission complete). Supply [`completion_deleter`](@ref) and
[`completion_ctx`](@ref) as that buffer's `on_release` and `ctx`, and the lend's deleter targets
this cell.

Each send follows three steps:

1. `arm!` the cell, then build the lend and send it.
2. `wait(cell)` blocks until zenoh's deleter fires on one of its runtime threads.
3. Reclaim or reuse the buffer — the wake carries the happens-before, so the bytes are safe to touch.

`isdone(cell)` polls the same state without blocking. Keep the cell GC-rooted until its deleter has
fired: its raw pointer lives inside zenoh, and a collected cell makes that pointer dangle. `close` the
cell once no deleter can still fire for it.
"""
mutable struct CompletionCell
    async::Ptr{Cvoid}            # field 1 (offset 0) — uv_async_t*; read by the foreign deleter
    done::UInt8                  # field 2 — 0 armed / 1 done; written by the foreign deleter
    cond::Base.AsyncCondition    # field 3 — GC owner of the async handle (keeps `async` valid)
    function CompletionCell()
        cond = Base.AsyncCondition()
        # Start "done" (= not armed): waiting on a never-lent cell returns immediately.
        return new(Base.unsafe_convert(Ptr{Cvoid}, cond), UInt8(1), cond)
    end
end
@assert fieldoffset(CompletionCell, 1) == 0

@inline _cell_done_p(ctx::Ptr{Cvoid}) = Ptr{UInt8}(ctx + fieldoffset(CompletionCell, 2))
@inline _cell_async(ctx::Ptr{Cvoid})  = unsafe_load(Ptr{Ptr{Cvoid}}(ctx + fieldoffset(CompletionCell, 1)))

# The two-arg `z_bytes_from_buf` deleter (runs on libzenoh's thread): mark done + wake the owner.
# ccalls / pointer arithmetic only. Returns a value (matching `_release`); the C side ignores it.
function _completion_release(::Ptr{Cvoid}, ctx::Ptr{Cvoid})
    unsafe_store!(_cell_done_p(ctx), UInt8(1))
    ccall(:uv_async_send, Cint, (Ptr{Cvoid},), _cell_async(ctx))
    return C_NULL
end

# @cfunction must be built in __init__ (a top-level one bakes a JIT address into the precompile
# image, invalid on reload — same rule as closure_kinds.jl).
const _COMPLETION_RELEASE_CFN = Ref{Ptr{Cvoid}}(C_NULL)
_register_init!() do
    _COMPLETION_RELEASE_CFN[] = @cfunction(_completion_release, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}))
end

"""
    completion_deleter() -> Ptr{Cvoid}

The `@cfunction` deleter pointer for [`CompletionCell`](@ref), to pass as `lent_bytes`'
`on_release`. Pair with [`completion_ctx`](@ref).
"""
completion_deleter() = _COMPLETION_RELEASE_CFN[]

"""
    completion_ctx(c::CompletionCell) -> Ptr{Cvoid}

The raw ctx pointer for `c`, to pass as `lent_bytes`' `ctx`. The caller MUST keep `c` GC-rooted
until the deleter fires — the pointer dangles otherwise.
"""
completion_ctx(c::CompletionCell) = pointer_from_objref(c)

"""
    arm!(c::CompletionCell)

Reset `c` to the not-done state before lending (reuse across sends). Must happen-before the lend.
"""
arm!(c::CompletionCell) = (c.done = UInt8(0); nothing)

"""
    isdone(c::CompletionCell) -> Bool

`true` once the deleter has fired — advisory, non-blocking poll. For the reclaim decision use
[`wait`](@ref).
"""
isdone(c::CompletionCell) = c.done != 0

"""
    wait(c::CompletionCell)

Block until `c`'s deleter has fired (transmission complete). The wake carries the happens-before,
so after this returns the lent buffer is safe to reuse or free.
"""
function Base.wait(c::CompletionCell)
    while c.done == 0
        try
            Base.wait(c.cond)
        catch
            break                       # cond closed (teardown)
        end
    end
    return nothing
end

"""
    close(c::CompletionCell)

Close the underlying `AsyncCondition`. Call only once no deleter can still fire for `c`.
"""
Base.close(c::CompletionCell) = (close(c.cond); nothing)

export CompletionCell, completion_deleter, completion_ctx
