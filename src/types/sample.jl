# Sample — owned/loaned wrapper around `z_owned_sample_t`. Delivered by
# subscribers and queries; accessors read the underlying loaned form.

struct Sample{S <: Union{Base.RefValue{LibZenohC.z_owned_sample_t},
                         Ptr{LibZenohC.z_loaned_sample_t}}}
    s::S
end
Sample(p::Ptr{LibZenohC.z_loaned_sample_t}) =
    Sample{Ptr{LibZenohC.z_loaned_sample_t}}(p)
function Sample(r::Base.RefValue{LibZenohC.z_owned_sample_t})
    finalizer(x -> LibZenohC.z_sample_drop(_move(x)), r)
    return Sample{Base.RefValue{LibZenohC.z_owned_sample_t}}(r)
end

_loaned_sample(s::Sample{Ptr{LibZenohC.z_loaned_sample_t}}) = s.s
_loaned_sample(s::Sample{Base.RefValue{LibZenohC.z_owned_sample_t}}) = _loan(s.s)

function timestamp(s::Sample)
    ts = LibZenohC.z_sample_timestamp(_loaned_sample(s))
    if ts == C_NULL
        return nothing
    else
        ZTimestamp(ts)
    end
end

function payload(s::Sample)
    return ZBytes(LibZenohC.z_sample_payload(_loaned_sample(s)))
end

kind(s::Sample) = LibZenohC.z_sample_kind(_loaned_sample(s))

function keyexpr(s::Sample)
    ke = LibZenohC.z_sample_keyexpr(_loaned_sample(s))
    view = Ref{LibZenohC.z_view_string_t}()
    LibZenohC.z_keyexpr_as_view_string(ke, view)
    loaned = LibZenohC.z_view_string_loan(view)
    return unsafe_string(LibZenohC.z_string_data(loaned), LibZenohC.z_string_len(loaned))
end

function attachment(s::Sample)
    a = LibZenohC.z_sample_attachment(_loaned_sample(s))
    if a == C_NULL
        return nothing
    else
        return ZBytes(a)
    end
end

congestion_control(s::Sample) = _congestion_control_from_raw(LibZenohC.z_sample_congestion_control(_loaned_sample(s)))
priority(s::Sample) = _priority_from_raw(LibZenohC.z_sample_priority(_loaned_sample(s)))
express(s::Sample) = LibZenohC.z_sample_express(_loaned_sample(s))

function encoding(s::Sample)
    return _from_loaned_encoding(LibZenohC.z_sample_encoding(_loaned_sample(s)))
end
