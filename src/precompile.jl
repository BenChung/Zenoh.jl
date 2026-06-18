# Precompile the entity-declaration / QoS-option path — the largest inference bucket in a fresh
# consumer's time-to-first-declare (~200 ms of keyword-sorter bodies + option builders, per
# ROSNode startup profiling).
#
# Constraint: PrecompileTools workloads run during precompilation, where finalizers and
# `Threads.@spawn`'d tasks do NOT reliably run. The publishers tear down synchronously and own no
# libuv handle, so they are declared LIVE against a router-free peer session (the biggest bucket,
# and the kwsorter/option frames are only reachable by an actual call). The subscriber and
# buffered-queryable declare paths spin up a callback ring whose teardown is finalizer/task-
# deferred — declaring them live would leave an `AsyncCondition` open at the completion check
# ("Waiting for background task / IO / timer"). So instead we exercise their option builders and
# the callback-ctx lifecycle directly (session-free, torn down synchronously) and name the recv
# frame — covering the inference without leaving an event source alive.
#
# The callback cfunction pointers (set in `__init__`, which has not run yet) do not matter here:
# the compiled code reads those pointer `Ref`s at runtime, so codegen is identical whether they
# are set or null. The whole block is best-effort — a sandbox that cannot open a session still
# precompiles (the publisher frames just aren't baked).

using PrecompileTools

@setup_workload begin
    @compile_workload begin
        # Publishers (plain + advanced) — live declares drive the kwarg-sorter + option-builder
        # path (_make_publisher_opts / _declare_plain_publisher / _make_advanced_publisher_opts /
        # _wants_advanced / _cache_value / …). No AsyncCondition or task; close is synchronous.
        try
            s = open(Config(; str =
                "{mode:\"peer\",scouting:{multicast:{enabled:false}},timestamping:{enabled:true}}"))
            ke = Keyexpr("z/precompile")
            p1 = Publisher(s, ke; reliability = Reliabilities.RELIABLE)
            # Advanced publisher's declare needs session timestamping; its option-builder frames
            # (the biggest bucket) compile whether or not the declare itself succeeds.
            p2 = try
                AdvancedPublisher(s, ke; reliability = Reliabilities.RELIABLE,
                    cache = CacheOptions(1), miss_detection = MissDetectionOptions(:periodic),
                    detection = DetectionOptions())
            catch
                nothing
            end
            p2 === nothing || close(p2)
            close(p1)
            close(s)
        catch
            # No session in this environment — skip; the publisher frames just aren't baked.
        end

        # Subscriber / queryable inference, session-free and synchronously torn down so nothing
        # lingers. The option builders run directly; the callback ring is set up and immediately
        # destroyed (destroy_ctx! closes the AsyncCondition synchronously — no finalizer/task);
        # the recv frame is named (unreachable without inbound traffic). This covers everything but
        # the `_open_*_sub` declare closures, which are only reachable by a live declare (whose
        # async teardown is precompile-hostile).
        for origin in (Localities.ANY, nothing)
            _make_subscriber_opts(origin)
        end
        _make_queryable_opts(; complete = true, allowed_origin = Localities.ANY)
        for kind in (Val(:sample), Val(:query))
            ctx, ac, _ = _setup_callback(kind, 16)
            _teardown_callback(kind, ctx, ac)
        end
        precompile(_ring_take, (CallbackCtx{LibZenohC.z_owned_sample_t}, Base.AsyncCondition))
        precompile(_ring_take, (CallbackCtx{LibZenohC.z_owned_query_t},  Base.AsyncCondition))
    end
end
