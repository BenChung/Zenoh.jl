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
finally
    kill(router)
end