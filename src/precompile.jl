# Precompile the entity-declaration / QoS-option path — the largest inference bucket in a fresh
# consumer's time-to-first-declare (~360 ms of keyword-sorter bodies + option builders + declare
# closures, per ROSNode startup profiling).
#
# Constraint: PrecompileTools workloads run during precompilation, where finalizers and
# `Threads.@spawn`'d tasks do NOT reliably run. So:
#   • Publishers, the fifo subscriber, and the buffered (ring) queryable own no declare-time task,
#     and their ctx teardown is now idempotent (see destroy_ctx!), so we declare them LIVE and tear
#     them down SYNCHRONOUSLY here (the deferred finalizer becomes a harmless no-op). This bakes the
#     kwsorter + option-builder + `_open_*` declare frames — only reachable by a real call.
#   • The keep_all subscriber `@spawn`s a drain task at declare that can't be reliably driven to exit
#     during precompilation, so it would leave a live task at the completion check. Its frames are
#     instead baked by naming the drain body + recv directly.
#
# The callback cfunction pointers (set in `__init__`, which has not run yet) do not matter here: the
# compiled code reads those pointer `Ref`s at runtime, so codegen is identical whether they are set
# or null. The whole block is best-effort — a sandbox that cannot open a session still precompiles.

using PrecompileTools

@setup_workload begin
    @compile_workload begin
        try
            s = open(Config(; str =
                "{mode:\"peer\",scouting:{multicast:{enabled:false}},timestamping:{enabled:true}}"))
            ke = Keyexpr("z/precompile")

            # Plain publisher — _make_publisher_opts / _declare_plain_publisher. No ctx/task.
            p1 = Publisher(s, ke; reliability = Reliabilities.RELIABLE)

            # Advanced publisher — _make_advanced_publisher_opts / _wants_advanced / _cache_value …,
            # the biggest bucket. Its declare needs session timestamping; the option-builder frames
            # compile whether or not the declare itself succeeds, so tolerate failure.
            p2 = try
                AdvancedPublisher(s, ke; reliability = Reliabilities.RELIABLE,
                    cache = CacheOptions(1), miss_detection = MissDetectionOptions(:periodic),
                    detection = DetectionOptions())
            catch
                nothing
            end
            p2 === nothing || close(p2)

            # Fifo buffered subscriber — _open_buffered_sub / _make_subscriber_opts. The kwarg shape
            # must match ROSNode's (channel + capacity + allowed_origin; ROSNode entity.jl) — the
            # kwsorter body is specialized per kwarg-NamedTuple shape. `_open_buffered_sub` also
            # infers its `_open_keepall_sub` branch, so this one declare covers both sub flavours.
            # No declare-time task; close() defers ctx teardown to a finalizer, so drive that
            # synchronously here (idempotent destroy_ctx! makes the later finalizer a no-op) to leave
            # no AsyncCondition open.
            sf = open(s, ke; channel = :fifo, capacity = 16, allowed_origin = Localities.ANY)
            close(sf)
            _teardown_buffered_sub!(sf)

            # Buffered (ring) queryable — matches ROSNode's service queryable shape
            # `Queryable(s,k; channel=:fifo, complete=true)` (service.jl). Same synchronous-teardown
            # treatment as the fifo subscriber.
            qy = Queryable(s, ke; channel = :fifo, complete = true)
            close(qy)
            _teardown_buffered_queryable!(qy)

            close(p1)
            close(s)
        catch
            # No session in this environment — skip; these frames just aren't baked.
        end

        # keep_all subscriber frames: its declare `@spawn`s a drain task that can't be exited
        # reliably during precompilation, so name the drain body + the no-origin opts variant rather
        # than declaring it live. The recv frames (`_ring_take`) need inbound traffic, so name them too.
        _make_subscriber_opts(nothing)
        precompile(_drain_samples,
            (CallbackCtx{LibZenohC.z_owned_sample_t}, Base.AsyncCondition, Channel{Sample}))
        precompile(_ring_take, (CallbackCtx{LibZenohC.z_owned_sample_t}, Base.AsyncCondition))
        precompile(_ring_take, (CallbackCtx{LibZenohC.z_owned_query_t},  Base.AsyncCondition))
    end
end
