# Zenoh.jl

[![CI](https://github.com/BenChung/Zenoh.jl/actions/workflows/CI.yml/badge.svg?branch=master)](https://github.com/BenChung/Zenoh.jl/actions/workflows/CI.yml?query=branch%3Amaster)
[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://BenChung.github.io/Zenoh.jl/dev/)

Wraps the Zenoh C bindings for Julia.

Currently supports publication & subscription.

##  Publish
```
c = Zenoh.Config(; str = """{connect: { endpoints: ["tcp/localhost:7448"]}}""")
s = open(c)
kbr = Zenoh.Keyexpr("example")
Zenoh.put(s, kbr, "hi")
close(s)
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
