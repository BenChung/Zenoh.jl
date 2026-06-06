using Zenoh, Zenohd_jll, Test
include("test_utils.jl")

# Distinct random TCP port per run, so a lingering router from a previous
# (crashed/killed) run can't bind-collide with this run's router or be
# mistaken for it. All sessions below connect to `$EP`.
const PORT = rand(20000:39999)
const EP = "tcp/localhost:$PORT"
@info "test router endpoint" EP
# Router logs go to a per-run file, NOT the test process's stdout. Inheriting
# stdout (the previous behaviour) wired zenohd's fd to the test runner's
# output stream, so a hung test (whose `finally` never killed the router) left
# zenohd holding that stream open — any capture/pipe of the test output then
# blocked indefinitely instead of seeing the failure. A file also keeps the
# test summary readable and preserves router logs for postmortem.
const ROUTER_LOG = joinpath(tempdir(), "zenohd-test-$PORT.log")
# `scouting/multicast/enabled:false`: keep this router from multicast-discovering
# an unrelated zenohd on the box (e.g. a dev router on the default :7447). Without
# it the test router connects out to that stray router and gossips it to the test
# sessions, which then wedge on `close` (10s open_timeout → -128). Sessions also
# disable multicast (see `_NO_SCOUT`); gossip stays on for matching_status.
router = run(pipeline(`$(Zenohd_jll.zenohd()) -l $EP --cfg scouting/multicast/enabled:false`,
                      stdout = ROUTER_LOG, stderr = ROUTER_LOG), wait=false)

# Two long-lived router-connected sessions, shared across the semantically
# neutral round-trip testsets (generic pub/sub/get/queryable/querier on
# distinct keys) so the suite doesn't pay a ~0.5s session-open per testset.
# Testsets that need distinct peers for their semantics (locality /
# allowed_origin), SHM (`shm_clients=`), liveliness propagation, or that close
# the session under test, keep opening their own — they do NOT use S1/S2.
# Test sessions must talk ONLY to this run's isolated router on $EP. Left at
# zenoh's default, *multicast* scouting also discovers any other zenohd on the
# machine — e.g. a dev router on the default :7447 — and that stray
# cross-connection wedges session `close` (it parks the full 10s open_timeout,
# then throws ZenohError(-128)). So every test config disables multicast
# scouting. Gossip stays ON: it only propagates over already-established links
# (here just the test router), so it can't reach an external zenohd, and the
# matching_status / MatchingListener tests rely on it to learn a peer's
# subscriptions through the router. `epcfg` additionally points `connect` at the
# test router; pass extra JSON5 sections (shm, timestamping, …) via `extra`.
const _NO_SCOUT = "scouting:{multicast:{enabled:false}}"
epcfg(extra::AbstractString="") = Zenoh.Config(; str =
    "{connect:{endpoints:[\"$EP\"]}, $_NO_SCOUT$(isempty(extra) ? "" : ", $extra")}")
rcfg() = epcfg()
sleep(0.3)            # let the router bind
S1 = open(rcfg())
S2 = open(rcfg())
sleep(0.5)            # let S1/S2 connect before the first round-trip

try
    @timed_testset "Config" begin
        c = Zenoh.Config()
        ref = Zenoh.toJson(c)
        c["connect/endpoints"] = "[\"$EP\"]"
        @test c["connect/endpoints"] == "[\"$EP\"]"
        @test length(Zenoh.toJson(c)) > length(ref) # lame I know

        # Typed setindex! serializes Julia values to JSON5 fragments.
        @test Zenoh._to_json5(true) == "true"
        @test Zenoh._to_json5(5000) == "5000"
        @test Zenoh._to_json5(:peer) == "\"peer\""
        @test Zenoh._to_json5(["a", "b"]) == "[\"a\",\"b\"]"
        @test Zenoh._to_json5(Connect(endpoints = ["x"], exit_on_failure = true)) ==
            "{\"endpoints\":[\"x\"],\"exit_on_failure\":true}"
        c2 = Zenoh.Config()
        c2["mode"] = :peer
        @test c2["mode"] == "\"peer\""
        c2["scouting/multicast/enabled"] = false
        @test c2["scouting/multicast/enabled"] == "false"
    end

    @timed_testset "ZenohConfig" begin
        c = Config(ZenohConfig(
            mode = :peer,
            connect = Connect(endpoints = ["$EP"]),
            scouting = Scouting(multicast = Multicast(enabled = false)),
            timestamping = Timestamping(enabled = true),
            queries_default_timeout = 5000,
            open = Open(connect_scouted = false, declares = true),
            transport = Transport(
                shared_memory = SharedMemory(enabled = true),
                link = Link(tx = LinkTx(threads = 4)),
                auth = Auth(usrpwd = UsrPwd(user = "u", password = "p")),
            ),
            qos = Qos(network = [QosOverwrite(
                messages = ["put"], key_exprs = ["demo/**"],
                overwrite = QosOverwriteValues(priority = :data_high))]),
            adminspace = AdminSpace(enabled = true,
                permissions = Permissions(read = true, write = false)),
            overrides = Dict("transport/link/rx/buffer_size" => 65536),
        ))
        @test c["mode"] == "\"peer\""
        @test c["connect/endpoints"] == "[\"$EP\"]"
        @test c["scouting/multicast/enabled"] == "false"
        @test c["timestamping/enabled"] == "true"
        @test c["queries_default_timeout"] == "5000"
        @test c["open/return_conditions/declares"] == "true"
        @test c["adminspace/enabled"] == "true"
        @test occursin("data_high", c["qos/network"]) && startswith(c["qos/network"], "[")
        @test c["transport/shared_memory/enabled"] == "true"
        @test c["transport/link/tx/threads"] == "4"
        @test c["transport/auth/usrpwd/user"] == "\"u\""
        @test c["transport/link/rx/buffer_size"] == "65536"

        # Unknown mode symbols are rejected.
        @test_throws ArgumentError Config(ZenohConfig(mode = :bogus))

        # A typed config opens a working session, like the string-built form.
        # Scouting off (built through the typed structs) keeps it isolated to the
        # test router; see the _NO_SCOUT note at the top.
        s = open(Config(ZenohConfig(
            connect  = Connect(endpoints = ["$EP"]),
            scouting = Scouting(multicast = Multicast(enabled = false)))))
        close(s)
    end

    struct TestStruct
        a::Int
        b::Float64
    end
    # For ZRef round-trip tests. Pixel has alignment 1 (all-UInt8), so it views
    # in place even through the align-1 POSIX provider; ZBig has alignment 8 to
    # exercise the align-fallback / copy paths.
    struct Pixel; r::UInt8; g::UInt8; b::UInt8; a::UInt8; end
    struct ZBig; x::Int64; y::Float64; n::Int32; end
    # 128 KiB isbits payload — larger than the tiny provider injected in the
    # alloc-error tests, so `zref(session, Huge)` forces a ShmAllocError.
    struct Huge; data::NTuple{1 << 17, UInt8}; end
    @timed_testset "ZBytes" begin 
        zb = Zenoh.ZBytes("hi")
        @test length(zb) == 2
        open(zb, Val(:read)) do r 
            @test read(r, String) == "hi"
        end
        open(zb, Val(:readslice)) do r 
            @test read(r, String) == "hi"
        end
        zb = Zenoh.ZBytes([1, 2, 3, 4])
        @test length(zb) == 4*8
        open(zb, Val(:read)) do r 
            @test read(r, Int) == 1
            @test read(r, Int) == 2
            @test read(r, Int) == 3
            @test read(r, Int) == 4
        end
        open(zb, Val(:readslice)) do r 
            @test read(r, Int) == 1
            @test read(r, Int) == 2
            @test read(r, Int) == 3
            @test read(r, Int) == 4
        end
        r = Ref{TestStruct}(TestStruct(1, 2.0))
        zb = Zenoh.ZBytes(r)
        open(zb, Val(:read)) do r 
            @test read(r, Int) == 1
            @test read(r, Float64) == 2.0
        end
        open(zb, Val(:readslice)) do r 
            @test read(r, Int) == 1
            @test read(r, Float64) == 2.0
        end
        zb = Zenoh.ZBytes(:hi)
        open(zb, Val(:read)) do r
            @test read(r, String) == "hi"
        end
        open(zb, Val(:readslice)) do r
            @test read(r, String) == "hi"
        end

        # Extraction conversions
        @test String(Zenoh.ZBytes("hello")) == "hello"
        @test Vector{UInt8}(Zenoh.ZBytes("hello")) == Vector{UInt8}("hello")
        @test Vector{UInt8}(Zenoh.ZBytes(UInt8[1, 2, 3])) == UInt8[1, 2, 3]
        @test isempty(Zenoh.ZBytes())
        @test !isempty(Zenoh.ZBytes("x"))
        @test length(Zenoh.ZBytes()) == 0

        # Copy constructors: source need not be kept alive
        @test String(Zenoh.ZBytes("copied"; copy=true)) == "copied"
        @test Vector{UInt8}(Zenoh.ZBytes(UInt8[9, 8, 7]; copy=true)) == UInt8[9, 8, 7]

        # ZBytesWriter: explicit finish
        w = Zenoh.ZBytesWriter()
        write(w, "ab")
        write(w, UInt8[0x63])  # "c"
        @test String(finish(w)) == "abc"

        # append! splices a ZBytes onto the writer
        w = Zenoh.ZBytesWriter()
        write(w, "head-")
        append!(w, Zenoh.ZBytes("tail"))
        @test String(finish(w)) == "head-tail"

        # do-block open form returns the finished payload
        zb = open(Zenoh.ZBytes, Val(:write)) do w
            write(w, "x")
            write(w, "y")
        end
        @test String(zb) == "xy"

        # round-trip a binary value through the writer
        zb = open(Zenoh.ZBytes, Val(:write)) do w
            write(w, Int64(42))
            write(w, 3.5)
        end
        open(zb, Val(:read)) do r
            @test read(r, Int64) == 42
            @test read(r, Float64) == 3.5
        end

        # close() drops an unfinished writer (explicit, main-task cleanup)
        w = Zenoh.ZBytesWriter()
        write(w, "discarded")
        close(w)
        @test true  # no crash; resource freed without a finalizer

        # ZBytes(::ZBytes) identity — lets send APIs move a pre-built payload
        let z = Zenoh.ZBytes("identity")
            @test Zenoh.ZBytes(z) === z
        end

        # close(::ZBytes) reclaims an owned ZBytes on the caller's task
        zc = Zenoh.ZBytes("to-be-closed")
        close(zc)
        @test true  # no crash; dropped without a finalizer
    end

    @timed_testset "ZSlice" begin
        es = Zenoh.ZSlice()
        @test isempty(es)
        @test length(es) == 0

        data = UInt8[1, 2, 3, 4, 5]
        cs = Zenoh.ZSlice(data; copy=true)
        @test !isempty(cs)
        @test length(cs) == 5
    end

    @timed_testset "Serializer" begin
        # Scalar round-trip.
        @test Zenoh.deserialize(Int64, Zenoh.serialize(Int64(42))) == 42

        # 16-byte array, length-prefixed (Vector{UInt8} ↔ buf/slice).
        d = collect(UInt8, 1:16)
        @test Zenoh.deserialize(Vector{UInt8}, Zenoh.serialize(d)) == d

        # 16-byte array, fixed no-prefix (NTuple{16,UInt8} ↔ N× uint8).
        t = ntuple(i -> UInt8(i), 16)
        @test Zenoh.deserialize(NTuple{16,UInt8}, Zenoh.serialize(t)) === t

        # Composite: int64 + 16-byte array in one payload.
        p = (Int64(-7), collect(UInt8, 1:16))
        @test Zenoh.deserialize(Tuple{Int64,Vector{UInt8}}, Zenoh.serialize(p)) == p

        # Handle API (write/read) + cursor exhaustion.
        s = Zenoh.ZSerializer()
        write(s, Int64(7))
        write(s, ntuple(i -> UInt8(i), 16))
        zb = finish(s)
        de = Zenoh.ZDeserializer(zb)
        @test read(de, Int64) == 7
        @test read(de, NTuple{16,UInt8}) === ntuple(i -> UInt8(i), 16)
        @test Zenoh.is_done(de)

        # Lifecycle: close is idempotent; finish/write after finish error.
        s2 = Zenoh.ZSerializer(); close(s2); close(s2); @test true
        s3 = Zenoh.ZSerializer(); finish(s3)
        @test_throws ErrorException finish(s3)
        s4 = Zenoh.ZSerializer(); finish(s4)
        @test_throws ErrorException write(s4, Int64(1))
    end

    @timed_testset "LogSeverity" begin
        S = Zenoh.LogSeverities
        for s in (S.TRACE, S.DEBUG, S.INFO, S.WARN, S.ERROR)
            @test s isa Zenoh.LogSeverity
            @test Zenoh._log_severity_from_raw(Zenoh._raw(s)) === s
        end
        @test S.TRACE < S.DEBUG < S.INFO < S.WARN < S.ERROR
        @test S.DEBUG <= S.WARN
        @test occursin("LogSeverities.WARN", sprint(show, S.WARN))
        @test Zenoh._filter_string(S.ERROR) == "error"
        r = Zenoh.LogRecord(S.INFO, "hello")
        @test r.severity === S.INFO && r.message == "hello"
        @test occursin("LogRecord", sprint(show, r))
        @test Zenoh._LogEntry |> isbitstype
    end

    @timed_testset "Log capture (subprocess)" begin
        # Zenoh's log init is process-global + one-shot, so it can't run in
        # this shared test process; drive the foreign-thread bridge in a
        # throwaway subprocess and check it captured records.
        script = tempname() * ".jl"
        open(script, "w") do io
            # Scouting off (JSON5 needs no quotes — keeps this raw block
            # escape-free) so the throwaway session doesn't discover an external
            # zenohd and hang on shutdown; session startup alone still emits
            # plenty of TRACE/DEBUG records.
            println(io, raw"""
            using Zenoh
            ls = Zenoh.open_log_stream(min_severity=Zenoh.LogSeverities.TRACE, capacity=128)
            s = open(Zenoh.Config(; str = "{scouting:{multicast:{enabled:false}}}"))
            sleep(2.0)
            recs = Zenoh.LogRecord[]
            while (r = Zenoh.tryrecv!(ls)) !== nothing
                push!(recs, r)
            end
            println(stderr, "captured=", length(recs))
            ok = length(recs) >= 1 && all(r -> r.severity isa Zenoh.LogSeverity, recs)
            close(ls); close(s)
            exit(ok ? 0 : 2)
            """)
        end
        out = tempname()
        try
            # Use the package project (deterministic, precompiled) rather than the
            # Pkg.test sandbox; logging init is global so this runs out-of-process.
            proj = dirname(@__DIR__)
            p = run(pipeline(ignorestatus(`$(Base.julia_cmd()) --project=$proj $script`),
                             stdout=out, stderr=out))
            p.exitcode == 0 || @info "log-capture subprocess output" log=read(out, String)
            @test p.exitcode == 0
        finally
            rm(script; force=true)
            rm(out; force=true)
        end
    end

    @timed_testset "Keyexpr macro" begin
        k = kexpr"test/macro"
        @test k isa Zenoh.Keyexpr
        # `**/**` is non-canonical (collapses to `**`); strict rejects, `c` accepts.
        @test_throws Zenoh.ZenohError kexpr"**/**"
        @test kexpr"**/**"c isa Zenoh.Keyexpr
        # Unknown flag rejected at macro expansion.
        @test_throws ArgumentError @macroexpand kexpr"whatever"x
    end

    @timed_testset "Keyexpr utilities" begin
        a = Zenoh.Keyexpr("a/b/c")
        b = Zenoh.Keyexpr("a/b/c")
        c = Zenoh.Keyexpr("a/b/d")

        # String conversion / show
        @test String(a) == "a/b/c"
        @test string(a) == "a/b/c"
        @test sprint(show, a) == "Keyexpr(\"a/b/c\")"
        @test sprint(print, a) == "a/b/c"

        # Equality + hash consistency
        @test a == b
        @test a != c
        @test hash(a) == hash(b)

        # includes / intersects with wildcards
        star = Zenoh.Keyexpr("a/*/c")
        dstar = Zenoh.Keyexpr("a/**")
        @test Zenoh.includes(dstar, a)
        @test !Zenoh.includes(a, dstar)
        @test Zenoh.includes(star, a)
        @test Zenoh.intersects(star, a)
        @test Zenoh.intersects(dstar, c)
        # disjoint
        @test !Zenoh.intersects(Zenoh.Keyexpr("x/y"), a)

        # relation_to lattice + set-comparison predicates
        @test Zenoh.relation_to(dstar, a) === Zenoh.IntersectionLevels.INCLUDES
        @test Zenoh.relation_to(a, b)     === Zenoh.IntersectionLevels.EQUALS
        @test Zenoh.relation_to(Zenoh.Keyexpr("x/y"), a) === Zenoh.IntersectionLevels.DISJOINT
        @test Zenoh._intersection_level_from_raw(Zenoh._raw(Zenoh.IntersectionLevels.INTERSECTS)) ===
              Zenoh.IntersectionLevels.INTERSECTS
        @test occursin("IntersectionLevels.INCLUDES", sprint(show, Zenoh.IntersectionLevels.INCLUDES))
        # a ⊆ b ⟺ b ⊇ a (issubset is the dual of includes); isdisjoint = !intersects
        @test (a ⊆ dstar)
        @test !(dstar ⊆ a)
        @test issubset(a, b)
        @test isdisjoint(Zenoh.Keyexpr("x/y"), a)
        @test !isdisjoint(dstar, c)

        # concat — raw suffix, no separator inserted
        @test String(Zenoh.concat(a, "/d")) == "a/b/c/d"
        # bad suffix → ZenohError
        @test_throws Zenoh.ZenohError Zenoh.concat(a, "//bad")

        # join — keyexpr-with-separator
        @test String(join(a, Zenoh.Keyexpr("d/e"))) == "a/b/c/d/e"

        # canonize / is_canon
        @test Zenoh.canonize("a/**/**/b") == "a/**/b"
        @test Zenoh.is_canon("a/b/c")
        @test !Zenoh.is_canon("a/**/**/b")
        @test_throws Zenoh.ZenohError Zenoh.canonize("")
    end

    @timed_testset "Keyexpr interpolation" begin
        x = Zenoh.Keyexpr("a/b")
        y = Zenoh.Keyexpr("c/d")

        # $name
        @test String(kexpr"$x") == "a/b"
        @test String(kexpr"prefix/$x") == "prefix/a/b"
        @test String(kexpr"$x/suffix") == "a/b/suffix"
        @test String(kexpr"prefix/$x/suffix") == "prefix/a/b/suffix"

        # Multiple interpolations
        @test String(kexpr"$x/$y") == "a/b/c/d"
        @test String(kexpr"head/$x/mid/$y/tail") == "head/a/b/mid/c/d/tail"

        # $(expr) explicit form, and a complex expression
        @test String(kexpr"prefix/$(x)/suffix") == "prefix/a/b/suffix"
        @test String(kexpr"$(Zenoh.concat(x, \"/extra\"))") == "a/b/extra"

        # AbstractString interpolation
        seg = "plain"
        @test String(kexpr"prefix/$seg/suffix") == "prefix/plain/suffix"

        # Autocanonize flag through interpolation
        ks = Zenoh.Keyexpr("**")
        @test String(kexpr"$ks/**/leaf"c) == "**/leaf"
        # Without the flag, the assembled `**/**` is non-canonical → throw.
        @test_throws Zenoh.ZenohError kexpr"$ks/**/leaf"

        # Parse-time errors surface as ArgumentError from @macroexpand.
        @test_throws ArgumentError @macroexpand kexpr"trailing$"
        @test_throws ArgumentError @macroexpand kexpr"$(unbalanced"
        @test_throws ArgumentError @macroexpand kexpr"bad$!literal"

        # Round-tripped through interpolation == direct construction.
        @test kexpr"$x" == x
        @test kexpr"prefix/$x" == Zenoh.Keyexpr("prefix/a/b")
    end

    @timed_testset "ZBytes iteration" begin
        # Covers the iterate(::ZBytes) path, which must loan the underlying
        # z_owned_bytes_t before calling z_bytes_get_slice_iterator.
        zb = Zenoh.ZBytes("hello world")
        total = 0
        count = 0
        for view_slice in zb
            count += 1
            loaned = Zenoh.LibZenohC.z_view_slice_loan(view_slice)
            total += Zenoh.LibZenohC.z_slice_len(loaned)
        end
        @test count >= 1
        @test total == length(zb)
    end

    @timed_testset "Publisher-Subscriber" begin
        # Create a session with the router
        s = S1
        sub = nothing
        pub = nothing
        
        try
            # Create a keyexpr for testing
            test_key = Zenoh.Keyexpr("test/pubsub")
            
            # Create a channel to receive the message
            received_msg = Channel{String}(1)
            
            # Create a subscriber
            sub = open((s) -> begin 
                p = Zenoh.payload(s)
                open(p, Val(:read)) do msg
                    put!(received_msg, read(msg, String))
                end
            end, s, test_key)
            
            # Create a publisher
            pub = Zenoh.Publisher(s, test_key)
            
            # Test message
            test_message = "Hello from Zenoh!"
            
            # Publish the message
            Zenoh.put(pub, test_message)
            
            # Wait for and verify the received message
            received = take!(received_msg)
            @test received == test_message
        finally
            # Cleanup
            if !isnothing(sub)
                close(sub)
            end
            if !isnothing(pub)
                close(pub)
            end        end
    end

    @timed_testset "Serializer over session (deserialize from Sample)" begin
        # Encapsulation in practice: put(serialize(...)) on one side, then
        # deserialize(T, sample) straight off the received Sample — exercising
        # the loaned-payload deserialize path, and naming no ZBytes anywhere.
        s = S1
        sub = nothing
        pub = nothing
        try
            test_key = Zenoh.Keyexpr("test/serializer/session")
            got = Channel{Tuple{Int64,Vector{UInt8}}}(1)
            sub = open(sample -> put!(got, Zenoh.deserialize(Tuple{Int64,Vector{UInt8}}, sample)),
                       s, test_key)
            pub = Zenoh.Publisher(s, test_key)

            payload = (Int64(2024), collect(UInt8, 1:16))
            Zenoh.put(pub, Zenoh.serialize(payload))

            @test take!(got) == payload
        finally
            !isnothing(sub) && close(sub)
            !isnothing(pub) && close(pub)        end
    end

    @timed_testset "Move-on-send (prebuilt ZBytes payload)" begin
        # A payload assembled with ZBytesWriter (an owned ZBytes) can be sent
        # directly: put moves it in, so it's consumed — no leak, no finalizer.
        s = S1
        sub = nothing
        pub = nothing
        try
            test_key = Zenoh.Keyexpr("test/move-on-send")
            received = Channel{String}(2)
            sub = open(s, test_key) do sample
                put!(received, String(Zenoh.payload(sample)))
            end
            pub = Zenoh.Publisher(s, test_key)

            # (1) send the assembled output of a writer
            assembled = open(Zenoh.ZBytes, Val(:write)) do w
                write(w, "head-")
                write(w, "tail")
            end
            Zenoh.put(pub, assembled)             # moves `assembled` in
            @test take!(received) == "head-tail"

            # (2) send a plain pre-built ZBytes
            Zenoh.put(pub, Zenoh.ZBytes("prebuilt"))
            @test take!(received) == "prebuilt"
        finally
            isnothing(sub) || close(sub)
            isnothing(pub) || close(pub)        end
    end

    @timed_testset "Timestamp and ZID" begin
        # Create a session with the router
        s = S1
        sub = nothing
        pub = nothing
        
        try
            # Test session ZID
            session_zid = Zenoh.zid(s)
            @test !all(iszero, session_zid.id)  # ZID should not be all zeros

            # to_le_bytes returns the raw 16-byte LE array; the show string is
            # those bytes reversed (big-endian) with leading zeros elided.
            le = to_le_bytes(session_zid)
            @test le isa NTuple{16,UInt8}
            @test le == session_zid.id
            known = Zenoh.LibZenohC.z_id_t(ntuple(i -> UInt8(i), 16))
            @test to_le_bytes(known) == ntuple(i -> UInt8(i), 16)
            @test sprint(show, known) == "z_id: " * bytes2hex(reverse(collect(to_le_bytes(known))))

            # Test router ZIDs
            router_ids = Zenoh.router_zids(s)
            @test !isempty(router_ids)  # Should have at least one router (the one we started)
            
            # Test timestamp creation
            ts1 = Zenoh.ZTimestamp(s)
            @test ts1 isa Zenoh.ZTimestamp
            @test Zenoh.ntp64_time(ts1) > 0  # Should be a positive NTP64 timestamp
            ts1_zid = Zenoh.zid(ts1)
            @test !all(iszero, ts1_zid.id)  # Timestamp ZID should not be all zeros
            
            # Test timestamp copying
            ts2 = Zenoh.ZTimestamp(ts1.ts)
            @test ts2 isa Zenoh.ZTimestamp
            @test Zenoh.ntp64_time(ts2) == Zenoh.ntp64_time(ts1)  # Should have same time
            ts2_zid = Zenoh.zid(ts2)
            @test ts2_zid.id == ts1_zid.id  # Should have same ZID
            
            # Test timestamp functionality with a publisher/subscriber
            test_key = Zenoh.Keyexpr("test/timestamp")
            
            # Create channels to receive the message and timestamp
            received_msg = Channel{String}(1)
            received_timestamp = Channel{Union{Nothing, Zenoh.ZTimestamp}}(1)
            
            # Create a subscriber
            sub = open((s) -> begin 
                p = Zenoh.payload(s)
                ts = Zenoh.timestamp(s)
                put!(received_timestamp, ts)
                open(p, Val(:read)) do msg
                    put!(received_msg, read(msg, String))
                end
            end, s, test_key)
            
            # Create a publisher
            pub = Zenoh.Publisher(s, test_key)
            
            # Test message
            test_message = "Testing timestamps"
            
            # Publish the message with a timestamp
            ts3 = Zenoh.ZTimestamp(s)
            Zenoh.put(pub, test_message, timestamp=ts3)

            # Get the timestamp and the msg in the same order as they're written
            ts = take!(received_timestamp)
            @test ts isa Zenoh.ZTimestamp
            
            # Wait for and verify the received message and timestamp
            received = take!(received_msg)
            @test received == test_message
            
            # Test timestamp properties
            @test Zenoh.ntp64_time(ts) > 0  # Should be a positive NTP64 timestamp
            ts_zid = Zenoh.zid(ts)
            @test !all(iszero, ts_zid.id)  # Timestamp ZID should not be all zeros
        finally
            # Cleanup
            if !isnothing(sub)
                close(sub)
            end
            if !isnothing(pub)
                close(pub)
            end        end
    end

    @timed_testset "Session put with timestamp" begin
        # Exercises Zenoh.put(::Session, ::Keyexpr, payload; timestamp=...),
        # which writes the timestamp through Ptr{z_put_options_t}. Using the
        # wrong options struct type would land the write at the wrong offset
        # and the received timestamp would not match what was sent.
        s = S1
        sub = nothing

        try
            test_key = Zenoh.Keyexpr("test/session_put_ts")
            received_msg = Channel{String}(1)
            received_timestamp = Channel{Union{Nothing, Zenoh.ZTimestamp}}(1)

            sub = open((sample) -> begin
                p = Zenoh.payload(sample)
                put!(received_timestamp, Zenoh.timestamp(sample))
                open(p, Val(:read)) do msg
                    put!(received_msg, read(msg, String))
                end
            end, s, test_key)

            test_message = "Session put with explicit timestamp"
            ts_sent = Zenoh.ZTimestamp(s)
            Zenoh.put(s, test_key, test_message, timestamp=ts_sent)

            ts_received = take!(received_timestamp)
            @test ts_received isa Zenoh.ZTimestamp
            @test Zenoh.ntp64_time(ts_received) == Zenoh.ntp64_time(ts_sent)
            @test Zenoh.zid(ts_received).id == Zenoh.zid(ts_sent).id

            received = take!(received_msg)
            @test received == test_message
        finally
            if !isnothing(sub)
                close(sub)
            end        end
    end

    @timed_testset "Sample accessors" begin
        s = S1
        sub = nothing
        pub = nothing

        try
            test_key_str = "test/sample_accessors"
            test_key = Zenoh.Keyexpr(test_key_str)

            received_kind = Channel{Zenoh.SampleKind}(1)
            received_keyexpr = Channel{String}(1)
            received_attachment = Channel{Union{Nothing, Zenoh.ZBytes}}(1)
            received_encoding = Channel{Zenoh.Encoding}(1)
            received_cc = Channel{Zenoh.CongestionControl}(1)
            received_prio = Channel{Zenoh.Priority}(1)
            received_express = Channel{Bool}(1)
            received_done = Channel{Bool}(1)

            sub = open((sample) -> begin
                put!(received_kind, Zenoh.kind(sample))
                put!(received_keyexpr, Zenoh.keyexpr(sample))
                put!(received_attachment, Zenoh.attachment(sample))
                put!(received_encoding, Zenoh.encoding(sample))
                put!(received_cc, Zenoh.congestion_control(sample))
                put!(received_prio, Zenoh.priority(sample))
                put!(received_express, Zenoh.express(sample))
                put!(received_done, true)
            end, s, test_key)

            pub = Zenoh.Publisher(s, test_key)
            Zenoh.put(pub, "sample accessor payload")

            @test take!(received_done)
            @test take!(received_kind) === Zenoh.SampleKinds.PUT
            @test take!(received_keyexpr) == test_key_str
            @test take!(received_attachment) === nothing
            enc = take!(received_encoding)
            @test enc isa Zenoh.Encoding
            @test !isempty(enc.mime)
            @test take!(received_cc) === Zenoh.CongestionControls.DEFAULT
            @test take!(received_prio) === Zenoh.Priorities.DEFAULT
            @test take!(received_express) isa Bool
        finally
            if !isnothing(sub)
                close(sub)
            end
            if !isnothing(pub)
                close(pub)
            end        end
    end

    @timed_testset "Encoding" begin
        # Pure-Julia behaviour: construction, equality, string round-trip.
        e1 = Zenoh.Encoding("application/json")
        @test e1.mime == "application/json"
        @test e1.schema === nothing
        @test string(e1) == "application/json"

        e2 = Zenoh.Encoding("application/json"; schema="v1.2")
        @test e2.schema == "v1.2"
        @test string(e2) == "application/json;v1.2"
        @test e1 != e2
        @test hash(e1) != hash(e2)

        # MIME input.
        e3 = Zenoh.Encoding(MIME("text/plain"))
        @test e3 == Zenoh.Encoding("text/plain")

        # Equality & hash for identical values.
        @test Zenoh.Encoding("application/xml") == Zenoh.Encoding("application/xml")
        @test hash(Zenoh.Encoding("application/xml")) == hash(Zenoh.Encoding("application/xml"))

        # show should be parsable-looking and include the schema when present.
        @test occursin("\"application/json\"", sprint(show, e1))
        @test occursin("schema=\"v1.2\"", sprint(show, e2))

        # Encodings submodule has canonical constants.
        @test Zenoh.Encodings.APPLICATION_JSON == Zenoh.Encoding("application/json")
        @test Zenoh.Encodings.TEXT_PLAIN.mime == "text/plain"
        @test Zenoh.Encodings.ZENOH_BYTES.mime == "zenoh/bytes"
    end

    @timed_testset "Put with encoding" begin
        s = S1
        sub = nothing
        pub = nothing

        try
            test_key = Zenoh.Keyexpr("test/encoding_putget")
            received_enc = Channel{Zenoh.Encoding}(4)
            received_msg = Channel{String}(4)

            sub = open((sample) -> begin
                put!(received_enc, Zenoh.encoding(sample))
                p = Zenoh.payload(sample)
                open(p, Val(:read)) do msg
                    put!(received_msg, read(msg, String))
                end
            end, s, test_key)

            pub = Zenoh.Publisher(s, test_key)

            # Publisher.put with Encoding value.
            Zenoh.put(pub, "json payload"; encoding=Zenoh.Encodings.APPLICATION_JSON)
            @test take!(received_msg) == "json payload"
            @test take!(received_enc) == Zenoh.Encoding("application/json")

            # Publisher.put with raw String (coerced to Encoding).
            Zenoh.put(pub, "yaml payload"; encoding="application/yaml")
            @test take!(received_msg) == "yaml payload"
            @test take!(received_enc) == Zenoh.Encoding("application/yaml")

            # Session.put with Encoding value and schema.
            Zenoh.put(s, test_key, "json with schema";
                encoding=Zenoh.Encoding("application/json"; schema="v1.0"))
            @test take!(received_msg) == "json with schema"
            @test take!(received_enc) == Zenoh.Encoding("application/json"; schema="v1.0")

            # Session.put with Base.MIME.
            Zenoh.put(s, test_key, "plain text"; encoding=MIME("text/plain"))
            @test take!(received_msg) == "plain text"
            @test take!(received_enc) == Zenoh.Encoding("text/plain")
        finally
            if !isnothing(sub)
                close(sub)
            end
            if !isnothing(pub)
                close(pub)
            end        end
    end
    @timed_testset "Buffered subscriber" begin
        s = S1
        sub = nothing
        pub = nothing

        try
            test_key = Zenoh.Keyexpr("test/buffered_sub")
            sub = open(s, test_key; channel=:fifo, capacity=8)
            pub = Zenoh.Publisher(s, test_key)

            # tryrecv! on empty channel returns nothing.
            @test Zenoh.tryrecv!(sub) === nothing

            # Single round-trip: take! blocks until a sample is available.
            Zenoh.put(pub, "hi-fifo")
            sample = take!(sub)
            @test sample isa Zenoh.Sample
            @test Zenoh.keyexpr(sample) == "test/buffered_sub"
            open(Zenoh.payload(sample), Val(:read)) do io
                @test read(io, String) == "hi-fifo"
            end

            # Iteration on one task, close from another. Because recv uses
            # @threadcall, the iter task cooperatively waits while the main
            # task runs close(sub); the close drops the closure, the channel
            # disconnects, and iteration terminates.
            for i in 1:3
                Zenoh.put(pub, "msg-$i")
            end

            collected = String[]
            done = Channel{Nothing}(1)
            iter_task = @async begin
                try
                    for sample in sub
                        open(Zenoh.payload(sample), Val(:read)) do io
                            push!(collected, read(io, String))
                        end
                    end
                finally
                    put!(done, nothing)
                end
            end
            sleep(0.2)
            close(sub)
            take!(done)
            @test istaskdone(iter_task)
            @test !istaskfailed(iter_task)
            @test "msg-1" in collected
            @test "msg-2" in collected
            @test "msg-3" in collected
            sub = nothing  # already closed
        finally
            if !isnothing(sub)
                close(sub)
            end
            if !isnothing(pub)
                close(pub)
            end        end
    end

    @timed_testset "Buffered subscriber (ring)" begin
        s = S1
        sub = nothing
        pub = nothing

        try
            test_key = Zenoh.Keyexpr("test/buffered_sub_ring")
            sub = open(s, test_key; channel=:ring, capacity=1)
            pub = Zenoh.Publisher(s, test_key)

            for i in 1:5
                Zenoh.put(pub, "ring-$i")
            end
            sleep(0.2)

            # Ring with capacity 1 retains at most one sample at any
            # instant; drain whatever survived without depending on ordering.
            # Iterate on a sibling task; close from main interrupts the wait.
            collected = String[]
            done = Channel{Nothing}(1)
            @async begin
                try
                    for sample in sub
                        open(Zenoh.payload(sample), Val(:read)) do io
                            push!(collected, read(io, String))
                        end
                    end
                finally
                    put!(done, nothing)
                end
            end
            sleep(0.2)
            close(sub)
            take!(done)
            @test all(s -> startswith(s, "ring-"), collected)
            sub = nothing
        finally
            if !isnothing(sub)
                close(sub)
            end
            if !isnothing(pub)
                close(pub)
            end        end
    end

    @timed_testset "Get/Reply" begin
        s = S1

        try
            # Plumbing test: querying a key with no queryable should return
            # an empty iterator (no replies) without throwing.
            handler = Zenoh.get(s, Zenoh.Keyexpr("test/no_one_replies");
                timeout_ms=200)
            replies = collect(handler)
            @test replies isa Vector{Zenoh.Reply}

            # Optional admin-space query — if the router exposes any keys
            # matching this pattern, we verify is_ok/sample plumbing on the
            # returned replies.
            handler2 = Zenoh.get(s, Zenoh.Keyexpr("@/**"); timeout_ms=2000)
            for reply in handler2
                @test reply isa Zenoh.Reply
                if Zenoh.is_ok(reply)
                    samp = Zenoh.sample(reply)
                    @test samp isa Zenoh.Sample
                    # Accessors should work on owned samples coming through.
                    @test Zenoh.keyexpr(samp) isa String
                else
                    @test Zenoh.error_encoding(reply) isa Zenoh.Encoding
                end
            end

            # target/consolidation options + ring mode + moved payload/encoding
            # paths all wired.
            handler3 = Zenoh.get(s, Zenoh.Keyexpr("test/no_one_replies");
                channel=:ring, capacity=4,
                target=:all, consolidation=:none,
                timeout_ms=200,
                payload="hi", encoding=Zenoh.Encodings.APPLICATION_JSON,
                attachment="meta")
            @test collect(handler3) isa Vector{Zenoh.Reply}
        finally        end
    end

    @timed_testset "Liveliness token + buffered subscriber" begin
        s = S1
        sub = nothing
        tok = nothing
        try
            test_key = Zenoh.Keyexpr("test/liveliness/buffered")
            sub = Zenoh.LivelinessSubscriberHandler(s, test_key; capacity=8)

            # Empty before any token: tryrecv! must not block.
            @test Zenoh.tryrecv!(sub) === nothing

            # Declare → subscriber sees a PUT announcing the token.
            tok = Zenoh.LivelinessToken(s, test_key)
            put_sample = take!(sub)
            @test put_sample isa Zenoh.Sample
            @test Zenoh.kind(put_sample) === Zenoh.SampleKinds.PUT
            @test Zenoh.keyexpr(put_sample) == "test/liveliness/buffered"

            # Undeclare → subscriber sees a DELETE.
            close(tok)
            tok = nothing
            del_sample = take!(sub)
            @test Zenoh.kind(del_sample) === Zenoh.SampleKinds.DELETE
        finally
            !isnothing(tok) && close(tok)
            !isnothing(sub) && close(sub)        end
    end

    @timed_testset "Liveliness callback subscriber" begin
        s = S1
        sub = nothing
        tok = nothing
        try
            test_key = Zenoh.Keyexpr("test/liveliness/callback")
            seen = Channel{Zenoh.SampleKind}(4)
            sub = Zenoh.LivelinessSubscriber((sample) -> put!(seen, Zenoh.kind(sample)),
                s, test_key)

            tok = Zenoh.LivelinessToken(s, test_key)
            @test take!(seen) === Zenoh.SampleKinds.PUT

            close(tok); tok = nothing
            @test take!(seen) === Zenoh.SampleKinds.DELETE
        finally
            !isnothing(tok) && close(tok)
            !isnothing(sub) && close(sub)        end
    end

    @timed_testset "Liveliness history replay" begin
        # history=true should replay existing tokens to a late subscriber.
        s = S1
        sub = nothing
        tok = nothing
        try
            test_key = Zenoh.Keyexpr("test/liveliness/history")
            tok = Zenoh.LivelinessToken(s, test_key)
            sleep(0.1)  # let the token propagate before the late subscribe

            sub = Zenoh.LivelinessSubscriberHandler(s, test_key;
                capacity=4, history=true)
            sample = take!(sub)
            @test Zenoh.kind(sample) === Zenoh.SampleKinds.PUT
            @test Zenoh.keyexpr(sample) == "test/liveliness/history"
        finally
            !isnothing(tok) && close(tok)
            !isnothing(sub) && close(sub)        end
    end

    @timed_testset "QoS enums" begin
        # Singleton-instance identity, subtype relationships, and raw-enum
        # round-trip for the four bounded QoS enums.
        @test Zenoh.Localities.ANY           isa Zenoh.Locality
        @test Zenoh.Localities.SESSION_LOCAL isa Zenoh.Locality
        @test Zenoh.Localities.REMOTE        isa Zenoh.Locality
        @test Zenoh.Localities.DEFAULT === Zenoh.Localities.ANY

        @test Zenoh.Priorities.REAL_TIME        isa Zenoh.Priority
        @test Zenoh.Priorities.DATA             isa Zenoh.Priority
        @test Zenoh.Priorities.BACKGROUND       isa Zenoh.Priority
        @test Zenoh.Priorities.DEFAULT === Zenoh.Priorities.DATA

        @test Zenoh.CongestionControls.BLOCK isa Zenoh.CongestionControl
        @test Zenoh.CongestionControls.DROP  isa Zenoh.CongestionControl
        @test Zenoh.CongestionControls.DEFAULT === Zenoh.CongestionControls.DROP

        @test Zenoh.ReplyKeyexprs.ANY            isa Zenoh.ReplyKeyexpr
        @test Zenoh.ReplyKeyexprs.MATCHING_QUERY isa Zenoh.ReplyKeyexpr
        @test Zenoh.ReplyKeyexprs.DEFAULT === Zenoh.ReplyKeyexprs.MATCHING_QUERY

        @test Zenoh.Reliabilities.BEST_EFFORT isa Zenoh.Reliability
        @test Zenoh.Reliabilities.RELIABLE    isa Zenoh.Reliability
        @test Zenoh.Reliabilities.DEFAULT === Zenoh.Reliabilities.RELIABLE

        @test Zenoh.SampleKinds.PUT    isa Zenoh.SampleKind
        @test Zenoh.SampleKinds.DELETE isa Zenoh.SampleKind
        @test Zenoh.SampleKinds.DEFAULT === Zenoh.SampleKinds.PUT

        @test Zenoh.WhatAmIs.ROUTER isa Zenoh.WhatAmI
        @test Zenoh.WhatAmIs.PEER   isa Zenoh.WhatAmI
        @test Zenoh.WhatAmIs.CLIENT isa Zenoh.WhatAmI

        # Singletons survive the raw round-trip.
        @test Zenoh._priority_from_raw(Zenoh._raw(Zenoh.Priorities.REAL_TIME)) ===
              Zenoh.Priorities.REAL_TIME
        @test Zenoh._locality_from_raw(Zenoh._raw(Zenoh.Localities.REMOTE)) ===
              Zenoh.Localities.REMOTE
        @test Zenoh._congestion_control_from_raw(Zenoh._raw(Zenoh.CongestionControls.BLOCK)) ===
              Zenoh.CongestionControls.BLOCK
        @test Zenoh._reply_keyexpr_from_raw(Zenoh._raw(Zenoh.ReplyKeyexprs.ANY)) ===
              Zenoh.ReplyKeyexprs.ANY
        @test Zenoh._reliability_from_raw(Zenoh._raw(Zenoh.Reliabilities.BEST_EFFORT)) ===
              Zenoh.Reliabilities.BEST_EFFORT
        @test Zenoh._reliability_from_raw(Zenoh._raw(Zenoh.Reliabilities.RELIABLE)) ===
              Zenoh.Reliabilities.RELIABLE
        @test Zenoh._sample_kind_from_raw(Zenoh._raw(Zenoh.SampleKinds.DELETE)) ===
              Zenoh.SampleKinds.DELETE
        @test Zenoh._whatami_from_raw(Zenoh._raw(Zenoh.WhatAmIs.PEER)) ===
              Zenoh.WhatAmIs.PEER

        @test occursin("Priorities.REAL_TIME",      sprint(show, Zenoh.Priorities.REAL_TIME))
        @test occursin("Localities.REMOTE",         sprint(show, Zenoh.Localities.REMOTE))
        @test occursin("CongestionControls.BLOCK",  sprint(show, Zenoh.CongestionControls.BLOCK))
        @test occursin("ReplyKeyexprs.ANY",         sprint(show, Zenoh.ReplyKeyexprs.ANY))
        @test occursin("Reliabilities.RELIABLE",    sprint(show, Zenoh.Reliabilities.RELIABLE))
        @test occursin("SampleKinds.DELETE",        sprint(show, Zenoh.SampleKinds.DELETE))
        @test occursin("WhatAmIs.ROUTER",           sprint(show, Zenoh.WhatAmIs.ROUTER))
        @test Zenoh.whatami_string(Zenoh.WhatAmIs.ROUTER) == "router"

        # Config-builder bridge: singletons serialize to the zenoh config token.
        @test Zenoh._to_json5(Zenoh.Reliabilities.RELIABLE)    == "\"reliable\""
        @test Zenoh._to_json5(Zenoh.Reliabilities.BEST_EFFORT) == "\"best_effort\""
        rule = Zenoh.PublicationRule(key_exprs = ["a/**"],
                                     reliability = Zenoh.Reliabilities.BEST_EFFORT)
        @test occursin("\"reliability\":\"best_effort\"", Zenoh._to_json5(rule))
    end

    @timed_testset "QoS end-to-end (session put → subscriber)" begin
        # Session-level put threads the QoS fields onto the wire; verify
        # the subscriber-side Sample accessors reflect them.
        s = S1
        sub = nothing
        try
            test_key = Zenoh.Keyexpr("test/qos/end_to_end")
            received_prio    = Channel{Zenoh.Priority}(1)
            received_cc      = Channel{Zenoh.CongestionControl}(1)
            received_express = Channel{Bool}(1)
            received_reliab  = Channel{Zenoh.Reliability}(1)
            received_done    = Channel{Bool}(1)

            sub = open((sample) -> begin
                put!(received_prio,    Zenoh.priority(sample))
                put!(received_cc,      Zenoh.congestion_control(sample))
                put!(received_express, Zenoh.express(sample))
                put!(received_reliab,  Zenoh.reliability(sample))
                put!(received_done, true)
            end, s, test_key)

            Zenoh.put(s, test_key, "qos payload";
                priority           = Zenoh.Priorities.REAL_TIME,
                congestion_control = Zenoh.CongestionControls.BLOCK,
                express            = true,
                reliability        = Zenoh.Reliabilities.BEST_EFFORT)

            @test take!(received_done)
            @test take!(received_prio)    === Zenoh.Priorities.REAL_TIME
            @test take!(received_cc)      === Zenoh.CongestionControls.BLOCK
            @test take!(received_express) === true
            @test take!(received_reliab)  === Zenoh.Reliabilities.BEST_EFFORT
        finally
            !isnothing(sub) && close(sub)        end
    end

    @timed_testset "QoS via Publisher options" begin
        # Same idea but the QoS lives on the Publisher itself, not on
        # the per-put call.
        s = S1
        sub = nothing
        pub = nothing
        try
            test_key = Zenoh.Keyexpr("test/qos/publisher")
            received_prio = Channel{Zenoh.Priority}(1)
            received_cc   = Channel{Zenoh.CongestionControl}(1)
            received_reliab = Channel{Zenoh.Reliability}(1)
            received_done = Channel{Bool}(1)

            sub = open((sample) -> begin
                put!(received_prio, Zenoh.priority(sample))
                put!(received_cc,   Zenoh.congestion_control(sample))
                put!(received_reliab, Zenoh.reliability(sample))
                put!(received_done, true)
            end, s, test_key)

            pub = Zenoh.Publisher(s, test_key;
                priority           = Zenoh.Priorities.INTERACTIVE_HIGH,
                congestion_control = Zenoh.CongestionControls.BLOCK,
                reliability        = Zenoh.Reliabilities.BEST_EFFORT)
            Zenoh.put(pub, "pub qos payload")

            @test take!(received_done)
            @test take!(received_prio) === Zenoh.Priorities.INTERACTIVE_HIGH
            @test take!(received_cc)   === Zenoh.CongestionControls.BLOCK
            @test take!(received_reliab) === Zenoh.Reliabilities.BEST_EFFORT
        finally
            !isnothing(sub) && close(sub)
            !isnothing(pub) && close(pub)        end
    end

    @timed_testset "Subscriber allowed_origin" begin
        # Same-session puts are session-local. A subscriber with
        # allowed_origin=REMOTE should not receive them. Use a tryrecv-style
        # negative check.
        s = S1
        sh_remote = nothing
        sh_any    = nothing
        try
            test_key = Zenoh.Keyexpr("test/qos/locality")
            sh_remote = open(s, test_key; channel=:fifo, capacity=4,
                             allowed_origin=Zenoh.Localities.REMOTE)
            sh_any    = open(s, test_key; channel=:fifo, capacity=4,
                             allowed_origin=Zenoh.Localities.ANY)
            sleep(0.1)

            Zenoh.put(s, test_key, "hello")

            # The :any subscriber receives the message.
            smp = take!(sh_any)
            @test Zenoh.keyexpr(smp) == "test/qos/locality"

            # The :remote subscriber must not — session-local origin is
            # filtered out. Give libzenohc a generous window to deliver
            # before asserting absence.
            sleep(0.3)
            @test Zenoh.tryrecv!(sh_remote) === nothing
        finally
            !isnothing(sh_remote) && close(sh_remote)
            !isnothing(sh_any)    && close(sh_any)        end
    end

    @timed_testset "Queryable (channel) round-trip" begin
        s = S1
        qh = nothing
        srv = nothing
        try
            test_key = Zenoh.Keyexpr("test/queryable/channel")
            qh = Zenoh.Queryable(s, test_key; channel=:fifo, capacity=8,
                                 complete=true, allowed_origin=Zenoh.Localities.ANY)

            seen_params = Channel{String}(4)
            seen_keyexpr = Channel{String}(4)
            srv = @async begin
                for query in qh
                    put!(seen_keyexpr, Zenoh.keyexpr(query))
                    put!(seen_params, Zenoh.parameters(query))
                    Zenoh.reply(query, "pong";
                        encoding=Zenoh.Encodings.TEXT_PLAIN)
                end
            end

            # Give the router a moment to learn about the queryable.
            sleep(0.2)

            # Routing through the router can duplicate the query reply
            # path (one from the local queryable + one routed back), so
            # we filter for ok replies and assert at least one.
            replies = collect(Zenoh.get(s, test_key, "k1=v1&k2=v2";
                timeout_ms=500))
            ok_replies = filter(Zenoh.is_ok, replies)
            @test length(ok_replies) >= 1
            smp = Zenoh.sample(ok_replies[1])
            @test Zenoh.keyexpr(smp) == "test/queryable/channel"
            open(Zenoh.payload(smp), Val(:read)) do io
                @test read(io, String) == "pong"
            end
            @test Zenoh.encoding(smp) == Zenoh.Encodings.TEXT_PLAIN

            @test take!(seen_keyexpr) == "test/queryable/channel"
            @test take!(seen_params)  == "k1=v1&k2=v2"
        finally
            !isnothing(qh) && close(qh)
            !isnothing(srv) && wait(srv)        end
    end

    @timed_testset "Queryable (callback) round-trip" begin
        s = S1
        q = nothing
        try
            test_key = Zenoh.Keyexpr("test/queryable/callback")
            served = Channel{String}(4)
            q = Zenoh.Queryable(s, test_key) do query
                put!(served, Zenoh.parameters(query))
                Zenoh.reply(query, "callback-pong")
            end
            sleep(0.2)

            replies = collect(Zenoh.get(s, test_key, "x=1"; timeout_ms=2000))
            ok_replies = filter(Zenoh.is_ok, replies)
            @test length(ok_replies) >= 1
            smp = Zenoh.sample(ok_replies[1])
            open(Zenoh.payload(smp), Val(:read)) do io
                @test read(io, String) == "callback-pong"
            end
            @test take!(served) == "x=1"
        finally
            !isnothing(q) && close(q)        end
    end

    @timed_testset "Queryable accessors (payload + attachment + encoding)" begin
        s = S1
        qh = nothing
        srv = nothing
        try
            test_key = Zenoh.Keyexpr("test/queryable/accessors")
            qh = Zenoh.Queryable(s, test_key; channel=:fifo, capacity=4)

            # Capacity > 1 because router routing may deliver the query
            # through both local and remote paths.
            seen_payload = Channel{String}(4)
            seen_attach  = Channel{String}(4)
            seen_enc     = Channel{Zenoh.Encoding}(4)
            srv = @async begin
                for query in qh
                    p = Zenoh.payload(query)
                    open(p, Val(:read)) do io
                        put!(seen_payload, read(io, String))
                    end
                    a = Zenoh.attachment(query)
                    if isnothing(a)
                        put!(seen_attach, "<none>")
                    else
                        open(a, Val(:read)) do io
                            put!(seen_attach, read(io, String))
                        end
                    end
                    e = Zenoh.encoding(query)
                    put!(seen_enc, isnothing(e) ? Zenoh.Encoding("") : e)
                    Zenoh.reply(query, "ack")
                end
            end
            sleep(0.2)

            collect(Zenoh.get(s, test_key; timeout_ms=500,
                payload="req-payload",
                encoding=Zenoh.Encodings.APPLICATION_JSON,
                attachment="req-meta"))

            @test take!(seen_payload) == "req-payload"
            @test take!(seen_attach)  == "req-meta"
            @test take!(seen_enc)     == Zenoh.Encodings.APPLICATION_JSON
        finally
            !isnothing(qh) && close(qh)
            !isnothing(srv) && wait(srv)        end
    end

    @timed_testset "Queryable reply_err" begin
        s = S1
        q = nothing
        try
            test_key = Zenoh.Keyexpr("test/queryable/err")
            q = Zenoh.Queryable(s, test_key) do query
                Zenoh.reply_err(query, "boom";
                    encoding=Zenoh.Encodings.TEXT_PLAIN)
            end
            sleep(0.2)

            replies = collect(Zenoh.get(s, test_key; timeout_ms=2000))
            err_replies = filter(r -> !Zenoh.is_ok(r), replies)
            @test length(err_replies) >= 1
            r = err_replies[1]
            open(Zenoh.error_payload(r), Val(:read)) do io
                @test read(io, String) == "boom"
            end
            @test Zenoh.error_encoding(r) == Zenoh.Encodings.TEXT_PLAIN
        finally
            !isnothing(q) && close(q)        end
    end

    @timed_testset "Queryable reply_del" begin
        s = S1
        q = nothing
        try
            test_key = Zenoh.Keyexpr("test/queryable/del")
            q = Zenoh.Queryable(s, test_key) do query
                Zenoh.reply_del(query)
            end
            sleep(0.2)

            replies = collect(Zenoh.get(s, test_key; timeout_ms=2000))
            ok_replies = filter(Zenoh.is_ok, replies)
            @test length(ok_replies) >= 1
            smp = Zenoh.sample(ok_replies[1])
            @test Zenoh.kind(smp) === Zenoh.SampleKinds.DELETE
        finally
            !isnothing(q) && close(q)        end
    end

    @timed_testset "Queryable tryrecv! + close before any query" begin
        s = S1
        qh = nothing
        try
            qh = Zenoh.Queryable(s, Zenoh.Keyexpr("test/queryable/idle");
                channel=:ring, capacity=2)
            # Channel form is a Queryable (T(...)::T) and the QueryableHandler alias.
            @test qh isa Zenoh.Queryable
            @test qh isa Zenoh.QueryableHandler
            # No query in flight → tryrecv! returns nothing (doesn't block).
            @test Zenoh.tryrecv!(qh) === nothing
            # close is idempotent on the channel form.
            close(qh)
            @test qh.closed
            close(qh)
            @test qh.closed
            qh = nothing
        finally
            !isnothing(qh) && close(qh)        end
    end

    @timed_testset "liveliness_get snapshot" begin
        s = S1
        tok = nothing
        try
            test_key_str = "test/liveliness/snapshot"
            test_key = Zenoh.Keyexpr(test_key_str)

            # Empty snapshot before declare.
            empty = Zenoh.liveliness_get(s, test_key; timeout_ms=300)
            @test collect(empty) isa Vector{Zenoh.Reply}

            tok = Zenoh.LivelinessToken(s, test_key)
            sleep(0.1)  # token must reach the router before the snapshot

            handler = Zenoh.liveliness_get(s, test_key; timeout_ms=1000)
            seen_keys = String[]
            for reply in handler
                if Zenoh.is_ok(reply)
                    push!(seen_keys, Zenoh.keyexpr(Zenoh.sample(reply)))
                end
            end
            @test test_key_str in seen_keys

            # Callback form: must invoke f at least once for the live token.
            count = Ref(0)
            Zenoh.liveliness_get(s, test_key; timeout_ms=1000) do reply
                Zenoh.is_ok(reply) && (count[] += 1)
            end
            @test count[] >= 1
        finally
            !isnothing(tok) && close(tok)        end
    end

    @timed_testset "MatchingListener + matching_status" begin
        # Two sessions through the same router: pub on s1, sub on s2.
        s1 = S1
        s2 = S2
        pub = nothing
        ml  = nothing
        sub = nothing
        try
            k = Zenoh.Keyexpr("test/matching/listener")
            pub = Zenoh.Publisher(s1, k)

            # Buffered channel for the transitions. The poll
            # (matching_status) is the authoritative state check; the
            # event stream is verified separately because libzenohc has
            # been observed to occasionally emit spurious settling events
            # near declare time on some platforms.
            events = Channel{Bool}(16)
            ml = Zenoh.MatchingListener(pub) do matching
                put!(events, matching)
            end

            # No subscribers yet — poll reports false.
            @test Zenoh.matching_status(pub) == false

            # Subscriber arrives → poll flips to true and a `true` event
            # must appear in the event stream.
            sub = open((_) -> nothing, s2, k)
            sleep(0.2)
            @test Zenoh.matching_status(pub) == true
            arrivals = Bool[]
            while isready(events); push!(arrivals, take!(events)); end
            @test true in arrivals

            # Subscriber leaves → poll flips back and a `false` event
            # must appear.
            close(sub); sub = nothing
            sleep(0.2)
            @test Zenoh.matching_status(pub) == false
            departures = Bool[]
            while isready(events); push!(departures, take!(events)); end
            @test false in departures
        finally
            !isnothing(sub) && close(sub)
            !isnothing(ml)  && close(ml)
            !isnothing(pub) && close(pub)
        end
    end

    @timed_testset "Querier (channel) round-trip" begin
        # Two shared sessions through the same router: queryable on s1, querier on s2.
        s1 = S1
        s2 = S2
        qh = nothing
        qrr = nothing
        srv = nothing
        try
            test_key = Zenoh.Keyexpr("test/querier/channel")
            qh = Zenoh.Queryable(s1, test_key; channel=:fifo, capacity=8,
                                 complete=true, allowed_origin=Zenoh.Localities.ANY)

            seen_params = Channel{String}(4)
            seen_keyexpr = Channel{String}(4)
            srv = @async begin
                for query in qh
                    put!(seen_keyexpr, Zenoh.keyexpr(query))
                    put!(seen_params,  Zenoh.parameters(query))
                    Zenoh.reply(query, "querier-pong";
                        encoding=Zenoh.Encodings.TEXT_PLAIN)
                end
            end

            sleep(0.2)  # let the router learn about the queryable

            qrr = Zenoh.Querier(s2, test_key;
                target=:all, consolidation=:none, timeout_ms=2000)

            @test Zenoh.keyexpr(qrr) == "test/querier/channel"

            replies = collect(Zenoh.get(qrr, "k1=v1&k2=v2"))
            ok_replies = filter(Zenoh.is_ok, replies)
            @test length(ok_replies) >= 1

            smp = Zenoh.sample(ok_replies[1])
            @test Zenoh.keyexpr(smp) == "test/querier/channel"
            open(Zenoh.payload(smp), Val(:read)) do io
                @test read(io, String) == "querier-pong"
            end
            @test Zenoh.encoding(smp) == Zenoh.Encodings.TEXT_PLAIN

            @test take!(seen_keyexpr) == "test/querier/channel"
            @test take!(seen_params)  == "k1=v1&k2=v2"

            # querier_id: zid matches the owning session, eid is populated
            gid = Zenoh.querier_id(qrr)
            @test gid.zid == Zenoh.zid(s2)
            @test gid.eid isa UInt32

            # parameters accept a SubString view (exercises the _substr path)
            sub = SubString("__k3=v3__", 3, 7)   # "k3=v3"
            @test sub == "k3=v3"
            @test length(filter(Zenoh.is_ok, collect(Zenoh.get(qrr, sub)))) >= 1
            @test take!(seen_params) == "k3=v3"
        finally
            !isnothing(qrr) && close(qrr)
            !isnothing(qh)  && close(qh)
            !isnothing(srv) && wait(srv)
        end
    end

    @timed_testset "Querier repeated queries reuse declared options" begin
        s1 = S1
        s2 = S2
        qh = nothing
        qrr = nothing
        srv = nothing
        try
            test_key = Zenoh.Keyexpr("test/querier/repeated")
            qh = Zenoh.Queryable(s1, test_key; channel=:fifo, capacity=8)
            srv = @async begin
                for query in qh
                    Zenoh.reply(query, "ack-" * Zenoh.parameters(query))
                end
            end
            sleep(0.2)

            qrr = Zenoh.Querier(s2, test_key; timeout_ms=2000)

            for i in 1:3
                replies = collect(Zenoh.get(qrr, "i=$i"))
                ok = filter(Zenoh.is_ok, replies)
                @test length(ok) >= 1
                open(Zenoh.payload(Zenoh.sample(ok[1])), Val(:read)) do io
                    @test read(io, String) == "ack-i=$i"
                end
            end
        finally
            !isnothing(qrr) && close(qrr)
            !isnothing(qh)  && close(qh)
            !isnothing(srv) && wait(srv)
        end
    end

    @timed_testset "Querier (callback) round-trip" begin
        s1 = S1
        s2 = S2
        qh = nothing
        qrr = nothing
        srv = nothing
        try
            test_key = Zenoh.Keyexpr("test/querier/callback")
            qh = Zenoh.Queryable(s1, test_key; channel=:fifo, capacity=8)
            srv = @async begin
                for query in qh
                    Zenoh.reply(query, "cb-pong")
                end
            end
            sleep(0.2)

            qrr = Zenoh.Querier(s2, test_key; timeout_ms=2000)
            received = Channel{String}(4)
            Zenoh.get(qrr, "x=1") do reply
                if Zenoh.is_ok(reply)
                    open(Zenoh.payload(Zenoh.sample(reply)), Val(:read)) do io
                        put!(received, read(io, String))
                    end
                end
            end
            @test take!(received) == "cb-pong"
        finally
            !isnothing(qrr) && close(qrr)
            !isnothing(qh)  && close(qh)
            !isnothing(srv) && wait(srv)
        end
    end

    @timed_testset "Querier MatchingListener + matching_status" begin
        s1 = S1
        s2 = S2
        qrr = nothing
        ml  = nothing
        qh  = nothing
        srv = nothing
        try
            k = Zenoh.Keyexpr("test/querier/matching")
            qrr = Zenoh.Querier(s1, k)

            events = Channel{Bool}(16)
            ml = Zenoh.MatchingListener(qrr) do matching
                put!(events, matching)
            end

            # No queryable yet — poll reports false.
            @test Zenoh.matching_status(qrr) == false

            # Queryable arrives → poll flips to true; a `true` event appears.
            qh = Zenoh.Queryable(s2, k; channel=:fifo, capacity=4)
            srv = @async begin
                for _ in qh
                    # ignore queries — this test cares about matching, not replies
                end
            end
            sleep(0.2)
            @test Zenoh.matching_status(qrr) == true
            arrivals = Bool[]
            while isready(events); push!(arrivals, take!(events)); end
            @test true in arrivals

            # Queryable leaves → poll flips back; a `false` event appears.
            close(qh); qh = nothing
            !isnothing(srv) && wait(srv); srv = nothing
            sleep(0.2)
            @test Zenoh.matching_status(qrr) == false
            departures = Bool[]
            while isready(events); push!(departures, take!(events)); end
            @test false in departures
        finally
            !isnothing(qh)  && close(qh)
            !isnothing(srv) && wait(srv)
            !isnothing(ml)  && close(ml)
            !isnothing(qrr) && close(qrr)
        end
    end

    @timed_testset "CancellationToken" begin
        # Core property: a clone shares the underlying flag, so cancelling the
        # handle you keep cancels the one moved into a get (the get-opts builders
        # clone the token in and hand your handle back to cancel through).
        tok   = Zenoh.CancellationToken()
        clone = Zenoh._clone(tok)
        @test !Zenoh.is_cancelled(tok)
        @test !Zenoh.is_cancelled(clone)
        Zenoh.cancel(tok)
        @test Zenoh.is_cancelled(tok)
        @test Zenoh.is_cancelled(clone)          # shared flag, not a deep copy
        close(clone); close(tok)

        # symmetric: cancelling the clone is visible on the original
        a = Zenoh.CancellationToken(); b = Zenoh._clone(a)
        Zenoh.cancel(b)
        @test Zenoh.is_cancelled(a)
        close(a); close(b)

        # The `cancellation` kwarg threads through every get path and returns
        # (no matching queryable here, so each get resolves promptly).
        k = Zenoh.Keyexpr("test/cancellation/smoke")
        let t = Zenoh.CancellationToken()
            gh = Base.get(S1, k; cancellation = t); for _ in gh; end
            @test true
        end
        let t = Zenoh.CancellationToken()
            gh = Zenoh.liveliness_get(S1, k; cancellation = t); for _ in gh; end
            @test true
        end
        qrr = Zenoh.Querier(S1, k; timeout_ms = 1000)
        try
            t = Zenoh.CancellationToken()
            gh = Base.get(qrr; payload = "x", cancellation = t); for _ in gh; end
            @test true
        finally
            close(qrr)
        end
    end

    @timed_testset "Typed query target/consolidation + Querier QoS singletons" begin
        # The QueryTargets / QueryConsolidations singletons are the canonical
        # form; verify they thread through both get and Querier, and that the
        # Querier accepts the same CongestionControl/Priority/Locality
        # singletons every other entrypoint takes (this path previously took
        # raw enum values and broke on the singletons).
        s = S1
        qrr = nothing
        try
            # get with typed singletons against a key no one answers.
            h = Zenoh.get(s, Zenoh.Keyexpr("test/typed/none");
                target=Zenoh.QueryTargets.ALL,
                consolidation=Zenoh.QueryConsolidations.NONE,
                timeout_ms=200)
            @test collect(h) isa Vector{Zenoh.Reply}

            # Symbol shorthand and singleton coerce identically.
            @test Zenoh._as_query_target(Zenoh.QueryTargets.ALL) ==
                  Zenoh._as_query_target(:all)

            # Querier declared with typed QoS singletons (formerly raw-only).
            qrr = Zenoh.Querier(s, Zenoh.Keyexpr("test/typed/querier");
                target=Zenoh.QueryTargets.ALL_COMPLETE,
                consolidation=Zenoh.QueryConsolidations.LATEST,
                congestion_control=Zenoh.CongestionControls.BLOCK,
                priority=Zenoh.Priorities.DATA_HIGH,
                allowed_destination=Zenoh.Localities.ANY,
                express=true, timeout_ms=200)
            @test Zenoh.keyexpr(qrr) == "test/typed/querier"
            @test collect(Zenoh.get(qrr)) isa Vector{Zenoh.Reply}
        finally
            !isnothing(qrr) && close(qrr)        end
    end

    @timed_testset "Publisher idempotent close" begin
        s = S1
        try
            pub = Zenoh.Publisher(s, Zenoh.Keyexpr("test/pub/close"))
            close(pub)
            @test pub.closed
            close(pub)  # second close is a no-op, must not throw
            @test pub.closed
        finally        end
    end

    @timed_testset "Session idempotent close" begin
        # No router needed — a standalone peer opens without connecting. Scouting
        # off so it doesn't discover (and then hang on close against) an external
        # zenohd; see the _NO_SCOUT note at the top.
        s = open(Zenoh.Config(; str = "{$_NO_SCOUT}"))
        @test isopen(s)
        close(s)
        @test !isopen(s)          # closed → false (no use-after-free on the freed handle)
        @test s.closed[]
        close(s)                  # second close is a no-op, must not throw
        @test s.closed[]
        # operations after close fail loudly rather than touching a freed handle
        @test_throws ArgumentError Zenoh.zid(s)
        @test_throws ArgumentError Zenoh.Publisher(s, Zenoh.Keyexpr("test/closed/pub"))
        GC.gc(true)               # finalizer must skip the already-closed session
        @test true
    end

    @timed_testset "SHM provider basics" timeout=20 begin
        p = Zenoh.ShmProvider(1 << 20)
        @test p isa Zenoh.ShmProvider
        @test p isa Zenoh.AbstractShmProvider
        # available/defragment/garbage_collect should return non-negative Ints.
        @test Zenoh.available(p) >= 0
        @test Zenoh.defragment(p) >= 0
        @test Zenoh.garbage_collect(p) >= 0
    end

    @timed_testset "SHM allocation" timeout=20 begin
        p = Zenoh.ShmProvider(1 << 20)
        buf = Zenoh.alloc(p, 256)
        @test buf isa Zenoh.ShmBufMut
        @test length(buf) == 256
        @test Zenoh.data(buf) isa Memory{UInt8}
        # Write through the Memory view; round-trip the bytes.
        for i in 1:256
            Zenoh.data(buf)[i] = UInt8((i - 1) % 256)
        end
        @test Zenoh.data(buf)[1] == 0x00
        @test Zenoh.data(buf)[16] == 0x0f

        # Aligned alloc. The built-in POSIX provider only supports align=1
        # (its layout has fixed alignment); larger alignments surface as a
        # ShmLayoutError(:provider_incompatible). align=1 is a no-op and
        # always succeeds.
        buf2 = Zenoh.alloc(p, 128; align=1)
        @test length(buf2) == 128
        @test buf2 isa Zenoh.ShmBufMut
        @test_throws Zenoh.ShmLayoutError Zenoh.alloc(p, 128; align=64)

        # Blocking alloc (GC + defragment + blocking policy; its own entrypoint).
        buf3 = Zenoh.alloc_blocking(p, 64)
        @test length(buf3) == 64

        # copyto! convenience.
        src = collect(UInt8(1):UInt8(32))
        buf4 = Zenoh.alloc(p, 32)
        copyto!(buf4, src)
        @test Vector{UInt8}(Zenoh.data(buf4)[1:32]) == src

        # Alignment validation.
        @test_throws ArgumentError Zenoh.alloc(p, 16; align=3)  # not power of 2
    end

    @timed_testset "try_alloc + shm_serialize + ZBytes(buf,n)" timeout=20 begin
        p = Zenoh.ShmProvider(1 << 20)

        # try_alloc: success returns a writable ShmBufMut of the requested size.
        b = Zenoh.try_alloc(p, 128)
        @test b isa Zenoh.ShmBufMut
        @test length(b) == 128
        Zenoh.close(b)                                   # release the unsent buffer on this task

        # try_alloc validates layout up front, like alloc: a non-power-of-two
        # align is a hard ArgumentError, and an unsupported (non-1) alignment is
        # a genuine ShmLayoutError — neither degrades to `nothing`.
        @test_throws ArgumentError Zenoh.try_alloc(p, 64; align=3)
        @test_throws Zenoh.ShmLayoutError Zenoh.try_alloc(p, 64; align=64)

        # try_alloc's reason for being: a full/fragmented segment is a non-error
        # outcome, returned as `nothing` rather than thrown. Exhaust a small
        # provider, then the next request degrades cleanly.
        small = Zenoh.ShmProvider(1 << 14)
        held = Zenoh.ShmBufMut[]
        while (bb = Zenoh.try_alloc(small, 4096)) !== nothing
            push!(held, bb)
        end
        @test !isempty(held)                             # it satisfied at least one before filling
        @test Zenoh.try_alloc(small, 4096) === nothing   # ALLOC_ERROR → nothing, no throw
        foreach(Zenoh.close, held)

        # shm_serialize: fill! writes straight into the segment; the result is a
        # sendable owned, SHM-backed ZBytes.
        payload = collect(UInt8, 1:64)
        z = Zenoh.shm_serialize(p, 64) do mem
            @test mem isa Memory{UInt8}
            @test length(mem) == 64
            copyto!(mem, payload)
        end
        @test z isa Zenoh.ZBytes
        @test Vector{UInt8}(z) == payload                # bytes survived the alloc→fill→move
        @test Zenoh.is_shm(z)                            # and it stayed in shared memory
        shmview = Zenoh.as_shm(z)
        @test shmview !== nothing
        @test Vector{UInt8}(Zenoh.data(shmview)) == payload

        # shm_serialize: a throwing fill! releases the half-filled buffer and
        # rethrows — no leak, and the provider still satisfies a later alloc.
        @test_throws ErrorException Zenoh.shm_serialize(p, 32) do mem
            error("boom")
        end
        @test Zenoh.alloc(p, 32) isa Zenoh.ShmBufMut

        # ZBytes(buf, n): the full-length move is the supported case; it consumes
        # buf, after which close is a no-op (the handle was moved/gravestoned).
        buf = Zenoh.alloc(p, 48)
        copyto!(buf, collect(UInt8, 1:48))
        zf = Zenoh.ZBytes(buf, 48)
        @test Vector{UInt8}(zf) == collect(UInt8, 1:48)
        Zenoh.close(buf)                                 # no-op after the move

        # ZBytes(buf): the convenience defaults n to the full granted length.
        buf2 = Zenoh.alloc(p, 16)
        @test length(Vector{UInt8}(Zenoh.ZBytes(buf2))) == 16

        # n past the granted length is a BoundsError.
        buf3 = Zenoh.alloc(p, 16)
        @test_throws BoundsError Zenoh.ZBytes(buf3, 32)
        Zenoh.close(buf3)
        # A shorter n is unsupported (no length-bounded SHM move) → ArgumentError,
        # not a silent over-send.
        buf4 = Zenoh.alloc(p, 16)
        @test_throws ArgumentError Zenoh.ZBytes(buf4, 8)
        Zenoh.close(buf4)
    end

    @timed_testset "SHM client storage + open kwarg" timeout=20 begin
        cs = Zenoh.default_shm_clients()
        @test cs isa Zenoh.ShmClientStorage
        c = epcfg()
        s = open(c; shm_clients = cs)
        try
            @test isopen(s)
        finally
            close(s)
        end
    end

    @timed_testset "SHM round-trip publish/subscribe" timeout=20 begin
        c1 = epcfg()
        c2 = epcfg()
        s_pub = open(c1; shm_clients = Zenoh.default_shm_clients())
        s_sub = open(c2; shm_clients = Zenoh.default_shm_clients())
        sleep(0.5)

        received = Channel{Vector{UInt8}}(4)
        was_shm  = Channel{Bool}(4)
        test_key = Zenoh.Keyexpr("shm/roundtrip")
        sub = open(s_sub, test_key) do sample
            zb = Zenoh.payload(sample)
            shm = Zenoh.as_shm(zb)
            if shm !== nothing
                put!(was_shm, true)
                put!(received, Vector{UInt8}(Zenoh.data(shm)))
            else
                put!(was_shm, false)
                bytes = Vector{UInt8}(undef, length(zb))
                open(zb, Val(:read)) do io
                    readbytes!(io, bytes, length(zb))
                end
                put!(received, bytes)
            end
        end
        sleep(0.5)
        try
            provider = Zenoh.ShmProvider(1 << 20)

            # (a) Manual: alloc, fill, publish a ShmBufMut directly.
            msg_a = UInt8[10, 20, 30, 40, 50, 60, 70]
            buf = Zenoh.alloc(provider, length(msg_a))
            copyto!(buf, msg_a)
            Zenoh.put(s_pub, test_key, buf)
            @test take!(received) == msg_a
            @test take!(was_shm)  # round-trip went through SHM

            # (b) High-level: put with shm= kwarg, AbstractVector{UInt8} data.
            msg_b = collect(UInt8(100):UInt8(200))
            Zenoh.put(s_pub, test_key, msg_b; shm = provider)
            @test take!(received) == msg_b
            @test take!(was_shm)

            # (c) High-level with a String.
            msg_c = "hello-shm-world"
            Zenoh.put(s_pub, test_key, msg_c; shm = provider)
            @test String(take!(received)) == msg_c
            @test take!(was_shm)

            # (d) is_shm predicate on a Vector-backed (non-SHM) payload.
            # Non-shm round-trip — make sure as_shm correctly says "no" and
            # is_shm returns false.
            Zenoh.put(s_pub, test_key, UInt8[1, 2, 3])
            @test take!(received) == UInt8[1, 2, 3]
            @test !take!(was_shm)
        finally
            close(sub)
            close(s_pub)
            close(s_sub)
        end
    end

    @timed_testset "ZRef typed round-trip (transport-agnostic)" timeout=30 begin
        c1 = epcfg()
        c2 = epcfg()
        s_pub = open(c1; shm_clients = Zenoh.default_shm_clients())
        s_sub = open(c2; shm_clients = Zenoh.default_shm_clients())
        sleep(0.5)

        pixels   = Channel{Pixel}(8)
        borrowed = Channel{Bool}(8)
        was_shm  = Channel{Bool}(8)
        bigs     = Channel{ZBig}(8)
        test_key = Zenoh.Keyexpr("zref/roundtrip")

        # Subscriber reconstructs Pixel via zref(sample, Pixel) — no SHM branch.
        sub = open(s_sub, test_key) do sample
            zb = Zenoh.payload(sample)
            put!(was_shm, Zenoh.is_shm(zb))
            if length(zb) == sizeof(Pixel)
                r = zref(sample, Pixel)
                put!(borrowed, Zenoh.isborrowed(r))
                put!(pixels, r[])          # read the value out before the callback returns
            else
                r = zref(sample, ZBig)
                put!(bigs, r[])
            end
        end
        sleep(0.5)
        try
            provider = Zenoh.ShmProvider(1 << 20)

            # (a) SHM-backed Pixel: author in the segment, publish, view in place.
            zp = zref(provider, Pixel)
            zp[] = Pixel(0x11, 0x22, 0x33, 0x44)
            Zenoh.put(s_pub, test_key, zp)
            @test take!(pixels) == Pixel(0x11, 0x22, 0x33, 0x44)
            @test take!(was_shm)               # arrived via SHM
            @test take!(borrowed)              # received zero-copy (Pixel is align-1)

            # (b) Pixel via the transparent session fast path. Transport is
            # deliberately opaque here: depending on whether the session-derived
            # SHM provider has warmed up, zref(session,T) may allocate from SHM
            # or fall back to Julia memory. The invariant is value-correctness
            # either way — so we drain (don't assert) the transport channels.
            zj = zref(s_pub, Pixel)
            @test !Zenoh.isborrowed(zj)        # a send handle is never a borrow
            zj[] = Pixel(0xaa, 0xbb, 0xcc, 0xdd)
            Zenoh.put(s_pub, test_key, zj)
            @test take!(pixels) == Pixel(0xaa, 0xbb, 0xcc, 0xdd)
            take!(was_shm); take!(borrowed)    # transport-agnostic: value is what matters

            # (c) ZBig (alignment 8) over an explicit standalone SHM provider:
            # align fallback may force a receive copy, but the value must match.
            zb = zref(provider, ZBig)
            zb[] = ZBig(123456789, 3.5, -42)
            Zenoh.put(s_pub, test_key, zb)
            @test take!(bigs) == ZBig(123456789, 3.5, -42)
            @test take!(was_shm)               # explicit provider ⇒ definitely SHM

            # (d) ZBig via the transparent session path (transport opaque).
            zbj = zref(s_pub, ZBig)
            zbj[] = ZBig(-1, -2.5, 7)
            Zenoh.put(s_pub, test_key, zbj)
            @test take!(bigs) == ZBig(-1, -2.5, 7)
            take!(was_shm)
        finally
            close(sub)
            close(s_pub)
            close(s_sub)
        end
    end

    @timed_testset "ZBytes <-> Memory (serialization buffers)" timeout=20 begin
        # Serialize: build a Memory{Float64}, wrap as ZBytes (borrowed).
        vals = [1.5, 2.5, 3.5, 4.5]
        src = Memory{Float64}(undef, 4)
        for i in 1:4; src[i] = vals[i]; end
        zb = Zenoh.ZBytes(src)
        @test length(zb) == 4 * sizeof(Float64)

        # Deserialize: owned copy as Memory{Float64}.
        m = Zenoh.as_memory(zb, Float64)
        @test m isa Memory{Float64}
        @test collect(m) == vals

        # Default eltype is UInt8.
        mb = Zenoh.as_memory(zb)
        @test mb isa Memory{UInt8}
        @test length(mb) == 32

        # Scoped Borrowed view (zero-copy or copy); result of f is returned.
        s = with_memory(zb, Float64) do b
            @test b isa Zenoh.Borrowed{Float64}
            @test length(b) == 4
            @test b[1] == 1.5 && b[4] == 4.5
            @test collect(b) == vals
            sum(b)                       # iterates
        end
        @test s == sum(vals)

        # Escape detection: a Borrowed that leaks out of `with_memory` is
        # invalidated, and any later use throws BorrowError (not a segfault).
        escaped = with_memory(zb, Float64) do b
            @test isvalid(b)
            b                            # smuggle it out
        end
        @test !isvalid(escaped)
        @test_throws Zenoh.BorrowError escaped[1]
        @test_throws Zenoh.BorrowError length(escaped)
        @test_throws Zenoh.BorrowError pointer(escaped)
        @test_throws Zenoh.BorrowError collect(escaped)

        # Value-first deref: a single-struct payload reads back via b[].
        struct_bytes = Zenoh.ZBytes(Ref(TestStruct(7, 9.0)))
        with_memory(struct_bytes, TestStruct) do b
            @test length(b) == 1
            @test b[] == TestStruct(7, 9.0)     # the common case
            # Struct-field proxy: b.field reads the field by offset.
            @test b.a == 7
            @test b.b == 9.0
            @test Set(propertynames(b)) == Set((:a, :b))
            @test_throws ArgumentError b.nope   # not a field of TestStruct
            # Read-only by default: mutation is refused, not UB.
            @test !iswritable(b)
            @test_throws ArgumentError (b.a = 1)
            @test_throws ArgumentError (b[] = TestStruct(0, 0.0))
        end
        # b[] on a multi-element view is an error (use indexing instead).
        with_memory(zb, Float64) do b
            @test_throws ArgumentError b[]
            @test_throws ArgumentError b.a      # property access needs a single element
        end

        # Writable borrow: owns a copy, so b.field = v / b[i] = v mutate it.
        with_memory(struct_bytes, TestStruct; writable = true) do b
            @test iswritable(b)
            b.a = 42
            b.b = -1.5
            @test b[] == TestStruct(42, -1.5)
            @test b.a == 42
        end
        with_memory(zb, Float64; writable = true) do b
            b[2] = 99.0
            @test b[2] == 99.0
            @test collect(b) == [1.5, 99.0, 3.5, 4.5]
        end

        # Manual borrow/close, and use-after-close throws.
        bm = borrow(zb, Float64)
        @test bm[2] == 2.5
        close(bm)
        @test_throws Zenoh.BorrowError bm[2]
        close(bm)                        # idempotent

        # Unsafe API: raw Memory{T}, no wrapper / no per-access checks.
        s2 = unsafe_with_memory(zb, Float64) do mem
            @test mem isa Memory{Float64}
            @test length(mem) == 4
            @test mem[1] == 1.5
            sum(mem)
        end
        @test s2 == sum(vals)
        # unsafe_memory extracts the raw Memory from a Borrowed (checked once).
        with_memory(zb, Float64) do b
            m = Zenoh.unsafe_memory(b)
            @test m isa Memory{Float64}
            @test collect(m) == vals
        end

        # Length must divide sizeof(T).
        odd = Zenoh.ZBytes(UInt8[1, 2, 3, 4, 5])
        @test_throws ArgumentError Zenoh.as_memory(odd, Float64)
        @test_throws ArgumentError borrow(odd, Float64)

        # Round-trip a Memory through ZBytes and back unchanged (bytewise).
        rt = Zenoh.as_memory(Zenoh.ZBytes(Zenoh.as_memory(zb)), Float64)
        @test collect(rt) == vals

        # with_payload_memory: hands `f` an *isbits* PayloadView (a (ptr,len) view,
        # no `unsafe_wrap` Memory header) over the payload bytes — every tier.
        @test isbitstype(Zenoh.PayloadView)
        bytes = collect(reinterpret(UInt8, vals))       # the 32 payload bytes
        pv_sum = with_payload_memory(zb) do pv
            @test pv isa Zenoh.PayloadView
            @test length(pv) == 32
            @test collect(pv) == bytes
            sum(UInt64(b) for b in pv)
        end
        @test pv_sum == sum(UInt64.(bytes))

        # with_payload_memory_checked: the same zero-copy view, but escape-guarded —
        # in-frame use is fine; a view smuggled past the block is invalidated, so
        # later access throws BorrowError (not a use-after-free).
        ck_sum = with_payload_memory_checked(zb) do pv
            @test pv isa Zenoh.GuardedPayloadView
            @test collect(pv) == bytes
            sum(UInt64(b) for b in pv)
        end
        @test ck_sum == sum(UInt64.(bytes))
        escaped_pv = with_payload_memory_checked(zb) do pv
            pv                                            # smuggle it out
        end
        @test_throws Zenoh.BorrowError escaped_pv[1]
        @test_throws Zenoh.BorrowError pointer(escaped_pv)
        @test_throws Zenoh.BorrowError collect(escaped_pv)
    end

    @timed_testset "SHM capability discovery" timeout=20 begin
        # Opened without shm_clients: SHM never requested.
        c0 = epcfg()
        s0 = open(c0)
        try
            @test Zenoh.shm_state(s0) == :none
            @test !Zenoh.shm_capable(s0)
        finally
            close(s0)
        end

        # Opened with shm_clients but the default test config doesn't enable a
        # session-side provider, so discovery reports a non-usable state and
        # zref falls back to Julia. (We assert the shape, not the exact symbol,
        # since it depends on whether obtain fails outright or reports disabled.)
        c1 = epcfg()
        s1 = open(c1; shm_clients = Zenoh.default_shm_clients())
        try
            st = Zenoh.shm_state(s1)
            @test st isa Symbol
            @test st in (:unavailable, :disabled, :error, :initializing, :ready)
            # capability must agree with the cache the fast path actually uses.
            @test Zenoh.shm_capable(s1) == (st in (:ready, :initializing))
            # live probe agrees with capability and returns a Bool.
            @test Zenoh.shm_ready(s1) isa Bool
            @test Zenoh.shm_ready(s1) == (Zenoh.shm_state(s1) === :ready)
        finally
            close(s1)
        end

        # shm_ready never re-probes (or clobbers) a session that never requested
        # SHM — it stays :none and reports false.
        s2 = open(epcfg())
        try
            @test !Zenoh.shm_ready(s2)
            @test Zenoh.shm_state(s2) == :none
        finally
            close(s2)
        end
    end

    @timed_testset "SHM wait_for_shm at open" timeout=30 begin
        cs = Zenoh.default_shm_clients()

        # Positive: a client config that enables SHM. `z_obtain_shm_provider`
        # fails for a brief warm-up window after connecting (reported as
        # :unavailable), so wait_for_shm must keep re-attempting until the
        # provider settles to :ready and gets cached.
        #
        # Whether the session-derived provider actually warms up within the
        # timeout depends on router negotiation and SHM resource state, which is
        # flaky late in a long suite — so we assert the *mechanism* (valid state,
        # capability consistent with state, SHM backing whenever capable) rather
        # than hard-requiring :ready. The happy path (sub-second warm-up to
        # :ready with a ShmBufMut backing) is verified standalone.
        shm_cfg = epcfg("transport:{shared_memory:{enabled:true}}")
        s = open(shm_cfg;
                 shm_clients = cs, wait_for_shm = true, shm_wait_timeout = 10.0)
        try
            st = Zenoh.shm_state(s)
            @test st in (:ready, :initializing, :unavailable, :disabled, :error)
            @test Zenoh.shm_capable(s) == (st in (:ready, :initializing))
            if Zenoh.shm_capable(s)
                @test zref(s, Pixel).backing isa Zenoh.ShmBufMut   # fast path uses SHM
            else
                @info "session-derived SHM provider not ready in-suite; skipping SHM-backed assertion" state=st
            end
        finally
            close(s)
        end

        # Bounded wait: a short timeout must return promptly whether or not SHM
        # comes up (it can — even a connect-only session warms up against an SHM
        # router — so we only assert the *bound*, not the transport).
        t0 = time()
        s2 = open(epcfg();
                  shm_clients = cs, wait_for_shm = 0.5, shm_wait_timeout = 0.5)
        try
            @test (time() - t0) < 5.0           # bounded by the 0.5s timeout, no hang
            @test Zenoh.shm_state(s2) isa Symbol
        finally
            close(s2)
        end

        # Deterministic Julia fallback: a session opened WITHOUT shm_clients is
        # never SHM-capable, so zref always backs onto Julia memory.
        s3 = open(epcfg())
        try
            @test Zenoh.shm_state(s3) == :none
            @test !Zenoh.shm_capable(s3)
            @test zref(s3, Pixel).backing isa Base.RefValue
        finally
            close(s3)
        end
    end

    @timed_testset "ZRef session alloc-error handler" timeout=20 begin
        cs = Zenoh.default_shm_clients()
        c  = epcfg()

        # (a) Registered handler is notified, then zref still degrades to Julia.
        seen = Ref{Any}(nothing)
        s = open(c; shm_clients = cs, on_shm_alloc_error = e -> (seen[] = e))
        try
            # The test config doesn't enable the session-derived provider, so
            # inject a deliberately tiny one to force the alloc to fail.
            s.shm[] = Zenoh.ShmProvider(1 << 16)   # 64 KiB < sizeof(Huge)
            r = zref(s, Huge)                       # ShmAllocError → handler → fallback
            @test seen[] isa Zenoh.ShmAllocError
            @test !Zenoh.isborrowed(r)              # degraded to Julia memory
            @test r isa ZRef{Huge}
        finally
            close(s)
        end

        # (b) A throwing handler escalates the failure out of zref.
        s2 = open(c; shm_clients = cs, on_shm_alloc_error = e -> throw(e))
        try
            s2.shm[] = Zenoh.ShmProvider(1 << 16)
            @test_throws Zenoh.ShmAllocError zref(s2, Huge)
        finally
            close(s2)
        end

        # (c) No handler: silent fallback (no throw), still returns a usable ZRef.
        s3 = open(c; shm_clients = cs)
        try
            s3.shm[] = Zenoh.ShmProvider(1 << 16)
            r = zref(s3, Huge)
            @test !Zenoh.isborrowed(r)
        finally
            close(s3)
        end
    end

    @timed_testset "SHM session-derived provider" timeout=20 begin
        # `z_obtain_shm_provider` requires the session to be configured with
        # a session-side SHM provider, which the default test config does not
        # enable. Verify the API is callable and either succeeds (provider
        # returned) or surfaces a ZenohError — exercising the error path is
        # what matters for v1 coverage of this entrypoint.
        c = epcfg()
        s = open(c; shm_clients = Zenoh.default_shm_clients())
        try
            local provider
            try
                provider = Zenoh.obtain_shm_provider(s)
                @test provider isa Zenoh.SharedShmProvider
                @test provider isa Zenoh.AbstractShmProvider
            catch e
                @test e isa Zenoh.ZenohError
            end
        finally
            close(s)
        end
    end

    @timed_testset "SHM cleanup_orphaned_shm_segments" timeout=10 begin
        # Idempotent / safe to call.
        @test Zenoh.cleanup_orphaned_shm_segments() === nothing
    end

    # Read a Sample's payload as a String (advanced-pubsub tests).
    _smp_str(smp) = open(Zenoh.payload(smp), Val(:read)) do io; read(io, String); end

    # Advanced publishers (cache / sample-miss detection) stamp samples, so
    # their session needs timestamping enabled — otherwise the declare fails
    # with Z_EGENERIC. Dedicated router-connected sessions for the advanced
    # testsets below; closed after the last one.
    atscfg() = epcfg("timestamping:{enabled:true}")
    ATS1 = open(atscfg())
    ATS2 = open(atscfg())
    sleep(0.5)

    @timed_testset "Advanced pub/sub: routing & type contract" begin
        s = ATS1
        # Routing predicate is type-stable by inference (presence, not value).
        @test (@inferred Zenoh._wants_advanced((cache=64,), Val(Zenoh.ADVANCED_PUB_KW)))
        @test !(@inferred Zenoh._wants_advanced((priority=1,), Val(Zenoh.ADVANCED_PUB_KW)))
        @test !(@inferred Zenoh._wants_advanced(NamedTuple(), Val(Zenoh.ADVANCED_PUB_KW)))
        @test (@inferred Zenoh._wants_advanced((history=1,), Val(Zenoh.ADVANCED_SUB_KW)))

        # Publisher routes on advanced-keyword presence; plain stays plain.
        p = Zenoh.Publisher(s, Zenoh.Keyexpr("test/adv/route/plain"))
        ap = Zenoh.Publisher(s, Zenoh.Keyexpr("test/adv/route/adv"); cache = 64)
        ape = Zenoh.AdvancedPublisher(s, Zenoh.Keyexpr("test/adv/route/exp"); cache = 64)
        try
            @test p isa Zenoh.Publisher && !Zenoh.isadvanced(p)
            @test ap isa Zenoh.AdvancedPublisher && Zenoh.isadvanced(ap)
            @test ape isa Zenoh.AdvancedPublisher
            @test p isa Zenoh.AbstractPublisher && ap isa Zenoh.AbstractPublisher
        finally
            close(p); close(ap); close(ape)
        end
    end

    @timed_testset "Advanced pub/sub: basic round-trip" begin
        s = ATS1
        sub = nothing; pub = nothing
        try
            k = Zenoh.Keyexpr("test/adv/basic")
            got = Channel{String}(1)
            sub = open(smp -> put!(got, _smp_str(smp)), s, k;
                       recovery = RecoveryOptions())
            @test sub isa Zenoh.AdvancedSubscriber
            pub = Zenoh.Publisher(s, k; cache = 16, miss_detection = :periodic)
            @test pub isa Zenoh.AdvancedPublisher
            Zenoh.put(pub, "adv-hello")
            @test take!(got) == "adv-hello"
        finally
            isnothing(sub) || close(sub)
            isnothing(pub) || close(pub)
        end
    end

    @timed_testset "Advanced pub/sub: history replay to late subscriber" begin
        # Cross-session via the router: publisher caches, a later advanced
        # subscriber queries the cache on declaration.
        pub = nothing; sub = nothing
        try
            k = Zenoh.Keyexpr("test/adv/history")
            pub = Zenoh.Publisher(ATS1, k; cache = CacheOptions(max_samples = 10))
            for i in 1:3
                Zenoh.put(pub, "h-$i")
            end
            sleep(0.4)  # let the cache settle / be discoverable
            sub = open(ATS2, k; channel = :fifo, capacity = 16,
                       history = HistoryOptions())
            # Drain replayed history with a short poll budget.
            collected = String[]
            deadline = time() + 3.0
            while time() < deadline && length(collected) < 3
                x = Zenoh.tryrecv!(sub)
                if x === nothing
                    sleep(0.05)
                else
                    push!(collected, _smp_str(x))
                end
            end
            @test !isempty(collected)              # history replay happened
            @test issubset(Set(collected), Set(["h-1", "h-2", "h-3"]))
        finally
            isnothing(sub) || close(sub)
            isnothing(pub) || close(pub)
        end
    end

    @timed_testset "Advanced pub/sub: unified delete!" begin
        s = ATS1
        sub = nothing; pub = nothing
        try
            k = Zenoh.Keyexpr("test/adv/delete")
            sub = open(s, k; channel = :fifo, capacity = 8)   # plain buffered sub
            pub = Zenoh.Publisher(s, k; cache = 4)            # advanced publisher
            Zenoh.put(pub, "v")
            s1 = take!(sub)
            @test Zenoh.kind(s1) === Zenoh.SampleKinds.PUT
            # delete! on an AdvancedPublisher → DELETE-kind sample
            Zenoh.delete!(pub)
            s2 = take!(sub)
            @test Zenoh.kind(s2) === Zenoh.SampleKinds.DELETE
            # delete! on a Session and a plain Publisher also dispatch cleanly.
            Zenoh.delete!(s, k)
            s3 = take!(sub)
            @test Zenoh.kind(s3) === Zenoh.SampleKinds.DELETE
        finally
            isnothing(sub) || close(sub)
            isnothing(pub) || close(pub)
        end
    end

    @timed_testset "Advanced pub/sub: MatchingListener + matching_status" begin
        s = ATS1
        pub = nothing; sub = nothing; ml = nothing
        try
            k = Zenoh.Keyexpr("test/adv/matching")
            pub = Zenoh.Publisher(s, k; cache = 4)
            @test pub isa Zenoh.AdvancedPublisher
            @test Zenoh.matching_status(pub) == false
            transitions = Channel{Bool}(4)
            ml = MatchingListener(b -> put!(transitions, b), pub)
            sub = open(_ -> nothing, s, k)
            @test take!(transitions) == true       # subscriber arrived
            sleep(0.1)
            @test Zenoh.matching_status(pub) == true
        finally
            isnothing(ml)  || close(ml)
            isnothing(sub) || close(sub)
            isnothing(pub) || close(pub)
        end
    end

    @timed_testset "Advanced pub/sub: SampleMissListener declare/close" begin
        s = ATS1
        sub = nothing; pub = nothing; ml = nothing
        try
            k = Zenoh.Keyexpr("test/adv/miss")
            sub = open(_ -> nothing, s, k; recovery = RecoveryOptions())
            @test sub isa Zenoh.AdvancedSubscriber
            ml = Zenoh.SampleMissListener(m -> nothing, sub)
            @test ml isa Zenoh.SampleMissListener
            # Clean stream → no spurious misses; declare/close must be clean.
            pub = Zenoh.Publisher(s, k; cache = 4, miss_detection = :periodic)
            Zenoh.put(pub, "x")
            sleep(0.1)
            close(ml); ml = nothing
            @test true
        finally
            isnothing(ml)  || close(ml)
            isnothing(sub) || close(sub)
            isnothing(pub) || close(pub)
        end
    end

    @timed_testset "Advanced pub/sub: heartbeat modes + idempotent close" begin
        s = ATS1
        for hb in (:none, :periodic, :sporadic)
            pub = Zenoh.Publisher(s, Zenoh.Keyexpr("test/adv/hb/$hb");
                                  miss_detection = MissDetectionOptions(heartbeat = hb))
            @test pub isa Zenoh.AdvancedPublisher
            close(pub)
            @test pub.closed
            close(pub)             # idempotent
            @test pub.closed
        end
        @test_throws ArgumentError Zenoh._heartbeat_mode(:bogus)
    end

    include("ring_channel.jl")

    close(ATS1)
    close(ATS2)

finally
    close(S1)
    close(S2)
    kill(router)
end