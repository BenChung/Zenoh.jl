# Publisher + put. The session-level `put(s::Session, k, payload; …)` and
# the long-lived `Publisher` form share the per-call options (timestamp,
# encoding, attachment) but differ on QoS fields — see `_make_put_opts`.
# `_shm_zbytes` routes the optional `shm=` kwarg through to an
# SHM-backed ZBytes; specializations live in shm.jl.

struct Publisher
    pub::Base.RefValue{LibZenohC.z_owned_publisher_t}
    keyexpr::Keyexpr # we have to keep this for GC
    function Publisher(s::Session, k::Keyexpr;
            encoding::Union{Nothing, Encoding, AbstractString, Base.MIME} = nothing,
            congestion_control::Union{Nothing, CongestionControl}         = nothing,
            priority::Union{Nothing, Priority}                            = nothing,
            is_express::Union{Nothing, Bool}                              = nothing,
            allowed_destination::Union{Nothing, Locality}                 = nothing)
        opts = Ref{LibZenohC.z_publisher_options_t}()
        LibZenohC.z_publisher_options_default(opts)
        optsP = Base.unsafe_convert(Ptr{LibZenohC.z_publisher_options_t}, opts)

        enc_ref = isnothing(encoding) ? nothing : _to_owned_encoding(_as_encoding(encoding))
        isnothing(enc_ref)             || (optsP.encoding            = _move(enc_ref))
        isnothing(congestion_control)  || (optsP.congestion_control  = _raw(congestion_control))
        isnothing(priority)            || (optsP.priority            = _raw(priority))
        isnothing(is_express)          || (optsP.is_express          = is_express)
        isnothing(allowed_destination) || (optsP.allowed_destination = _raw(allowed_destination))

        pub = Ref{LibZenohC.z_owned_publisher_t}()
        ret = GC.@preserve enc_ref LibZenohC.z_declare_publisher(_loan(s), pub, _loan(k), opts)
        _handle_result(ret)
        return new(pub, k)
    end
end
function Base.close(s::Publisher)
    _handle_result(LibZenohC.z_undeclare_publisher(_move(s.pub)))
end

function _init_put_opts(::Type{LibZenohC.z_publisher_put_options_t})
    opts = Ref{LibZenohC.z_publisher_put_options_t}()
    LibZenohC.z_publisher_put_options_default(opts)
    return opts
end

function _init_put_opts(::Type{LibZenohC.z_put_options_t})
    opts = Ref{LibZenohC.z_put_options_t}()
    LibZenohC.z_put_options_default(opts)
    return opts
end

const _Put_Types = Union{LibZenohC.z_publisher_put_options_t, LibZenohC.z_put_options_t}

# Shared between session-level put (z_put_options_t) and publisher put
# (z_publisher_put_options_t): timestamp, encoding, attachment. QoS
# fields (congestion_control / priority / is_express / allowed_destination)
# only exist on z_put_options_t — at the publisher level they're baked
# into the Publisher itself — so the session-level `put` handles those
# inline rather than threading another conditional through this helper.
function _make_put_opts(::Type{T};
        timestamp::Union{Nothing, ZTimestamp} = nothing,
        encoding::Union{Nothing, Encoding, AbstractString, Base.MIME} = nothing,
        attachment = nothing) where T <: _Put_Types
    opts  = _init_put_opts(T)
    optsP = Base.unsafe_convert(Ptr{T}, opts)

    enc_ref    = isnothing(encoding)   ? nothing : _to_owned_encoding(_as_encoding(encoding))
    attach_ref = isnothing(attachment) ? nothing : ZBytes(attachment)

    isnothing(timestamp)  || (optsP.timestamp  = Base.unsafe_convert(Ptr{LibZenohC.z_timestamp_t}, timestamp.ts))
    isnothing(enc_ref)    || (optsP.encoding   = _move(enc_ref))
    isnothing(attach_ref) || (optsP.attachment = _move(attach_ref))

    # `timestamp` is returned so the caller can GC.@preserve it across the
    # put: optsP.timestamp is a *borrowed* pointer into the ZTimestamp's
    # Ref (unlike encoding/attachment, which are moved-owned), so the
    # ZTimestamp must outlive the z_put/z_publisher_put call.
    return opts, enc_ref, attach_ref, timestamp
end

# Default for `shm=` kwarg routing. shm.jl specializes on AbstractShmProvider
# to alloc + copy into SHM and produce an SHM-backed ZBytes.
_shm_zbytes(::Nothing, payload) = ZBytes(payload)

function put(p::Publisher, payload; shm=nothing, kwargs...)
    bytes = _shm_zbytes(shm, payload)
    opts, enc_ref, attach_ref, ts = _make_put_opts(LibZenohC.z_publisher_put_options_t; kwargs...)

    GC.@preserve enc_ref attach_ref ts begin
        rtc = LibZenohC.z_publisher_put(_loan(p.pub), _move(bytes), opts)
        _handle_result(rtc)
    end
end

function put(s::Session, k::Keyexpr, payload;
        shm=nothing,
        congestion_control::Union{Nothing, CongestionControl} = nothing,
        priority::Union{Nothing, Priority}                    = nothing,
        is_express::Union{Nothing, Bool}                      = nothing,
        allowed_destination::Union{Nothing, Locality}         = nothing,
        kwargs...)
    bytes = _shm_zbytes(shm, payload)
    opts, enc_ref, attach_ref, ts = _make_put_opts(LibZenohC.z_put_options_t; kwargs...)
    optsP = Base.unsafe_convert(Ptr{LibZenohC.z_put_options_t}, opts)
    isnothing(congestion_control)  || (optsP.congestion_control  = _raw(congestion_control))
    isnothing(priority)            || (optsP.priority            = _raw(priority))
    isnothing(is_express)          || (optsP.is_express          = is_express)
    isnothing(allowed_destination) || (optsP.allowed_destination = _raw(allowed_destination))

    GC.@preserve enc_ref attach_ref ts begin
        rtc = LibZenohC.z_put(_loan(s), _loan(k), _move(bytes), opts)
        _handle_result(rtc)
    end
end
