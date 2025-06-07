using Zenoh, Test
using CDR

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



c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:7448"]}}""")
s = open(c)
kbr = Zenoh.Keyexpr("px4/localpos")
sub = open((s) -> begin 
    p = Zenoh.payload(s)
    open(p, Val(:read)) do msg
        arr = readavailable(msg)
        rdr = CDRReader(arr)
        timestamp = read(rdr, UInt64)
        timestamp_sample = read(rdr, UInt64)
        xy_valid = read(rdr, UInt8)
        z_valid = read(rdr, UInt8)
        v_xy_valid = read(rdr, UInt8)
        v_z_valid = read(rdr, UInt8)
        x = read(rdr, Float32)
        y = read(rdr, Float32)
        z = read(rdr, Float32)
        println(z)
    end
end, s, kbr)
close(sub)