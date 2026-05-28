"""
    Encoding(mime::AbstractString; schema=nothing)
    Encoding(m::Base.MIME; schema=nothing)

Identifies the payload type of a Zenoh sample. `mime` is the media type
string (e.g. `"application/json"`); `schema` is an optional, arbitrary
substring appended after a semicolon when serialised on the wire. The
schema is passed through verbatim — callers are responsible for any
escaping their consumers require.

For well-known types, prefer the named constants in `Zenoh.Encodings`,
e.g. `Encodings.APPLICATION_JSON`.
"""
struct Encoding
    mime::String
    schema::Union{Nothing, String}
end

Encoding(mime::AbstractString; schema::Union{Nothing, AbstractString} = nothing) =
    Encoding(String(mime), isnothing(schema) ? nothing : String(schema))
Encoding(m::Base.MIME; schema::Union{Nothing, AbstractString} = nothing) =
    Encoding(string(m); schema = schema)

Base.string(e::Encoding) = isnothing(e.schema) ? e.mime : string(e.mime, ";", e.schema)
function Base.show(io::IO, e::Encoding)
    if isnothing(e.schema)
        print(io, "Encoding(", repr(e.mime), ")")
    else
        print(io, "Encoding(", repr(e.mime), "; schema=", repr(e.schema), ")")
    end
end
Base.:(==)(a::Encoding, b::Encoding) = a.mime == b.mime && a.schema == b.schema
Base.hash(e::Encoding, h::UInt) = hash(e.schema, hash(e.mime, hash(:ZenohEncoding, h)))

_as_encoding(e::Encoding) = e
_as_encoding(s::AbstractString) = Encoding(s)
_as_encoding(m::Base.MIME) = Encoding(m)

# Allocate a libzenoh-owned encoding from a Julia Encoding. The result must
# either be moved into a put/get call (libzenoh takes ownership) or be
# dropped — the finalizer handles the latter. Dropping a moved-from encoding
# is a no-op per zenoh-c semantics, so the finalizer is safe in either case.
function _to_owned_encoding(e::Encoding)
    ref = Ref{LibZenohC.z_owned_encoding_t}()
    mime = e.mime
    GC.@preserve mime _handle_result(LibZenohC.z_encoding_from_str(ref,
        pointer(Base.unsafe_convert(Cstring, mime))))
    if !isnothing(e.schema)
        schema = e.schema
        GC.@preserve schema _handle_result(LibZenohC.z_encoding_set_schema_from_str(
            LibZenohC.z_encoding_loan_mut(ref),
            pointer(Base.unsafe_convert(Cstring, schema))))
    end
    finalizer(r -> LibZenohC.z_encoding_drop(_move(r)), ref)
    return ref
end

function _from_loaned_encoding(p::Ptr{LibZenohC.z_loaned_encoding_t})
    out = Ref{LibZenohC.z_owned_string_t}()
    LibZenohC.z_encoding_to_string(p, out)
    str = _string(out)
    _drop(_move(out))
    sep = findfirst(';', str)
    if isnothing(sep)
        return Encoding(str)
    else
        return Encoding(str[1:sep-1]; schema = str[sep+1:end])
    end
end

module Encodings
    import ..Zenoh: Encoding
    const APPLICATION_CBOR                 = Encoding("application/cbor")
    const APPLICATION_CDR                  = Encoding("application/cdr")
    const APPLICATION_COAP_PAYLOAD         = Encoding("application/coap-payload")
    const APPLICATION_JAVA_SERIALIZED_OBJECT = Encoding("application/java-serialized-object")
    const APPLICATION_JSON                 = Encoding("application/json")
    const APPLICATION_JSON_PATCH_JSON      = Encoding("application/json-patch+json")
    const APPLICATION_JSON_SEQ             = Encoding("application/json-seq")
    const APPLICATION_JSONPATH             = Encoding("application/jsonpath")
    const APPLICATION_JWT                  = Encoding("application/jwt")
    const APPLICATION_MP4                  = Encoding("application/mp4")
    const APPLICATION_OCTET_STREAM         = Encoding("application/octet-stream")
    const APPLICATION_OPENMETRICS_TEXT     = Encoding("application/openmetrics-text")
    const APPLICATION_PROTOBUF             = Encoding("application/protobuf")
    const APPLICATION_PYTHON_SERIALIZED_OBJECT = Encoding("application/python-serialized-object")
    const APPLICATION_SOAP_XML             = Encoding("application/soap+xml")
    const APPLICATION_SQL                  = Encoding("application/sql")
    const APPLICATION_X_WWW_FORM_URLENCODED = Encoding("application/x-www-form-urlencoded")
    const APPLICATION_XML                  = Encoding("application/xml")
    const APPLICATION_YAML                 = Encoding("application/yaml")
    const APPLICATION_YANG                 = Encoding("application/yang")

    const AUDIO_AAC                        = Encoding("audio/aac")
    const AUDIO_FLAC                       = Encoding("audio/flac")
    const AUDIO_MP4                        = Encoding("audio/mp4")
    const AUDIO_OGG                        = Encoding("audio/ogg")
    const AUDIO_VORBIS                     = Encoding("audio/vorbis")

    const IMAGE_BMP                        = Encoding("image/bmp")
    const IMAGE_GIF                        = Encoding("image/gif")
    const IMAGE_JPEG                       = Encoding("image/jpeg")
    const IMAGE_PNG                        = Encoding("image/png")
    const IMAGE_WEBP                       = Encoding("image/webp")

    const TEXT_CSS                         = Encoding("text/css")
    const TEXT_CSV                         = Encoding("text/csv")
    const TEXT_HTML                        = Encoding("text/html")
    const TEXT_JAVASCRIPT                  = Encoding("text/javascript")
    const TEXT_JSON                        = Encoding("text/json")
    const TEXT_JSON5                       = Encoding("text/json5")
    const TEXT_MARKDOWN                    = Encoding("text/markdown")
    const TEXT_PLAIN                       = Encoding("text/plain")
    const TEXT_XML                         = Encoding("text/xml")
    const TEXT_YAML                        = Encoding("text/yaml")

    const VIDEO_H261                       = Encoding("video/h261")
    const VIDEO_H263                       = Encoding("video/h263")
    const VIDEO_H264                       = Encoding("video/h264")
    const VIDEO_H265                       = Encoding("video/h265")
    const VIDEO_H266                       = Encoding("video/h266")
    const VIDEO_MP4                        = Encoding("video/mp4")
    const VIDEO_OGG                        = Encoding("video/ogg")
    const VIDEO_RAW                        = Encoding("video/raw")
    const VIDEO_VP8                        = Encoding("video/vp8")
    const VIDEO_VP9                        = Encoding("video/vp9")

    const ZENOH_BYTES                      = Encoding("zenoh/bytes")
    const ZENOH_SERIALIZED                 = Encoding("zenoh/serialized")
    const ZENOH_STRING                     = Encoding("zenoh/string")
end
