# ZTimestamp — owned timestamp value. Sessions mint fresh ones via the
# `ZTimestamp(::Session)` constructor; the pointer-form constructor
# copies an existing timestamp by value out of a libzenoh-owned slot.

"""
    ZTimestamp

A Zenoh timestamp held by value: an NTP64 time (a Hybrid Logical Clock reading)
paired with the Zenoh id of the node that generated it. Read [`ntp64_time`](@ref)
for the raw 64-bit time and `Zenoh.zid` for the generating node's id.

Mint a fresh one from a session's clock with [`ZTimestamp(::Session)`](@ref) to
stamp an outbound put, delete, or reply; read one off an inbound sample with
`timestamp(::Sample)`. The underlying `z_timestamp_t` is a plain value carrying
no external resources, so it lives by value in a `Ref` with no drop.
"""
struct ZTimestamp
    ts::Base.RefValue{LibZenohC.z_timestamp_t}
end

"""
    ZTimestamp(s::Session)

Mints a fresh timestamp from the session's Hybrid Logical Clock via
`z_timestamp_new`, for stamping an outbound put, delete, or reply explicitly.
"""
function ZTimestamp(s::Session)
    ts = Ref{LibZenohC.z_timestamp_t}()
    ret = LibZenohC.z_timestamp_new(ts, _loan(s))
    _handle_result(ret)
    return ZTimestamp(ts)
end

"""
    ZTimestamp(ptr::Ptr{LibZenohC.z_timestamp_t})

Copies an existing timestamp by value out of a libzenoh-owned slot into a
self-owned `Ref`, used internally by `timestamp(::Sample)` to lift a sample's
timestamp into a [`ZTimestamp`](@ref) that outlives the borrowed sample.
"""
function ZTimestamp(ptr::Ptr{LibZenohC.z_timestamp_t})
    ts = Ref{LibZenohC.z_timestamp_t}()
    unsafe_copyto!(Base.unsafe_convert(Ptr{LibZenohC.z_timestamp_t}, ts), ptr, 1)
    return ZTimestamp(ts)
end

zid(z::ZTimestamp) = LibZenohC.z_timestamp_id(z.ts)

"""
    ntp64_time(z::ZTimestamp)

Returns the timestamp's raw 64-bit NTP64 time as a `UInt64`, with the high 32
bits holding seconds and the low 32 bits the fraction (`seconds << 32 | fraction`);
split them yourself to recover each part.
"""
ntp64_time(z::ZTimestamp) = LibZenohC.z_timestamp_ntp64_time(z.ts)

export ZTimestamp, ntp64_time
