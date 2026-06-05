# A GC-safe variant of `Base.@threadcall`.
#
# Why this exists. `Base.@threadcall` runs a blocking C call on a libuv threadpool
# thread by wrapping it in a `@cfunction` and dispatching it with `jl_queue_work`.
# Executing a cfunction *adopts that worker thread into the Julia runtime* — it gets
# a ptls and becomes GC-tracked — and Base's generated wrapper runs the inner
# `ccall` in GC-*unsafe* state (threadcall.jl). So while the worker is parked in a
# long blocking call (e.g. a Zenoh FIFO/ring `recv` waiting for the next sample), it
# is a GC-tracked thread that never reaches a safepoint. A stop-the-world GC on any
# *other* thread (e.g. triggered by JIT/codegen during live traffic) then blocks in
# `jl_gc_wait_for_the_world` waiting for that parked worker forever — a hard deadlock.
#
# `@gc_safe_threadcall` is identical to `Base.@threadcall` except the wrapper's inner
# blocking call is `@ccall gc_safe=true …`. That marks the adopted worker thread
# GC-safe for the duration of the blocking call, so the collector treats it as parked
# and never waits on it. This is correct here precisely because the blocking call
# touches no Julia heap: it returns a libzenohc handle, which is stored (`unsafe_store!`)
# into a `GC.@preserve`d buffer *after* the call returns, back in GC-unsafe state.
#
# It reuses `Base.do_threadcall` unchanged — only the per-call wrapper differs — so
# concurrency limiting (the libuv pool semaphore) and the completion/notify path are
# exactly Base's.
macro gc_safe_threadcall(f, rettype, argtypes, argvals...)
    isa(argtypes, Expr) && argtypes.head === :tuple ||
        error("gc_safe_threadcall: argument types must be a tuple")
    length(argtypes.args) == length(argvals) ||
        error("gc_safe_threadcall: wrong number of arguments to C function")

    f = esc(f)
    rettype = esc(rettype)
    argtypes = map(esc, argtypes.args)
    argvals = map(esc, argvals)

    # Non-allocating wrapper that runs on the libuv worker thread.
    wrapper = :(function (fptr::Ptr{Cvoid}, args_ptr::Ptr{Cvoid}, retval_ptr::Ptr{Cvoid})
        p = args_ptr
    end)
    body = wrapper.args[2].args
    args = Symbol[]
    for (i, T) in enumerate(argtypes)
        arg = Symbol("arg", i)
        push!(body, :($arg = unsafe_load(convert(Ptr{$T}, p))))
        push!(body, :(p += Core.sizeof($T)))
        push!(args, arg)
    end
    # The gc_safe inner call — the sole difference from Base.@threadcall.
    # Built as `@ccall gc_safe=true $fptr(a::T, …)::rettype`.
    typed = [:($(args[i])::$(argtypes[i])) for i in eachindex(args)]
    inner_call = Expr(:(::), Expr(:call, Expr(:$, :fptr), typed...), rettype)
    gc_safe_ccall = Expr(:macrocall, GlobalRef(Base, Symbol("@ccall")), __source__,
                         Expr(:(=), :gc_safe, true), inner_call)
    push!(body, :(ret = $gc_safe_ccall))
    push!(body, :(unsafe_store!(convert(Ptr{$rettype}, retval_ptr), ret)))
    push!(body, :(return Int(Core.sizeof($rettype))))

    wrapper = Expr(:var"hygienic-scope", wrapper, @__MODULE__, __source__)
    return :(let fun_ptr = @cfunction($wrapper, Int, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
        Base.do_threadcall(fun_ptr, cglobal($f), $rettype, Any[$(argtypes...)], Any[$(argvals...)])
    end)
end
