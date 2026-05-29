

"""
A Zenoh configuration. Can be constructed as Config(; from_env=[should load from ZENOH_CONFIG env var], file="filename", str="json string").
Only zero or one of these options can be selected; if none is selected (the default) then the configuration will be initialized from the default.
"""
struct Config
    c::Base.RefValue{LibZenohC.z_owned_config_t}
    function Config(;from_env=false, file=nothing, str=nothing)
        cfg = Ref{LibZenohC.z_owned_config_t}()
        if !from_env && isnothing(file) && isnothing(str)
            res = LibZenohC.z_config_default(cfg)
        elseif from_env && isnothing(file) && isnothing(str)
            res = LibZenohC.zc_config_from_env(cfg)
        elseif !from_env && !isnothing(file) && isnothing(str)
            res = GC.@preserve file LibZenohC.zc_config_from_file(cfg, pointer(Base.unsafe_convert(Cstring, file)))
        elseif !from_env && isnothing(file) && !isnothing(str)
            res = GC.@preserve str LibZenohC.zc_config_from_str(cfg, pointer(Base.unsafe_convert(Cstring, str)))
        else
            throw(ArgumentError("Only one of from_env/file/str can be used to configure Zenoh"))
        end
        _handle_result(res)
        finalizer(c -> _drop(_move(c)), cfg)
        new(cfg)
    end
end
"""
Gets a JSON-serialized value at the key position of the configuration.
"""
function Base.getindex(c::Config, key::String)
    r=Ref{LibZenohC.z_owned_string_t}()
    GC.@preserve key _handle_result(LibZenohC.zc_config_get_from_str(_loan(c.c), pointer(Base.unsafe_convert(Cstring, key)), r))
    res = _string(r)
    _drop(_move(r))
    return res
end

"""
Serialize a Julia value into a JSON5 fragment suitable for insertion into a
`Config`. This is deliberately minimal — Zenoh's own parser validates and
canonicalizes the value on insert, so we only need to emit well-formed JSON5 for
the value types the config builder produces. Note that strings are *quoted* here
(the nested form); a top-level `AbstractString` passed to `setindex!` is instead
treated as raw, pre-formatted JSON5 (see below).
"""
_to_json5(x::Bool) = x ? "true" : "false"
_to_json5(x::Integer) = string(x)
_to_json5(x::Real) = string(x)
_to_json5(x::Symbol) = _to_json5(String(x))
function _to_json5(s::AbstractString)
    io = IOBuffer()
    write(io, '"')
    for ch in s
        (ch == '"' || ch == '\\') && write(io, '\\')
        write(io, ch)
    end
    write(io, '"')
    return String(take!(io))
end
_to_json5(x::AbstractVector) = "[" * join(map(_to_json5, x), ",") * "]"
_to_json5(p::Pair) = _to_json5(string(p.first)) * ":" * _to_json5(p.second)
_to_json5(d::AbstractDict) = "{" * join((_to_json5(k => v) for (k, v) in d), ",") * "}"
_to_json5(nt::NamedTuple) =
    "{" * join((_to_json5(string(k) => getfield(nt, k)) for k in keys(nt)), ",") * "}"

"""
Inserts a pre-formatted JSON5 string value at the key position of the
configuration, verbatim. (The value must already be valid JSON5, e.g.
`c["connect/endpoints"] = "[\\"tcp/localhost:7447\\"]"`.)
"""
function Base.setindex!(c::Config, value::AbstractString, key::AbstractString)
    skey = String(key)
    sval = String(value)
    GC.@preserve skey sval _handle_result(LibZenohC.zc_config_insert_json5(_loan(c.c), pointer(Base.unsafe_convert(Cstring, skey)), pointer(Base.unsafe_convert(Cstring, sval))))
    return value
end

"""
Inserts any other Julia value at the key position, serializing it to a JSON5
fragment first (`true`, `5000`, `:peer`, `["tcp/…"]`, a `Dict`, or a typed
config section). Lets you write `c["mode"] = :peer` instead of hand-writing JSON.
"""
Base.setindex!(c::Config, value, key::AbstractString) = setindex!(c, _to_json5(value), String(key))

"""
Convert a config into an equivalent JSON string.
"""
function toJson(c::Config)
    r=Ref{LibZenohC.z_owned_string_t}()
    _handle_result(LibZenohC.zc_config_to_string(_loan(c.c), r))
    res = _string(r)
    _drop(_move(r))
    return res
end

function Base.show(io::IO, c::Config)
    println(io, toJson(c))
end

export Config