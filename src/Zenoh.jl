module Zenoh
using CClosure

include("../gen/LibZenohC.jl")

# Core machinery
include("core/ownership.jl")        # _move/_loan/_drop/_take + _string
include("core/result.jl")           # ZenohError, _handle_result
include("core/config.jl")           # Config
include("core/config_builder.jl")   # ZenohConfig + typed config sections
include("core/session.jl")          # Session
include("core/callback.jl")         # CallbackCtx, _CB_INIT_HOOKS
include("core/logging.jl")          # setup_logging, LogSeverity, LogStream, open_log_stream
include("core/closure_kinds.jl")    # @closure_kind
include("core/encoding.jl")         # Encoding, _to_owned_encoding
include("core/qos.jl")              # Locality, Priority, CongestionControl, …

# Primitive value types
include("types/bytes.jl")           # ZBytes, ZBytesReader, slice iterators
include("types/slice.jl")           # ZSlice
include("types/keyexpr.jl")         # Keyexpr struct + ops + kexpr"…" macro
include("types/sample.jl")          # Sample + accessors
include("types/serializer.jl")      # ZSerializer/ZDeserializer (ze_* structured codec)
include("types/timestamp.jl")       # ZTimestamp

# Pub/sub + query/queryable
include("messaging/publisher.jl")   # Publisher, put
include("messaging/channel.jl")     # Reply, SubscriberHandler, GetHandler, get
include("messaging/subscriber.jl")  # Subscriber, callback + channel open
include("messaging/get_callback.jl")# callback-form get
include("messaging/queryable.jl")   # Query, Queryable

# Higher-level features
include("features/liveliness.jl")
include("features/querier.jl")
include("features/matching.jl")
include("features/advanced_pubsub.jl")  # AdvancedPublisher/Subscriber, delete!, SampleMissListener
include("features/scout.jl")
export scout, Hello, whatami_string

# Shared memory
include("shm/shm_client.jl")
include("shm/shm.jl")

# Typed, transport-agnostic payload handle (depends on Session, Sample,
# ZBytes, Publisher and the SHM types above).
include("types/zref.jl")

# Build all @cfunction pointers + dlsym lookups at runtime. Each
# callback file registered a hook via `_register_init!` in callback.jl;
# they all fire here. @cfunction at module top level would serialize a
# JIT address into the precompile image — invalid on reload.
function __init__()
    for hook in _CB_INIT_HOOKS
        hook()
    end
end

end # module Zenoh
