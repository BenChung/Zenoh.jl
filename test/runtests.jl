using Zenoh, Zenohd_jll, Test
include("test_utils.jl")
router = run(pipeline(`$(Zenohd_jll.zenohd()) -l tcp/localhost:19148`, stdout = stdout), wait=false)

try
    @timed_testset "Config" begin 
        c = Zenoh.Config()
        ref = Zenoh.toJson(c)
        c["connect/endpoints"] = "[\"tcp/localhost:19148\"]"
        @test c["connect/endpoints"] == "[\"tcp/localhost:19148\"]"
        @test length(Zenoh.toJson(c)) > length(ref) # lame I know 
    end

    struct TestStruct 
        a::Int
        b::Float64
    end
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

    @timed_testset "Keyexpr macro" begin
        k = kexpr"test/macro"
        @test k isa Zenoh.Keyexpr
        # `**/**` is non-canonical (collapses to `**`); strict rejects, `c` accepts.
        @test_throws Zenoh.ZenohError kexpr"**/**"
        @test kexpr"**/**"c isa Zenoh.Keyexpr
        # Unknown flag rejected at macro expansion.
        @test_throws ArgumentError @macroexpand kexpr"whatever"x
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
        c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:19148"]}}""")
        s = open(c)
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
            end
            close(s)
        end
    end

    @timed_testset "Timestamp and ZID" begin
        # Create a session with the router
        c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:19148"]}}""")
        s = open(c)
        sub = nothing
        pub = nothing
        
        try
            # Test session ZID
            session_zid = Zenoh.zid(s)
            @test !all(iszero, session_zid.id)  # ZID should not be all zeros
            
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
            end
            close(s)
        end
    end

    @timed_testset "Session put with timestamp" begin
        # Exercises Zenoh.put(::Session, ::Keyexpr, payload; timestamp=...),
        # which writes the timestamp through Ptr{z_put_options_t}. Using the
        # wrong options struct type would land the write at the wrong offset
        # and the received timestamp would not match what was sent.
        c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:19148"]}}""")
        s = open(c)
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
            end
            close(s)
        end
    end

    @timed_testset "Sample accessors" begin
        c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:19148"]}}""")
        s = open(c)
        sub = nothing
        pub = nothing

        try
            test_key_str = "test/sample_accessors"
            test_key = Zenoh.Keyexpr(test_key_str)

            received_kind = Channel{Zenoh.LibZenohC.z_sample_kind_t}(1)
            received_keyexpr = Channel{String}(1)
            received_attachment = Channel{Union{Nothing, Zenoh.ZBytes}}(1)
            received_encoding = Channel{Zenoh.Encoding}(1)
            received_cc = Channel{Zenoh.LibZenohC.z_congestion_control_t}(1)
            received_prio = Channel{Zenoh.LibZenohC.z_priority_t}(1)
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
            @test take!(received_kind) == Zenoh.LibZenohC.Z_SAMPLE_KIND_PUT
            @test take!(received_keyexpr) == test_key_str
            @test take!(received_attachment) === nothing
            enc = take!(received_encoding)
            @test enc isa Zenoh.Encoding
            @test !isempty(enc.mime)
            @test take!(received_cc) == Zenoh.LibZenohC.Z_CONGESTION_CONTROL_DEFAULT
            @test take!(received_prio) == Zenoh.LibZenohC.Z_PRIORITY_DEFAULT
            @test take!(received_express) isa Bool
        finally
            if !isnothing(sub)
                close(sub)
            end
            if !isnothing(pub)
                close(pub)
            end
            close(s)
        end
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
        c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:19148"]}}""")
        s = open(c)
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
            end
            close(s)
        end
    end
    @timed_testset "Buffered subscriber" begin
        c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:19148"]}}""")
        s = open(c)
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
            end
            close(s)
        end
    end

    @timed_testset "Buffered subscriber (ring)" begin
        c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:19148"]}}""")
        s = open(c)
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
            end
            close(s)
        end
    end

    @timed_testset "Get/Reply" begin
        c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:19148"]}}""")
        s = open(c)

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
        finally
            close(s)
        end
    end

    @timed_testset "Liveliness token + buffered subscriber" begin
        c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:19148"]}}""")
        s = open(c)
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
            @test Zenoh.kind(put_sample) == Zenoh.LibZenohC.Z_SAMPLE_KIND_PUT
            @test Zenoh.keyexpr(put_sample) == "test/liveliness/buffered"

            # Undeclare → subscriber sees a DELETE.
            close(tok)
            tok = nothing
            del_sample = take!(sub)
            @test Zenoh.kind(del_sample) == Zenoh.LibZenohC.Z_SAMPLE_KIND_DELETE
        finally
            !isnothing(tok) && close(tok)
            !isnothing(sub) && close(sub)
            close(s)
        end
    end

    @timed_testset "Liveliness callback subscriber" begin
        c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:19148"]}}""")
        s = open(c)
        sub = nothing
        tok = nothing
        try
            test_key = Zenoh.Keyexpr("test/liveliness/callback")
            seen = Channel{Zenoh.LibZenohC.z_sample_kind_t}(4)
            sub = Zenoh.LivelinessSubscriber((sample) -> put!(seen, Zenoh.kind(sample)),
                s, test_key)

            tok = Zenoh.LivelinessToken(s, test_key)
            @test take!(seen) == Zenoh.LibZenohC.Z_SAMPLE_KIND_PUT

            close(tok); tok = nothing
            @test take!(seen) == Zenoh.LibZenohC.Z_SAMPLE_KIND_DELETE
        finally
            !isnothing(tok) && close(tok)
            !isnothing(sub) && close(sub)
            close(s)
        end
    end

    @timed_testset "Liveliness history replay" begin
        # history=true should replay existing tokens to a late subscriber.
        c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:19148"]}}""")
        s = open(c)
        sub = nothing
        tok = nothing
        try
            test_key = Zenoh.Keyexpr("test/liveliness/history")
            tok = Zenoh.LivelinessToken(s, test_key)
            sleep(0.1)  # let the token propagate before the late subscribe

            sub = Zenoh.LivelinessSubscriberHandler(s, test_key;
                capacity=4, history=true)
            sample = take!(sub)
            @test Zenoh.kind(sample) == Zenoh.LibZenohC.Z_SAMPLE_KIND_PUT
            @test Zenoh.keyexpr(sample) == "test/liveliness/history"
        finally
            !isnothing(tok) && close(tok)
            !isnothing(sub) && close(sub)
            close(s)
        end
    end

    @timed_testset "Locality" begin
        @test Zenoh.Locality(:any).v           == Zenoh.LibZenohC.Z_LOCALITY_ANY
        @test Zenoh.Locality(:session_local).v == Zenoh.LibZenohC.Z_LOCALITY_SESSION_LOCAL
        @test Zenoh.Locality(:remote).v        == Zenoh.LibZenohC.Z_LOCALITY_REMOTE
        @test Zenoh.Locality(:default).v       == Zenoh.LibZenohC.z_locality_default()
        @test_throws MethodError Zenoh.Locality(:bogus)

        @test Zenoh.Locality(:any) == Zenoh.Localities.ANY
        @test Zenoh.Localities.SESSION_LOCAL == Zenoh.Locality(:session_local)
        @test Zenoh.Localities.REMOTE.v == Zenoh.LibZenohC.Z_LOCALITY_REMOTE

        @test hash(Zenoh.Locality(:remote)) == hash(Zenoh.Localities.REMOTE)
        @test occursin(":remote", sprint(show, Zenoh.Localities.REMOTE))
    end

    @timed_testset "Queryable (channel) round-trip" begin
        c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:19148"]}}""")
        s = open(c)
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
                timeout_ms=2000))
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
            !isnothing(srv) && wait(srv)
            close(s)
        end
    end

    @timed_testset "Queryable (callback) round-trip" begin
        c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:19148"]}}""")
        s = open(c)
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
            !isnothing(q) && close(q)
            close(s)
        end
    end

    @timed_testset "Queryable accessors (payload + attachment + encoding)" begin
        c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:19148"]}}""")
        s = open(c)
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

            collect(Zenoh.get(s, test_key; timeout_ms=2000,
                payload="req-payload",
                encoding=Zenoh.Encodings.APPLICATION_JSON,
                attachment="req-meta"))

            @test take!(seen_payload) == "req-payload"
            @test take!(seen_attach)  == "req-meta"
            @test take!(seen_enc)     == Zenoh.Encodings.APPLICATION_JSON
        finally
            !isnothing(qh) && close(qh)
            !isnothing(srv) && wait(srv)
            close(s)
        end
    end

    @timed_testset "Queryable reply_err" begin
        c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:19148"]}}""")
        s = open(c)
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
            !isnothing(q) && close(q)
            close(s)
        end
    end

    @timed_testset "Queryable reply_del" begin
        c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:19148"]}}""")
        s = open(c)
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
            @test Zenoh.kind(smp) == Zenoh.LibZenohC.Z_SAMPLE_KIND_DELETE
        finally
            !isnothing(q) && close(q)
            close(s)
        end
    end

    @timed_testset "Queryable tryrecv! + close before any query" begin
        c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:19148"]}}""")
        s = open(c)
        qh = nothing
        try
            qh = Zenoh.Queryable(s, Zenoh.Keyexpr("test/queryable/idle");
                channel=:ring, capacity=2)
            # No query in flight → tryrecv! returns nothing (doesn't block).
            @test Zenoh.tryrecv!(qh) === nothing
        finally
            !isnothing(qh) && close(qh)
            close(s)
        end
    end

    @timed_testset "liveliness_get snapshot" begin
        c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:19148"]}}""")
        s = open(c)
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
            !isnothing(tok) && close(tok)
            close(s)
        end
    end
finally
    kill(router)
end