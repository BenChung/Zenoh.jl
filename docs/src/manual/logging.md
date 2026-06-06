```@meta
CurrentModule = Zenoh
```

# Logging

Zenoh runs its own Rust logger over the [`tracing`](https://docs.rs/tracing) crate. `Zenoh.jl` gives you two ways to consume it. Tier A initializes the built-in **stderr** subscriber from a fallback level plus the `RUST_LOG`/`ZENOH_LOG` environment variables — the standard way to watch what a session is doing. Tier B installs an in-process callback that captures the log stream into Julia as a bounded, pull-based [`LogStream`](@ref) of [`LogRecord`](@ref)s; route them wherever you like, such as onto a ROS logging topic for unified remote debugging.

Logging is an observability concern of the implementation, so this page documents wrapper and runtime behavior. (It is the one page here with no entry in [Zenoh's abstractions](https://zenoh.io/docs/manual/abstractions/).) Zenoh's log initialization is process-global, one-shot, and irreversible: the two tiers are **mutually exclusive**, the first call wins, and a second call throws.

## Tier A — stderr / environment

[`setup_logging`](@ref) installs Zenoh's stderr subscriber with a fallback filter, used when neither `RUST_LOG` nor `ZENOH_LOG` is set. The fallback is a level string (`"info"`, `"debug"`, …, following [`tracing`'s `EnvFilter` syntax](https://docs.rs/tracing-subscriber/latest/tracing_subscriber/filter/struct.EnvFilter.html)) or a [`LogSeverity`](@ref).

```julia
using Zenoh

Zenoh.setup_logging()                            # fallback "info", overridable by RUST_LOG / ZENOH_LOG
Zenoh.setup_logging("debug")                     # or any tracing filter string
Zenoh.setup_logging(Zenoh.LogSeverities.WARN)    # or a LogSeverity
```

[`try_init_logging_from_env`](@ref) installs the same stderr subscriber purely from `RUST_LOG`/`ZENOH_LOG`, with no fallback, and is a no-op when both are unset — the right choice when logging should stay silent until an operator opts in via the environment.

```julia
Zenoh.try_init_logging_from_env()   # env-only; silent if RUST_LOG / ZENOH_LOG are unset
```

Both are global and one-shot; choose this path or Tier B at startup.

## Tier B — capture into Julia

[`open_log_stream`](@ref) installs Zenoh's in-process log callback and captures every record at `min_severity` and above into a fixed-capacity ring, returned as a [`LogStream`](@ref). Capture is opt-in: nothing is installed until you call it.

```julia
using Zenoh

ls = Zenoh.open_log_stream(; min_severity = Zenoh.LogSeverities.WARN, capacity = 256)
```

`min_severity` is enforced **inside Zenoh**: below-floor records are never delivered to Julia. The floor is therefore free and is the primary feedback-loop defense (see [Feedback loops when forwarding logs](@ref)). `capacity` bounds the ring; when the consumer falls behind, the **oldest** records are dropped and counted by [`dropped_count`](@ref). Memory stays bounded.

A [`LogStream`](@ref) yields [`LogRecord`](@ref)s, the exact `(severity, message)` pair Zenoh passes to the callback. Consume them by iterating (blocks per record), with `take!` (blocking), or with [`tryrecv!`](@ref) (non-blocking); call `close` when done.

```julia
# Drain promptly on a task so the ring does not overflow.
consumer = @async for rec in ls            # iterate blocks for each record
    println(rec.severity, ": ", rec.message)   # rec.severity::LogSeverity, rec.message::String
end

# Non-blocking poll:
rec = Zenoh.tryrecv!(ls)            # a LogRecord, or nothing if the ring is empty or the stream is closed
rec === nothing || handle(rec.severity, rec.message)

# Blocking pull of a single record:
rec = take!(ls)                     # blocks until a record arrives; throws if closed while waiting

@info "dropped so far" Zenoh.dropped_count(ls)

close(ls)   # stop delivery and free buffered records; the logger stays installed for the process
```

`take!`, `close`, and `iterate` are `Base` methods specialized on [`LogStream`](@ref), used as shown above; the Zenoh.jl exports are [`open_log_stream`](@ref), [`tryrecv!`](@ref), and [`dropped_count`](@ref).

### Lifecycle

Because Zenoh's logger is process-global and one-shot, exactly one [`LogStream`](@ref) exists per process. `close` stops delivery and frees buffered records, but **cannot** uninstall Zenoh's logger. Logging stays initialized for the process, so a later [`open_log_stream`](@ref) (or [`setup_logging`](@ref)) still throws.

!!! warning "Decide at startup"
    Choose between Tier A (`setup_logging` / `try_init_logging_from_env`) and Tier B (`open_log_stream`) when the process starts. The first call wins; the second throws; `close` does not re-enable a fresh `open_log_stream`.

## Severities

Severities are singleton values under the [`LogSeverities`](@ref) module, ordered `TRACE < DEBUG < INFO < WARN < ERROR`; `Base.isless` and `<=` compare them directly.

| `LogSeverity`           |
|-------------------------|
| `LogSeverities.TRACE`   |
| `LogSeverities.DEBUG`   |
| `LogSeverities.INFO`    |
| `LogSeverities.WARN`    |
| `LogSeverities.ERROR`   |

The exported abstract supertype [`LogSeverity`](@ref) is the accepted argument type for [`setup_logging`](@ref) and `min_severity` in [`open_log_stream`](@ref), and the field type of [`LogRecord`](@ref)`.severity`.

## Feedback loops when forwarding logs

Forwarding a captured log back over Zenoh (for example, republishing it onto a ROS logging topic) makes Zenoh log that publish, which could be captured and forwarded again. The callback delivers only `(severity, message)`, with no structured origin: the wrapper cannot tell a log caused by its own forwarding publish from any other. Loop prevention rests on two mechanisms and belongs to the integrator:

1. **Open the stream at `WARN` or higher.** A forwarding publish's own logs are data-plane `DEBUG`/`TRACE`; a `WARN` floor enforced inside Zenoh keeps them out of the stream entirely, so steady-state forwarding cannot feed itself.
2. **Rely on the bounded drop-oldest ring as the backstop.** A genuine `WARN`/`ERROR` that does loop churns the ring and bumps [`dropped_count`](@ref) — a diagnosable storm of one repeated message, with memory still bounded.

One self-sustaining `ERROR` loop the floor cannot stop: a record that reports a failure of the logging transport itself, republished onto that same transport. Guard against it by dropping records whose text matches the logging endpoint, or by forwarding logs over a dedicated session you never log-forward about. Surface [`dropped_count`](@ref) as a health metric — nonzero means the consumer or the forwarding path cannot keep up, or a loop is churning the ring.

## API

```@docs
LogSeverity
LogSeverities
LogRecord
LogStream
setup_logging
try_init_logging_from_env
open_log_stream
tryrecv!(::Zenoh.LogStream)
dropped_count
```

## Mapping to Zenoh, Rust, and C

The zenoh-c documentation renders as one long single-file page; follow a C-symbol link, then in-page search for the `zc_` name to reach its definition.

| Zenoh.jl | Zenoh abstraction | Rust | zenoh-c |
|----------|-------------------|------|---------|
| [`setup_logging`](@ref) | — (operational, not an abstraction) | [`zenoh::init_log_from_env_or`](https://docs.rs/zenoh/1.9.0/zenoh/fn.init_log_from_env_or.html) | [`zc_init_log_from_env_or`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [`try_init_logging_from_env`](@ref) | — | [`zenoh::try_init_log_from_env`](https://docs.rs/zenoh/1.9.0/zenoh/fn.try_init_log_from_env.html) | [`zc_try_init_log_from_env`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [`open_log_stream`](@ref) | — | (no safe-Rust equivalent) | [`zc_init_log_with_callback`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) + [`zc_closure_log`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [`LogSeverity`](@ref) / [`LogSeverities`](@ref) | — | (none; enum) | [`zc_log_severity_t`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) |
| [`LogRecord`](@ref) | — | (callback args) | [`zc_closure_log_call`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) args `(severity, msg)` |
| [`LogStream`](@ref) / [`tryrecv!`](@ref) / [`dropped_count`](@ref) / `take!` / `close` | — | (no Zenoh API) | (no Zenoh API) |

[`setup_logging`](@ref) calls `zc_init_log_from_env_or`, the C wrapper over Rust [`zenoh::init_log_from_env_or`](https://docs.rs/zenoh/1.9.0/zenoh/fn.init_log_from_env_or.html), installing the `tracing` stderr subscriber with the supplied filter as the fallback when `RUST_LOG`/`ZENOH_LOG` is unset. [`try_init_logging_from_env`](@ref) calls `zc_try_init_log_from_env` ([`zenoh::try_init_log_from_env`](https://docs.rs/zenoh/1.9.0/zenoh/fn.try_init_log_from_env.html)), installing it only when the environment variable is set. The [`LogSeverities`](@ref) constants map 1:1 onto `zc_log_severity_t` enumerators, and the Julia `isless` ordering reproduces the C enum's `0..4` order. A [`LogRecord`](@ref) materializes the `(severity, message)` pair Zenoh passes to the log closure.

`setup_logging` is the Zenoh.jl name for `init_log_from_env_or`; `try_init_logging_from_env` corresponds to `try_init_log_from_env`. Severities are singleton structs under [`LogSeverities`](@ref), matching the [Quality of Service](@ref) pattern.

!!! note "Not core Zenoh"
    Logging is absent from [Zenoh's abstractions](https://zenoh.io/docs/manual/abstractions/) (Key, Key Expression, Selector, Value, Encoding, Timestamp, Subscriber, Publisher, Queryable, Storage, Admin space).

!!! warning "Capture is a zenoh-c extension with no safe-Rust equivalent"
    The documented Rust API exposes only `init_log_from_env_or` and `try_init_log_from_env` (stderr via `tracing`). There is no safe-Rust counterpart to [`zc_init_log_with_callback`](https://zenoh-c.readthedocs.io/en/1.9.0/api.html); programmatic in-process log capture is a [zenoh-c](https://zenoh-c.readthedocs.io/en/1.9.0/api.html) (`zc_`) extension. [`open_log_stream`](@ref) wraps that C-only capability.

!!! note "Zenoh.jl extension: buffering, backpressure, and the pull API"
    Zenoh's callback is fire-and-forget from foreign threads. The fixed-capacity drop-oldest ring, the [`tryrecv!`](@ref) / `take!` / iteration / [`dropped_count`](@ref) / `close` surface, and the global one-shot mutual-exclusion guard are all Zenoh.jl machinery built on top of Zenoh's bare callback.

See also [Sessions & Configuration](@ref) for opening the session whose activity these logs report, and [Quality of Service](@ref) for the singleton-enum pattern the severities follow.
