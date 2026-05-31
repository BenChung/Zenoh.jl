# Ring-backed buffered delivery: the properties the callback-ring rewrite is
# meant to guarantee that the old blocking-`z_recv` form could not.
# Uses the shared router session S1.

@timed_testset "Ring scaling: >4 buffered endpoints coexist" timeout=30 begin
    s = S1
    N = 16                              # ≫ Base.threadcall_restrictor.sem_size (4)
    keys = [Zenoh.Keyexpr("test/ring/scale/$i") for i in 1:N]
    subs = [open(s, keys[i]; channel=:fifo, capacity=8) for i in 1:N]
    pubs = [Zenoh.Publisher(s, keys[i]) for i in 1:N]
    sleep(0.5)                          # let subscriptions propagate
    try
        for (i, p) in enumerate(pubs)
            Zenoh.put(p, "hi-$i")
        end
        # Under the old form, the 5th+ idle FIFO consumer parked a
        # @threadcall slot and this take! would hang (watchdog → exit 124).
        for (i, sub) in enumerate(subs)
            smp = take!(sub)
            @test String(Zenoh.payload(smp)) == "hi-$i"
        end
    finally
        close.(subs)
        close.(pubs)
    end
end

@timed_testset "Ring ordering + drop-oldest accounting" begin
    s = S1
    k = Zenoh.Keyexpr("test/ring/order")
    cap = 4
    sub = open(s, k; channel=:fifo, capacity=cap)
    pub = Zenoh.Publisher(s, k)
    sleep(0.3)
    try
        for n in 1:10
            Zenoh.put(pub, string(n))
        end
        sleep(0.4)                      # all 10 land in the ring before we drain

        got = Int[]
        while (smp = Zenoh.tryrecv!(sub)) !== nothing
            push!(got, parse(Int, String(Zenoh.payload(smp))))
        end

        @test issorted(got)                          # FIFO order preserved
        @test length(got) ≤ cap                      # bounded buffer
        @test !isempty(got) && got[end] == 10        # newest retained (drop-oldest)
        @test Zenoh.dropped_count(sub) ≥ 1           # drops happened and were counted
        @test Zenoh.dropped_count(sub) + length(got) ≤ 10
    finally
        close(sub)
        close(pub)
    end
end

@timed_testset "KEEP_ALL: lossless under burst (heap-backed)" begin
    s = S1
    k = Zenoh.Keyexpr("test/ring/keepall")
    # Small ring on purpose: the consume task drains it into an unbounded heap
    # Channel far faster than delivery, so nothing is dropped at the ring even
    # though the same burst would evict under :ring/capacity=4.
    sub = open(s, k; channel=:keep_all, capacity=4)
    @test sub isa Zenoh.KeepAllSubscriber
    pub = Zenoh.Publisher(s, k)
    sleep(0.3)
    try
        N = 50
        for n in 1:N
            Zenoh.put(pub, string(n))
        end
        sleep(0.5)
        got = Int[]
        while (smp = Zenoh.tryrecv!(sub)) !== nothing
            push!(got, parse(Int, String(Zenoh.payload(smp))))
        end
        @test length(got) == N            # every sample retained
        @test issorted(got)               # in order
        @test Zenoh.dropped_count(sub) == 0
    finally
        close(sub)
        close(pub)
    end
end

@timed_testset "KEEP_ALL: close drains remnants then ends" begin
    s = S1
    k = Zenoh.Keyexpr("test/ring/keepall_close")
    sub = open(s, k; channel=:keep_all, capacity=8)
    pub = Zenoh.Publisher(s, k)
    sleep(0.3)
    try
        for n in 1:5
            Zenoh.put(pub, string(n))
        end
        sleep(0.3)
        close(sub)                        # task drains remnants into ch, then closes ch
        got = String[]
        for smp in sub                    # iterate the closed-but-buffered Channel to exhaustion
            push!(got, String(Zenoh.payload(smp)))
        end
        @test length(got) == 5
    finally
        close(pub)
    end
end

@timed_testset "Ring: take! unblocks on close (no slot)" begin
    s = S1
    k = Zenoh.Keyexpr("test/ring/closewake")
    sub = open(s, k; channel=:fifo, capacity=4)
    sleep(0.2)
    try
        done = Channel{Symbol}(1)
        @async try
            take!(sub)                  # blocks: ring empty
            put!(done, :got)
        catch
            put!(done, :disconnected)   # close → ZenohError(DISCONNECTED)
        end
        sleep(0.2)
        close(sub)
        @test take!(done) === :disconnected
    finally
        # already closed
    end
end
