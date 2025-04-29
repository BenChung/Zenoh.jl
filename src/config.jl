

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
            throw("Only one of env/file/str can be used to configure Zenoh")
        end
        _handle_result(res)
        finalizer(c -> _drop(_move(c)), cfg)
        new(cfg)
    end
end

"""
Reads a configuration from a JSON-serialized string, such as ‘{mode:”client”,connect:{endpoints:[“tcp/127.0.0.1:7447”]}}’.
"""
function Base.getindex(c::Config, key::String)
    r=Ref{LibZenohC.z_owned_string_t}()
    GC.@preserve key _handle_result(LibZenohC.zc_config_get_from_str(_loan(c.c), pointer(Base.unsafe_convert(Cstring, key)), r))
    res = unsafe_string(LibZenohC.z_string_data(_loan(r)))
    _drop(_move(r))
    return res
end

"""
Inserts a JSON-serialized value at the key position of the configuration.
"""
function Base.setindex!(c::Config, value::String, key::String)
    GC.@preserve key value _handle_result(LibZenohC.zc_config_insert_json5(_loan(c.c), pointer(Base.unsafe_convert(Cstring, key)), pointer(Base.unsafe_convert(Cstring, value))))
end

"""
Convert a config into an equivalent JSON string.
"""
function toJson(c::Config)
    r=Ref{LibZenohC.z_owned_string_t}()
    _handle_result(LibZenohC.zc_config_to_string(_loan(c.c), r))
    res = unsafe_string(LibZenohC.z_string_data(_loan(r)))
    _drop(_move(r))
    return res
end

function Base.show(io::IO, c::Config)
    println(io, toJson(c))
end
