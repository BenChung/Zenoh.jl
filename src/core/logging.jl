# Logging — initialize Zenoh's Rust logger, and (opt-in) capture its log
# stream into Julia as a bounded, pull-based `LogStream`.
#
# Zenoh's only in-process capture hook is `zc_init_log_with_callback`, which
# installs a PROCESS-GLOBAL logger that Zenoh invokes from arbitrary internal
# Rust threads, potentially at high frequency. The Julia heap is off-limits
# from foreign threads (see core/callback.jl), so the callback trampoline does
# ccalls + raw pointer arithmetic only and hands records to a Julia consumer
# via `uv_async_send`. Delivery is a bounded ring (drop-oldest on overflow);
# the user pulls `LogRecord`s with `take!`/`tryrecv!`/`iterate` and routes them
# wherever they like (e.g. a ROS logging topic — see docs/logging.md).
#
# Loop safety (forwarding a log over Zenoh makes Zenoh log the publish →
# feedback): the callback exposes only (severity, message string) — no
# structured origin — so origin filtering is impossible. The defenses are the
# `min_severity` floor (set at init; below-floor records never reach the
# callback, so data-plane DEBUG/TRACE from a forwarding publish never loops)
# and the bounded drop-oldest ring (a real WARN/ERROR loop churns the buffer,
# never explodes). See docs/logging.md for the ROS-side contract.
#
# Zenoh log init is global, one-shot, and irreversible: `setup_logging` (stderr)
# and `open_log_stream` (capture) are mutually exclusive; first call wins.

# ── LogSeverity (mirrors the singleton-enum pattern in core/qos.jl) ──────

"""
    LogSeverities

Namespace holding the five log-severity levels as singleton instances:
`LogSeverities.TRACE`, `DEBUG`, `INFO`, `WARN`, and `ERROR`. Each is a distinct
singleton type under the shared [`LogSeverity`](@ref Zenoh.LogSeverity) supertype and maps 1:1 to
a `ZC_LOG_SEVERITY_*` value in the underlying C enum.

The levels order `TRACE < DEBUG < INFO < WARN < ERROR` (via `isless`/`<=`),
matching the C enum's `0..4` ranking. Pass a level to [`setup_logging`](@ref Zenoh.setup_logging) as
the stderr fallback or to [`open_log_stream`](@ref Zenoh.open_log_stream) as the capture floor.
"""
module LogSeverities
    import ..LibZenohC

    abstract type LogSeverity end

    struct Trace <: LogSeverity end
    struct Debug <: LogSeverity end
    struct Info  <: LogSeverity end
    struct Warn  <: LogSeverity end
    struct Error <: LogSeverity end

    const TRACE = Trace()
    const DEBUG = Debug()
    const INFO  = Info()
    const WARN  = Warn()
    const ERROR = Error()
end

"""
    LogSeverity

Abstract supertype of the five severity levels in [`LogSeverities`](@ref)
(`TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`). Accepted wherever a level is named:
the `filter` argument to [`setup_logging`](@ref), the `min_severity` floor of
[`open_log_stream`](@ref), and the `severity` field of a [`LogRecord`](@ref).

Levels are ordered `TRACE < DEBUG < INFO < WARN < ERROR` via `isless`/`<=`.
"""
const LogSeverity = LogSeverities.LogSeverity

_raw(::LogSeverities.Trace) = LibZenohC.ZC_LOG_SEVERITY_TRACE
_raw(::LogSeverities.Debug) = LibZenohC.ZC_LOG_SEVERITY_DEBUG
_raw(::LogSeverities.Info)  = LibZenohC.ZC_LOG_SEVERITY_INFO
_raw(::LogSeverities.Warn)  = LibZenohC.ZC_LOG_SEVERITY_WARN
_raw(::LogSeverities.Error) = LibZenohC.ZC_LOG_SEVERITY_ERROR

function _log_severity_from_raw(v::LibZenohC.zc_log_severity_t)
    v == LibZenohC.ZC_LOG_SEVERITY_TRACE && return LogSeverities.TRACE
    v == LibZenohC.ZC_LOG_SEVERITY_DEBUG && return LogSeverities.DEBUG
    v == LibZenohC.ZC_LOG_SEVERITY_INFO  && return LogSeverities.INFO
    v == LibZenohC.ZC_LOG_SEVERITY_WARN  && return LogSeverities.WARN
    v == LibZenohC.ZC_LOG_SEVERITY_ERROR && return LogSeverities.ERROR
    throw(ArgumentError("unknown zc_log_severity_t value: $v"))
end

Base.show(io::IO, ::LogSeverities.Trace) = print(io, "LogSeverities.TRACE")
Base.show(io::IO, ::LogSeverities.Debug) = print(io, "LogSeverities.DEBUG")
Base.show(io::IO, ::LogSeverities.Info)  = print(io, "LogSeverities.INFO")
Base.show(io::IO, ::LogSeverities.Warn)  = print(io, "LogSeverities.WARN")
Base.show(io::IO, ::LogSeverities.Error) = print(io, "LogSeverities.ERROR")

# Rank for Julia-side comparison / filtering (matches the C enum order).
_rank(s::LogSeverity) = Int(UInt32(_raw(s)))
Base.isless(a::LogSeverity, b::LogSeverity) = _rank(a) < _rank(b)
Base.:(<=)(a::LogSeverity, b::LogSeverity)  = _rank(a) <= _rank(b)

# Filter-string form for the stderr/env init path.
_filter_string(s::LogSeverities.Trace) = "trace"
_filter_string(s::LogSeverities.Debug) = "debug"
_filter_string(s::LogSeverities.Info)  = "info"
_filter_string(s::LogSeverities.Warn)  = "warn"
_filter_string(s::LogSeverities.Error) = "error"

"""
    LogRecord

One captured Zenoh log line: `severity::LogSeverity` and `message::String`.
"""
struct LogRecord
    severity::LogSeverity
    message::String
end
Base.show(io::IO, r::LogRecord) = print(io, "LogRecord(", r.severity, ", ", repr(r.message), ")")

# ── Foreign-thread bridge: a bounded ring filled by the log trampoline ───
#
# `mutex` sits at offset 0 so the ctx pointer *is* the `uv_mutex_t*` (same
# trick as CallbackCtx). The trampoline only touches the isbits fields
# (indices 2–8) via fixed `fieldoffset`s; the heap-ref fields (9–12) are GC
# roots it never reads.

struct _LogEntry
    severity::UInt32
    ptr::Ptr{UInt8}     # Libc.malloc'd copy of the message bytes; consumer frees
    len::Csize_t
end

mutable struct _LogBridge
    mutex::NTuple{128, UInt8}                 # 1 — uv_mutex_t storage (offset 0)
    head::Int                                 # 2 — total pushed
    tail::Int                                 # 3 — total consumed
    dropped::UInt64                           # 4 — overflow drops (drop-oldest)
    capacity::Int                             # 5
    async::Ptr{Cvoid}                         # 6 — uv_async_t* from AsyncCondition
    entries_ptr::Ptr{_LogEntry}               # 7 — raw data ptr of `entries`
    closing::UInt8                            # 8
    entries::Memory{_LogEntry}                # 9 — GC root for the ring buffer
    async_cond::Base.AsyncCondition           # 10 — GC root
    closure::Base.RefValue{LibZenohC.zc_owned_closure_log_t}  # 11 — GC root
    min_severity::UInt32                      # 12 — informational (Zenoh-side floor)
    _LogBridge() = new()
end

@assert fieldoffset(_LogBridge, 1) == 0

@inline _bridge_ctx(b::_LogBridge) = Ptr{Cvoid}(pointer_from_objref(b))
@inline _head_p(ctx::Ptr{Cvoid})    = Ptr{Int}(ctx + fieldoffset(_LogBridge, 2))
@inline _tail_p(ctx::Ptr{Cvoid})    = Ptr{Int}(ctx + fieldoffset(_LogBridge, 3))
@inline _dropped_p(ctx::Ptr{Cvoid}) = Ptr{UInt64}(ctx + fieldoffset(_LogBridge, 4))
@inline _cap_p(ctx::Ptr{Cvoid})     = Ptr{Int}(ctx + fieldoffset(_LogBridge, 5))
@inline _async_p(ctx::Ptr{Cvoid})   = Ptr{Ptr{Cvoid}}(ctx + fieldoffset(_LogBridge, 6))
@inline _entries_p(ctx::Ptr{Cvoid}) = Ptr{Ptr{_LogEntry}}(ctx + fieldoffset(_LogBridge, 7))
@inline _closing_p(ctx::Ptr{Cvoid}) = Ptr{UInt8}(ctx + fieldoffset(_LogBridge, 8))

# Foreign-thread call trampoline. ccalls + pointer ops ONLY — no Julia heap.
function _log_call_tramp(severity::LibZenohC.zc_log_severity_t,
                         msg::Ptr{LibZenohC.z_loaned_string_t}, ctx::Ptr{Cvoid})
    ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), ctx)
    if unsafe_load(_closing_p(ctx)) != 0
        ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), ctx)
        return nothing
    end
    cap  = unsafe_load(_cap_p(ctx))
    eptr = unsafe_load(_entries_p(ctx))
    head = unsafe_load(_head_p(ctx))
    tail = unsafe_load(_tail_p(ctx))
    # Drop-oldest if the ring is full: free the evicted message, advance tail.
    if head - tail >= cap
        old = unsafe_load(eptr, (tail % cap) + 1)
        ccall(:free, Cvoid, (Ptr{Cvoid},), old.ptr)
        unsafe_store!(_tail_p(ctx), tail + 1)
        unsafe_store!(_dropped_p(ctx), unsafe_load(_dropped_p(ctx)) + UInt64(1))
    end
    # Copy the message bytes into a libc buffer (the consumer frees it).
    n  = LibZenohC.z_string_len(msg)
    dp = LibZenohC.z_string_data(msg)
    p  = Ptr{UInt8}(n == 0 ? C_NULL : ccall(:malloc, Ptr{Cvoid}, (Csize_t,), n))
    if n != 0 && p == C_NULL
        # malloc failed: drop this record. Head stays put, so the slot is free
        # for the next push.
        ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), ctx)
        return nothing
    end
    n == 0 || ccall(:memcpy, Ptr{Cvoid}, (Ptr{UInt8}, Ptr{UInt8}, Csize_t), p, dp, n)
    unsafe_store!(eptr, _LogEntry(UInt32(severity), p, n), (head % cap) + 1)
    unsafe_store!(_head_p(ctx), head + 1)
    async = unsafe_load(_async_p(ctx))
    ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), ctx)
    ccall(:uv_async_send, Cint, (Ptr{Cvoid},), async)
    return nothing
end

# Fires if Zenoh ever drops the logger (it won't — global for process life).
function _log_drop_tramp(ctx::Ptr{Cvoid})
    ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), ctx)
    unsafe_store!(_closing_p(ctx), UInt8(1))
    ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), ctx)
    return nothing
end

const _LOG_CALL_CFN = Ref{Ptr{Cvoid}}(C_NULL)
const _LOG_DROP_CFN = Ref{Ptr{Cvoid}}(C_NULL)

# @cfunction addresses must be built at runtime (not baked into the precompile
# image) — registered here, fired from __init__ via the shared hook list.
_register_init!() do
    _LOG_CALL_CFN[] = @cfunction(_log_call_tramp, Cvoid,
        (LibZenohC.zc_log_severity_t, Ptr{LibZenohC.z_loaned_string_t}, Ptr{Cvoid}))
    _LOG_DROP_CFN[] = @cfunction(_log_drop_tramp, Cvoid, (Ptr{Cvoid},))
end

# ── Global one-shot init guard ───────────────────────────────────────────

# Zenoh's log init is process-global and irreversible. Track whether *any*
# init has happened so the stderr and capture paths can't collide. `_LOG_LOCK`
# makes check-and-init atomic, so racing initializers can't both pass the guard
# and double-init the global logger.
const _LOG_LOCK = ReentrantLock()
const _LOG_INITED = Ref{Bool}(false)
const _LOG_BRIDGE = Ref{Union{Nothing, _LogBridge}}(nothing)

# Call while holding `_LOG_LOCK`. Throws if any init already ran.
_check_not_inited() = _LOG_INITED[] &&
    error("Zenoh logging is already initialized (it is global and one-shot); " *
          "`setup_logging` and `open_log_stream` are mutually exclusive and may only be called once")

# ── stderr / env init (Tier A) ──────────────────────────────────────────

"""
    setup_logging(filter="info")

Initialize Zenoh's built-in logger writing to **stderr**, with `filter` as the
fallback level/spec (overridden by the `RUST_LOG`/`ZENOH_LOG` env vars). `filter`
may be a level string (`"info"`, `"debug"`, …) or a [`LogSeverity`](@ref).

Global and one-shot — mutually exclusive with [`open_log_stream`](@ref).
"""
function setup_logging(filter::Union{AbstractString, LogSeverity} = "info")
    f = filter isa LogSeverity ? _filter_string(filter) : String(filter)
    @lock _LOG_LOCK begin
        _check_not_inited()
        GC.@preserve f _handle_result(LibZenohC.zc_init_log_from_env_or(
            pointer(Base.unsafe_convert(Cstring, f))))
        _LOG_INITED[] = true
    end
    return nothing
end

"""
    try_init_logging_from_env()

Initialize Zenoh's stderr logger from the `RUST_LOG`/`ZENOH_LOG` env vars only
(no fallback); a no-op if they're unset. Global and one-shot.
"""
function try_init_logging_from_env()
    @lock _LOG_LOCK begin
        _check_not_inited()
        LibZenohC.zc_try_init_log_from_env()
        _LOG_INITED[] = true
    end
    return nothing
end

# ── LogStream (Tier B): bounded, pull-based capture ──────────────────────

"""
    LogStream

A bounded, pull-based view of Zenoh's log stream, returned by
[`open_log_stream`](@ref). Consume `LogRecord`s with `take!` (blocking),
`tryrecv!` (non-blocking), or by iterating; call `close` when done.

Records arrive from Zenoh's internal threads into a fixed-capacity ring;
overflow drops the oldest (count via [`dropped_count`](@ref)). Because Zenoh's
logger is global and one-shot, only one `LogStream` exists per process. `close`
stops delivery and frees buffered records, but cannot uninstall the global logger.
"""
mutable struct LogStream
    bridge::_LogBridge
    @atomic closed::Bool
end

"""
    open_log_stream(; min_severity=LogSeverities.WARN, capacity=256) -> LogStream

Capture Zenoh's logs (at `min_severity` and above) into a bounded
[`LogStream`](@ref). Opt-in: nothing is installed until this is called.

`min_severity` is enforced **inside Zenoh** — below-floor records never reach
the callback. Keep it at `WARN` (the default) when forwarding logs back over
Zenoh (e.g. to ROS): the data-plane `DEBUG`/`TRACE` logs a forwarding publish
generates then never enter the stream, which is the primary defense against a
log feedback loop (see docs/logging.md). Global and one-shot — mutually
exclusive with [`setup_logging`](@ref).
"""
function open_log_stream(; min_severity::LogSeverity = LogSeverities.WARN,
                           capacity::Integer = 256)
    capacity >= 1 || throw(ArgumentError("capacity must be ≥ 1"))

    b = _LogBridge()
    b.head = 0; b.tail = 0; b.dropped = UInt64(0)
    b.capacity = Int(capacity)
    b.closing = 0
    b.min_severity = UInt32(_raw(min_severity))
    b.entries = Memory{_LogEntry}(undef, Int(capacity))
    b.entries_ptr = pointer(b.entries)
    b.async_cond = Base.AsyncCondition()
    b.async = Base.unsafe_convert(Ptr{Cvoid}, b.async_cond)
    rc = ccall(:uv_mutex_init, Cint, (Ptr{Cvoid},), _bridge_ctx(b))
    rc == 0 || error("uv_mutex_init failed: $rc")
    b.closure = Ref{LibZenohC.zc_owned_closure_log_t}()

    @lock _LOG_LOCK begin
        _check_not_inited()
        # Install the closure, then hand it to Zenoh's global logger init.
        LibZenohC.zc_closure_log(b.closure, _LOG_CALL_CFN[], _LOG_DROP_CFN[], _bridge_ctx(b))
        GC.@preserve b LibZenohC.zc_init_log_with_callback(
            _raw(min_severity), _move(b.closure))
        _LOG_BRIDGE[] = b   # root for process life — Zenoh holds the ctx pointer
        _LOG_INITED[] = true
    end
    return LogStream(b, false)
end

# Pop one buffered entry under the lock; returns a LogRecord or nothing.
function _log_pop(b::_LogBridge)
    ctx = _bridge_ctx(b)
    ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), ctx)
    head = unsafe_load(_head_p(ctx)); tail = unsafe_load(_tail_p(ctx))
    if tail >= head
        ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), ctx)
        return nothing
    end
    cap  = unsafe_load(_cap_p(ctx))
    eptr = unsafe_load(_entries_p(ctx))
    e    = unsafe_load(eptr, (tail % cap) + 1)
    unsafe_store!(_tail_p(ctx), tail + 1)
    ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), ctx)
    # Build the record off-lock, then free the libc copy.
    msg = e.len == 0 ? "" : unsafe_string(e.ptr, e.len)
    e.ptr == C_NULL || ccall(:free, Cvoid, (Ptr{Cvoid},), e.ptr)
    return LogRecord(_log_severity_from_raw(LibZenohC.zc_log_severity_t(e.severity)), msg)
end

"""
    tryrecv!(s::LogStream) -> Union{LogRecord, Nothing}

Pop the next buffered `LogRecord`, or `nothing` if none is waiting. Never blocks.
"""
function tryrecv!(s::LogStream)
    (@atomic s.closed) && return nothing
    return _log_pop(s.bridge)
end

"""
    take!(s::LogStream) -> LogRecord

Block until the next `LogRecord` is available and return it; throws if the stream
is closed while waiting.
"""
function Base.take!(s::LogStream)
    while true
        r = tryrecv!(s)
        r === nothing || return r
        (@atomic s.closed) && throw(InvalidStateException("LogStream is closed", :closed))
        try
            wait(s.bridge.async_cond)
        catch e
            e isa EOFError || rethrow()   # only a closed AsyncCondition means "closed"
            throw(InvalidStateException("LogStream is closed", :closed))
        end
    end
end

# Iteration yields records until the stream closes. Only the stream-closed
# signal ends it; anything else (notably InterruptException) propagates.
function Base.iterate(s::LogStream, ::Nothing=nothing)
    try
        return (take!(s), nothing)
    catch e
        e isa InvalidStateException && e.state === :closed && return nothing
        rethrow()
    end
end
Base.IteratorSize(::Type{LogStream}) = Base.SizeUnknown()
Base.eltype(::Type{LogStream}) = LogRecord

"""
    dropped_count(s::LogStream) -> Int

Cumulative number of log records dropped because the ring was full.
"""
function dropped_count(s::LogStream)
    ctx = _bridge_ctx(s.bridge)
    ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), ctx)
    d = unsafe_load(_dropped_p(ctx))
    ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), ctx)
    return Int(d)
end

"""
    close(s::LogStream)

Stop delivery and free buffered records. Note: Zenoh's logger is global and
cannot be uninstalled, so logging stays "initialized" for the process — a new
[`open_log_stream`](@ref) will error.
"""
function Base.close(s::LogStream)
    (@atomicswap s.closed = true) && return nothing
    b = s.bridge
    ctx = _bridge_ctx(b)
    ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), ctx)
    unsafe_store!(_closing_p(ctx), UInt8(1))
    # Drain + free any buffered messages so they don't leak.
    head = unsafe_load(_head_p(ctx)); tail = unsafe_load(_tail_p(ctx))
    cap  = unsafe_load(_cap_p(ctx)); eptr = unsafe_load(_entries_p(ctx))
    while tail < head
        e = unsafe_load(eptr, (tail % cap) + 1)
        e.ptr == C_NULL || ccall(:free, Cvoid, (Ptr{Cvoid},), e.ptr)
        tail += 1
    end
    unsafe_store!(_tail_p(ctx), head)
    async = unsafe_load(_async_p(ctx))
    ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), ctx)
    # Do NOT close(b.async_cond): the global Zenoh logger is never uninstalled,
    # so a foreign trampoline can be mid-`uv_async_send`; closing would free the
    # uv handle under that in-flight sender (libuv UB). The handle lives for
    # process life (`b` is rooted in `_LOG_BRIDGE`). This send wakes any parked
    # `take!` to observe the close and exit; records committed after `closing`
    # is set bail before touching the ring, so nothing leaks.
    ccall(:uv_async_send, Cint, (Ptr{Cvoid},), async)
    return nothing
end

export LogSeverity, LogSeverities, LogRecord, LogStream,
    open_log_stream, tryrecv!, dropped_count,
    setup_logging, try_init_logging_from_env
