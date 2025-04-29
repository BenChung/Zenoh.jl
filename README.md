# Zenoh.jl

Wraps the Zenoh C bindings for Julia.

Currently supports publication & subscription.

##  Publish
```
c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:7448"]}}""")
s = open(c)
kbr = Zenoh.Keyexpr("example")
Zenoh.put(s, kbr, "hi")
close(sub)
```

## Subscribe
```
c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:7448"]}}""")
s = open(c)
kbr = Zenoh.Keyexpr("example")
sub = open((s) -> begin 
    p = Zenoh.payload(s)
    open(p, Val(:read)) do msg
        # do something with the msg IO
    end
end, s, kbr)
close(sub)
```
