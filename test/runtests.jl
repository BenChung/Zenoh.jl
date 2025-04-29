using Zenoh, Test
using CDR


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