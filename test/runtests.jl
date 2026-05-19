using Zenoh, Zenohd_jll, Test
router = run(pipeline(`$(Zenohd_jll.zenohd()) -l tcp/localhost:19148`, stdout = stdout), wait=false)

try
    @testset "Config" begin 
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
    @testset "ZBytes" begin 
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

    @testset "ZSlice" begin
        es = Zenoh.ZSlice()
        @test isempty(es)
        @test length(es) == 0

        data = UInt8[1, 2, 3, 4, 5]
        cs = Zenoh.ZSlice(data; copy=true)
        @test !isempty(cs)
        @test length(cs) == 5
    end

    @testset "ZBytes iteration" begin
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

    @testset "Publisher-Subscriber" begin
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

    @testset "Timestamp and ZID" begin
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

    @testset "Session put with timestamp" begin
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

    @testset "Sample accessors" begin
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

    @testset "Encoding" begin
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

    @testset "Put with encoding" begin
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
finally
    kill(router)
end