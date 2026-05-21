# Per-testset wall-clock timeout. The libzenohc bindings have produced
# deadlocks more than once (struct-padding clobbers, callback ordering,
# `@threadcall` ping-pong); without a watchdog those manifest as an
# indefinite hang in `Pkg.test()`. This file adds `@timed_testset` which
# spawns a watchdog task per testset, dumps every live task's backtrace
# on timeout, and hard-exits with status 124 so CI / a local terminal
# notices.

const DEFAULT_TESTSET_TIMEOUT_S = 10.0

# Walks Julia's scheduler and prints a backtrace for every task. Uses
# the same C entrypoint as the SIGABRT handler. Falls back to a notice
# if the symbol isn't available in this Julia build.
function _dump_all_task_backtraces(io::IO=stderr)
    try
        ccall(:jl_print_task_backtraces, Cvoid, (Cint,), Cint(0))
    catch e
        println(io, "(could not dump task backtraces: ", e, ")")
    end
end

# Watchdog loop. Polls every 0.2s so we don't have to wait the full
# timeout when the testset finishes early. `done` is flipped by the
# caller's `finally`. Sleep yields to the scheduler, so this works
# under JULIA_NUM_THREADS=1 too (no real OS thread needed).
function _watchdog_loop(name::AbstractString, timeout::Real,
        done::Threads.Atomic{Int})
    elapsed = 0.0
    while elapsed < timeout
        sleep(0.2)
        done[] != 0 && return
        elapsed += 0.2
    end
    println(stderr)
    println(stderr, "="^72)
    println(stderr, "!!! TIMEOUT: testset $(repr(name)) exceeded $(timeout)s")
    println(stderr, "="^72)
    flush(stderr)
    _dump_all_task_backtraces(stderr)
    flush(stderr)
    # Skip Julia cleanup — finalizers may be exactly what's stuck.
    ccall(:exit, Cvoid, (Cint,), Cint(124))
end

function with_test_timeout(name::AbstractString, timeout::Real, body::Function)
    done = Threads.Atomic{Int}(0)
    Threads.@spawn _watchdog_loop(name, timeout, done)
    try
        body()
    finally
        Threads.atomic_xchg!(done, 1)
    end
end

"""
    @timed_testset name [timeout=N] begin … end

A `@testset` with a per-testset wall-clock watchdog. If the body
doesn't finish within `timeout` seconds (default $(DEFAULT_TESTSET_TIMEOUT_S)s),
prints all live task backtraces to stderr and exits with status 124
(skipping Julia cleanup so a stuck finalizer can't swallow the
diagnostic).
"""
macro timed_testset(args...)
    isempty(args) && throw(ArgumentError("@timed_testset needs a name and a body"))
    body = args[end]
    name = args[1]
    timeout = DEFAULT_TESTSET_TIMEOUT_S
    for arg in args[2:end-1]
        Meta.isexpr(arg, :(=)) && arg.args[1] === :timeout || continue
        timeout = arg.args[2]
    end
    return esc(quote
        $with_test_timeout($name, $timeout) do
            @testset $name $body
        end
    end)
end
