# ZTimestamp — owned timestamp value. Sessions mint fresh ones via the
# `ZTimestamp(::Session)` constructor; the pointer-form constructor
# copies an existing timestamp by value out of a libzenoh-owned slot.

struct ZTimestamp
    ts::Base.RefValue{LibZenohC.z_timestamp_t}
end

function ZTimestamp(s::Session)
    ts = Ref{LibZenohC.z_timestamp_t}()
    ret = LibZenohC.z_timestamp_new(ts, _loan(s))
    _handle_result(ret)
    return ZTimestamp(ts)
end

function ZTimestamp(ptr::Ptr{LibZenohC.z_timestamp_t})
    ts = Ref{LibZenohC.z_timestamp_t}()
    # Copy the timestamp data by value
    unsafe_copyto!(Base.unsafe_convert(Ptr{LibZenohC.z_timestamp_t}, ts), ptr, 1)
    return ZTimestamp(ts)
end

zid(z::ZTimestamp) = LibZenohC.z_timestamp_id(z.ts)
ntp64_time(z::ZTimestamp) = LibZenohC.z_timestamp_ntp64_time(z.ts)

export ZTimestamp, ntp64_time
