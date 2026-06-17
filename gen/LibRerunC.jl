module LibRerunC

using librerun_c_jll
export librerun_c_jll

using CEnum: CEnum, @cenum

struct ArrowSchema
    format::Ptr{Cchar}
    name::Ptr{Cchar}
    metadata::Ptr{Cchar}
    flags::Int64
    n_children::Int64
    children::Ptr{Ptr{ArrowSchema}}
    dictionary::Ptr{ArrowSchema}
    release::Ptr{Cvoid}
    private_data::Ptr{Cvoid}
end

struct ArrowArray
    length::Int64
    null_count::Int64
    offset::Int64
    n_buffers::Int64
    n_children::Int64
    buffers::Ptr{Ptr{Cvoid}}
    children::Ptr{Ptr{ArrowArray}}
    dictionary::Ptr{ArrowArray}
    release::Ptr{Cvoid}
    private_data::Ptr{Cvoid}
end

struct ArrowArrayStream
    get_schema::Ptr{Cvoid}
    get_next::Ptr{Cvoid}
    get_last_error::Ptr{Cvoid}
    release::Ptr{Cvoid}
    private_data::Ptr{Cvoid}
end

struct rr_string
    utf8::Ptr{Cchar}
    length_in_bytes::UInt32
end

struct rr_bytes
    bytes::Ptr{UInt8}
    length::UInt32
end

function rr_make_string(utf8)
    ccall((:rr_make_string, librerun_c), rr_string, (Ptr{Cchar},), utf8)
end

const rr_store_kind = UInt32

@cenum var"##Ctag#277"::UInt32 begin
    RR_STORE_KIND_RECORDING = 1
    RR_STORE_KIND_BLUEPRINT = 2
end

const rr_component_type_handle = UInt32

const rr_recording_stream = UInt32

struct rr_spawn_options
    port::UInt16
    memory_limit::rr_string
    server_memory_limit::rr_string
    hide_welcome_screen::Bool
    detach_process::Bool
    executable_name::rr_string
    executable_path::rr_string
end

struct rr_importer_settings
    recording_id::rr_string
    entity_path_prefix::rr_string
    static_::Bool
end

const rr_data_loader_settings = rr_importer_settings

struct rr_store_info
    application_id::rr_string
    recording_id::rr_string
    store_kind::rr_store_kind
end

struct rr_component_descriptor
    archetype::rr_string
    component::rr_string
    component_type::rr_string
end

struct rr_component_type
    descriptor::rr_component_descriptor
    schema::ArrowSchema
end

struct rr_component_batch
    component_type::rr_component_type_handle
    array::ArrowArray
end

struct rr_data_row
    entity_path::rr_string
    num_component_batches::UInt32
    component_batches::Ptr{rr_component_batch}
end

struct rr_component_column
    component_type::rr_component_type_handle
    array::ArrowArray
end

const rr_sorting_status = UInt32

@cenum var"##Ctag#278"::UInt32 begin
    RR_SORTING_STATUS_UNKNOWN = 0
    RR_SORTING_STATUS_SORTED = 1
    RR_SORTING_STATUS_UNSORTED = 2
end

const rr_time_type = UInt32

@cenum var"##Ctag#279"::UInt32 begin
    RR_TIME_TYPE_SEQUENCE = 1
    RR_TIME_TYPE_DURATION = 2
    RR_TIME_TYPE_TIMESTAMP = 3
end

struct rr_timeline
    name::rr_string
    type::rr_time_type
end

struct rr_time_column
    timeline::rr_timeline
    array::ArrowArray
    sorting_status::rr_sorting_status
end

struct rr_grpc_sink
    url::rr_string
end

struct rr_file_sink
    path::rr_string
end

@cenum var"##Ctag#280"::UInt32 begin
    RR_LOG_SINK_KIND_GRPC = 0
    RR_LOG_SINK_KIND_FILE = 1
end

const rr_log_sink_kind = UInt8

struct rr_log_sink
    data::NTuple{24, UInt8}
end

function Base.getproperty(x::Ptr{rr_log_sink}, f::Symbol)
    f === :kind && return Ptr{rr_log_sink_kind}(x + 0)
    f === :grpc && return Ptr{rr_grpc_sink}(x + 8)
    f === :file && return Ptr{rr_file_sink}(x + 8)
    return getfield(x, f)
end

function Base.getproperty(x::rr_log_sink, f::Symbol)
    r = Ref{rr_log_sink}(x)
    ptr = Base.unsafe_convert(Ptr{rr_log_sink}, r)
    fptr = getproperty(ptr, f)
    GC.@preserve r unsafe_load(fptr)
end

function Base.setproperty!(x::Ptr{rr_log_sink}, f::Symbol, v)
    unsafe_store!(getproperty(x, f), v)
end

function Base.propertynames(x::rr_log_sink, private::Bool = false)
    (:kind, :grpc, :file, if private
            fieldnames(typeof(x))
        else
            ()
        end...)
end

const rr_error_code = UInt32

@cenum var"##Ctag#281"::UInt32 begin
    RR_ERROR_CODE_OK = 0
    RR_ERROR_CODE_OUT_OF_MEMORY = 1
    RR_ERROR_CODE_NOT_IMPLEMENTED = 2
    RR_ERROR_CODE_SDK_VERSION_MISMATCH = 3
    _RR_ERROR_CODE_CATEGORY_ARGUMENT = 16
    RR_ERROR_CODE_UNEXPECTED_NULL_ARGUMENT = 17
    RR_ERROR_CODE_INVALID_STRING_ARGUMENT = 18
    RR_ERROR_CODE_INVALID_ENUM_VALUE = 19
    RR_ERROR_CODE_INVALID_RECORDING_STREAM_HANDLE = 20
    RR_ERROR_CODE_INVALID_SOCKET_ADDRESS = 21
    RR_ERROR_CODE_INVALID_COMPONENT_TYPE_HANDLE = 22
    RR_ERROR_CODE_INVALID_TIME_ARGUMENT = 23
    RR_ERROR_CODE_INVALID_TENSOR_DIMENSION = 24
    RR_ERROR_CODE_INVALID_COMPONENT = 25
    RR_ERROR_CODE_INVALID_SERVER_URL = 26
    RR_ERROR_CODE_FILE_READ = 27
    RR_ERROR_CODE_INVALID_MEMORY_LIMIT = 28
    _RR_ERROR_CODE_CATEGORY_RECORDING_STREAM = 256
    RR_ERROR_CODE_RECORDING_STREAM_RUNTIME_FAILURE = 257
    RR_ERROR_CODE_RECORDING_STREAM_CREATION_FAILURE = 258
    RR_ERROR_CODE_RECORDING_STREAM_SAVE_FAILURE = 259
    RR_ERROR_CODE_RECORDING_STREAM_STDOUT_FAILURE = 260
    RR_ERROR_CODE_RECORDING_STREAM_SPAWN_FAILURE = 261
    RR_ERROR_CODE_RECORDING_STREAM_CHUNK_VALIDATION_FAILURE = 262
    RR_ERROR_CODE_RECORDING_STREAM_SERVE_GRPC_FAILURE = 263
    RR_ERROR_CODE_RECORDING_STREAM_FLUSH_TIMEOUT = 264
    RR_ERROR_CODE_RECORDING_STREAM_FLUSH_FAILURE = 265
    _RR_ERROR_CODE_CATEGORY_ARROW = 4096
    RR_ERROR_CODE_ARROW_FFI_SCHEMA_IMPORT_ERROR = 4097
    RR_ERROR_CODE_ARROW_FFI_ARRAY_IMPORT_ERROR = 4098
    _RR_ERROR_CODE_CATEGORY_UTILITIES = 65536
    RR_ERROR_CODE_VIDEO_LOAD_ERROR = 65537
    _RR_ERROR_CODE_CATEGORY_FILE_IO = 1048576
    RR_ERROR_CODE_FILE_OPEN_FAILURE = 1048577
    _RR_ERROR_CODE_CATEGORY_ARROW_CPP_STATUS = 268435456
    RR_ERROR_CODE_UNKNOWN = 268435457
end

struct rr_error
    code::rr_error_code
    description::NTuple{2048, Cchar}
end

function rr_version_string()
    ccall((:rr_version_string, librerun_c), Ptr{Cchar}, ())
end

function rr_spawn(spawn_opts, error)
    ccall((:rr_spawn, librerun_c), Cvoid, (Ptr{rr_spawn_options}, Ptr{rr_error}), spawn_opts, error)
end

function rr_register_component_type(component_type, error)
    ccall((:rr_register_component_type, librerun_c), rr_component_type_handle, (rr_component_type, Ptr{rr_error}), component_type, error)
end

function rr_recording_stream_new(store_info, default_enabled, error)
    ccall((:rr_recording_stream_new, librerun_c), rr_recording_stream, (Ptr{rr_store_info}, Bool, Ptr{rr_error}), store_info, default_enabled, error)
end

function rr_recording_stream_free(stream)
    ccall((:rr_recording_stream_free, librerun_c), Cvoid, (rr_recording_stream,), stream)
end

function rr_recording_stream_set_global(stream, store_kind)
    ccall((:rr_recording_stream_set_global, librerun_c), Cvoid, (rr_recording_stream, rr_store_kind), stream, store_kind)
end

function rr_recording_stream_set_thread_local(stream, store_kind)
    ccall((:rr_recording_stream_set_thread_local, librerun_c), Cvoid, (rr_recording_stream, rr_store_kind), stream, store_kind)
end

function rr_recording_stream_is_enabled(stream, error)
    ccall((:rr_recording_stream_is_enabled, librerun_c), Bool, (rr_recording_stream, Ptr{rr_error}), stream, error)
end

function rr_recording_stream_set_sinks(stream, sinks, num_sinks, error)
    ccall((:rr_recording_stream_set_sinks, librerun_c), Cvoid, (rr_recording_stream, Ptr{rr_log_sink}, UInt32, Ptr{rr_error}), stream, sinks, num_sinks, error)
end

function rr_recording_stream_connect_grpc(stream, url, error)
    ccall((:rr_recording_stream_connect_grpc, librerun_c), Cvoid, (rr_recording_stream, rr_string, Ptr{rr_error}), stream, url, error)
end

function rr_recording_stream_serve_grpc(stream, bind_ip, port, server_memory_limit, newest_first, cors_allow_origins, num_cors_allow_origins, error)
    ccall((:rr_recording_stream_serve_grpc, librerun_c), Cvoid, (rr_recording_stream, rr_string, UInt16, rr_string, Bool, Ptr{rr_string}, UInt32, Ptr{rr_error}), stream, bind_ip, port, server_memory_limit, newest_first, cors_allow_origins, num_cors_allow_origins, error)
end

function rr_recording_stream_spawn(stream, spawn_opts, error)
    ccall((:rr_recording_stream_spawn, librerun_c), Cvoid, (rr_recording_stream, Ptr{rr_spawn_options}, Ptr{rr_error}), stream, spawn_opts, error)
end

function rr_recording_stream_save(stream, path, error)
    ccall((:rr_recording_stream_save, librerun_c), Cvoid, (rr_recording_stream, rr_string, Ptr{rr_error}), stream, path, error)
end

function rr_recording_stream_stdout(stream, error)
    ccall((:rr_recording_stream_stdout, librerun_c), Cvoid, (rr_recording_stream, Ptr{rr_error}), stream, error)
end

function rr_recording_stream_flush_blocking(stream, timeout_sec, error)
    ccall((:rr_recording_stream_flush_blocking, librerun_c), Cvoid, (rr_recording_stream, Cfloat, Ptr{rr_error}), stream, timeout_sec, error)
end

function rr_recording_stream_set_time(stream, timeline_name, time_type, value, error)
    ccall((:rr_recording_stream_set_time, librerun_c), Cvoid, (rr_recording_stream, rr_string, rr_time_type, Int64, Ptr{rr_error}), stream, timeline_name, time_type, value, error)
end

function rr_recording_stream_disable_timeline(stream, timeline_name, error)
    ccall((:rr_recording_stream_disable_timeline, librerun_c), Cvoid, (rr_recording_stream, rr_string, Ptr{rr_error}), stream, timeline_name, error)
end

function rr_recording_stream_reset_time(stream)
    ccall((:rr_recording_stream_reset_time, librerun_c), Cvoid, (rr_recording_stream,), stream)
end

function rr_recording_stream_log(stream, data_row, inject_time, error)
    ccall((:rr_recording_stream_log, librerun_c), Cvoid, (rr_recording_stream, rr_data_row, Bool, Ptr{rr_error}), stream, data_row, inject_time, error)
end

function rr_recording_stream_log_file_from_path(stream, path, entity_path_prefix, static_, error)
    ccall((:rr_recording_stream_log_file_from_path, librerun_c), Cvoid, (rr_recording_stream, rr_string, rr_string, Bool, Ptr{rr_error}), stream, path, entity_path_prefix, static_, error)
end

function rr_recording_stream_log_file_from_contents(stream, path, contents, entity_path_prefix, static_, error)
    ccall((:rr_recording_stream_log_file_from_contents, librerun_c), Cvoid, (rr_recording_stream, rr_string, rr_bytes, rr_string, Bool, Ptr{rr_error}), stream, path, contents, entity_path_prefix, static_, error)
end

function rr_recording_stream_send_columns(stream, entity_path, time_columns, num_time_columns, component_columns, num_component_columns, error)
    ccall((:rr_recording_stream_send_columns, librerun_c), Cvoid, (rr_recording_stream, rr_string, Ptr{rr_time_column}, UInt32, Ptr{rr_component_column}, UInt32, Ptr{rr_error}), stream, entity_path, time_columns, num_time_columns, component_columns, num_component_columns, error)
end

# typedef int64_t * ( * rr_alloc_timestamps ) ( void * alloc_context , uint32_t num_timestamps )
const rr_alloc_timestamps = Ptr{Cvoid}

function rr_video_asset_read_frame_timestamps_nanos(video_bytes, video_bytes_len, media_type, alloc_context, alloc_timestamps, error)
    ccall((:rr_video_asset_read_frame_timestamps_nanos, librerun_c), Ptr{Int64}, (Ptr{UInt8}, UInt64, rr_string, Ptr{Cvoid}, rr_alloc_timestamps, Ptr{rr_error}), video_bytes, video_bytes_len, media_type, alloc_context, alloc_timestamps, error)
end

function _rr_escape_entity_path_part(part)
    ccall((:_rr_escape_entity_path_part, librerun_c), Ptr{Cchar}, (rr_string,), part)
end

function _rr_free_string(string)
    ccall((:_rr_free_string, librerun_c), Cvoid, (Ptr{Cchar},), string)
end

const ARROW_FLAG_DICTIONARY_ORDERED = 1

const ARROW_FLAG_NULLABLE = 2

const ARROW_FLAG_MAP_KEYS_SORTED = 4

const RR_REC_STREAM_CURRENT_RECORDING = 0xffffffff

const RR_REC_STREAM_CURRENT_BLUEPRINT = 0xfffffffe

const RR_COMPONENT_TYPE_HANDLE_INVALID = 0xffffffff

const RERUN_SDK_HEADER_VERSION = "0.33.0"

const RERUN_SDK_HEADER_VERSION_MAJOR = 0

const RERUN_SDK_HEADER_VERSION_MINOR = 33

const RERUN_SDK_HEADER_VERSION_PATCH = 0

# exports
const PREFIXES = ["rr_"]
for name in names(@__MODULE__; all=true), prefix in PREFIXES
    if startswith(string(name), prefix)
        @eval export $name
    end
end

end # module
