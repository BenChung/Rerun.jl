# RecordingStream: owning wrapper around the rerun_c stream handle.

"""
    RecordingStream(application_id; recording_id=nothing, default_enabled=true)

Create a recording stream. The handle is freed by a finalizer (or eagerly via
`close(rec)`); call `flush(rec)` before exit to guarantee delivery. Attach a
sink with [`save`](@ref), [`connect_grpc`](@ref), [`spawn`](@ref), or
[`to_stdout`](@ref).
"""
mutable struct RecordingStream
    handle::LibRerunC.rr_recording_stream

    function RecordingStream(application_id::AbstractString;
                             recording_id::Union{AbstractString,Nothing}=nothing,
                             default_enabled::Bool=true)
        appid = String(application_id)
        rid = recording_id === nothing ? nothing : String(recording_id)
        si = Ref(LibRerunC.rr_store_info(_rrstr(appid), _rrstr(rid), LibRerunC.RR_STORE_KIND_RECORDING))
        handle = GC.@preserve appid rid si begin
            checked() do err
                LibRerunC.rr_recording_stream_new(
                    Base.unsafe_convert(Ptr{LibRerunC.rr_store_info}, si), default_enabled, err)
            end
        end
        return finalizer(_free!, new(handle))
    end
end

Base.show(io::IO, r::RecordingStream) = print(io, "RecordingStream(handle=", r.handle, ")")

# Free the handle and mark it freed (idempotent). 0 = null/invalid; the
# 0xffff_ffff/0xffff_fffe values are the current-recording/blueprint sentinels,
# which `rr_recording_stream_free` is documented to no-op on anyway.
function _free!(r::RecordingStream)
    h = r.handle
    if h != 0 && h != LibRerunC.RR_REC_STREAM_CURRENT_RECORDING && h != LibRerunC.RR_REC_STREAM_CURRENT_BLUEPRINT
        LibRerunC.rr_recording_stream_free(h)
    end
    r.handle = LibRerunC.rr_recording_stream(0)
    return nothing
end

"""Free the stream's handle eagerly (idempotent). Freeing only triggers a
*non-blocking* flush, so call `flush(rec)` first if you need delivery."""
Base.close(r::RecordingStream) = _free!(r)

is_enabled(r::RecordingStream) = checked(err -> LibRerunC.rr_recording_stream_is_enabled(r.handle, err))

# rr_string-typed ccall arguments take a plain Julia string directly: ccall
# applies Base.cconvert/unsafe_convert (see marshal.jl) and roots it for the call.

"""Stream all log data to a `.rrd` file at `path`."""
function save(r::RecordingStream, path::AbstractString)
    _drain_exports()
    checked(err -> LibRerunC.rr_recording_stream_save(r.handle, path, err))
    return r
end

"""Connect to a running viewer over gRPC (default `rerun+http://127.0.0.1:9876/proxy`)."""
function connect_grpc(r::RecordingStream, url::AbstractString="rerun+http://127.0.0.1:9876/proxy")
    _drain_exports()
    checked(err -> LibRerunC.rr_recording_stream_connect_grpc(r.handle, url, err))
    return r
end

"""
    SpawnOptions(; port=0, memory_limit="", server_memory_limit="",
                   hide_welcome_screen=false, detach_process=false,
                   executable_name="", executable_path="")

Options for spawning the Rerun Viewer. Empty/zero fields use rerun's defaults
(port 9876, `rerun` on PATH, 75% memory limit, …).
"""
Base.@kwdef struct SpawnOptions
    port::UInt16 = 0
    memory_limit::String = ""
    server_memory_limit::String = ""
    hide_welcome_screen::Bool = false
    detach_process::Bool = false
    executable_name::String = ""
    executable_path::String = ""
end

# Build rr_spawn_options and run `f(ptr)` with the strings kept alive.
function _with_spawn_options(f, so::SpawnOptions)
    GC.@preserve so begin
        opts = LibRerunC.rr_spawn_options(so.port, _rrstr(so.memory_limit), _rrstr(so.server_memory_limit),
            so.hide_welcome_screen, so.detach_process, _rrstr(so.executable_name), _rrstr(so.executable_path))
        ref = Ref(opts)
        GC.@preserve ref f(Base.unsafe_convert(Ptr{LibRerunC.rr_spawn_options}, ref))
    end
end

"""Spawn a Rerun Viewer process and connect this stream to it over gRPC. Keyword
options (see [`SpawnOptions`](@ref)) configure the spawned process."""
function spawn(r::RecordingStream; opts...)
    _drain_exports()
    if isempty(opts)
        checked(err -> LibRerunC.rr_recording_stream_spawn(r.handle, C_NULL, err))
    else
        _with_spawn_options(SpawnOptions(; opts...)) do p
            checked(err -> LibRerunC.rr_recording_stream_spawn(r.handle, p, err))
        end
    end
    return r
end

"""Spawn a Rerun Viewer process (no stream attached). See [`SpawnOptions`](@ref)."""
function spawn(; opts...)
    if isempty(opts)
        checked(err -> LibRerunC.rr_spawn(C_NULL, err))
    else
        _with_spawn_options(SpawnOptions(; opts...)) do p
            checked(err -> LibRerunC.rr_spawn(p, err))
        end
    end
    return nothing
end

"""
    serve_grpc(rec; bind_ip="0.0.0.0", port=9876, server_memory_limit="25%",
               newest_first=false, cors_allow_origins=String[])

Serve this stream's data from an in-process gRPC server (viewers connect to
`rerun+http://{bind_ip}:{port}/proxy`). Buffers data up to `server_memory_limit`.
"""
function serve_grpc(r::RecordingStream; bind_ip::AbstractString="0.0.0.0", port::Integer=9876,
                    server_memory_limit::AbstractString="25%", newest_first::Bool=false,
                    cors_allow_origins=String[])
    _drain_exports()
    cors = String[String(o) for o in cors_allow_origins]
    corsarr = LibRerunC.rr_string[_rrstr(c) for c in cors]
    GC.@preserve cors corsarr begin
        ptr = isempty(corsarr) ? Ptr{LibRerunC.rr_string}(C_NULL) : pointer(corsarr)
        checked(err -> LibRerunC.rr_recording_stream_serve_grpc(r.handle, bind_ip, UInt16(port),
            server_memory_limit, newest_first, ptr, UInt32(length(corsarr)), err))
    end
    return r
end

"""Stream all log data to stdout (pipe into the viewer)."""
function to_stdout(r::RecordingStream)
    _drain_exports()
    checked(err -> LibRerunC.rr_recording_stream_stdout(r.handle, err))
    return r
end

"""Flush the pipeline and block until it propagates (or `timeout_sec` elapses)."""
function Base.flush(r::RecordingStream; timeout_sec::Real=2.0)
    checked(err -> LibRerunC.rr_recording_stream_flush_blocking(r.handle, Float32(timeout_sec), err))
    _drain_exports()
    return r
end

const _TIME_TYPES = Dict(
    :sequence  => LibRerunC.RR_TIME_TYPE_SEQUENCE,
    :duration  => LibRerunC.RR_TIME_TYPE_DURATION,
    :timestamp => LibRerunC.RR_TIME_TYPE_TIMESTAMP,
)

"""
    set_time(rec, timeline, value; kind=:sequence)

Set the current index on `timeline` for the calling thread (applies to
subsequent logs from this thread). `kind ∈ (:sequence, :duration, :timestamp)`;
for `:duration`/`:timestamp`, `value` is in **nanoseconds**.
"""
function set_time(r::RecordingStream, timeline::AbstractString, value::Integer; kind::Symbol=:sequence)
    _drain_exports()
    tt = get(_TIME_TYPES, kind) do
        error("unknown time kind $kind; expected :sequence, :duration, or :timestamp")
    end
    checked(err -> LibRerunC.rr_recording_stream_set_time(r.handle, timeline, tt, Int64(value), err))
    return r
end

reset_time(r::RecordingStream) = (LibRerunC.rr_recording_stream_reset_time(r.handle); r)

"""Stop logging to `timeline` for subsequent calls (no-op if it doesn't exist)."""
function disable_timeline(r::RecordingStream, timeline::AbstractString)
    checked(err -> LibRerunC.rr_recording_stream_disable_timeline(r.handle, timeline, err))
    return r
end

const _STORE_KINDS = Dict(:recording => LibRerunC.RR_STORE_KIND_RECORDING,
                          :blueprint => LibRerunC.RR_STORE_KIND_BLUEPRINT)
_store_kind(k::Symbol) = get(() -> error("unknown store kind $k; expected :recording or :blueprint"),
                             _STORE_KINDS, k)

"""Install this stream as the global current recording (`kind ∈ (:recording,:blueprint)`),
so it's used by APIs targeting the current recording. rerun holds its own
reference, so the stream survives this object being GC'd."""
set_global!(r::RecordingStream; kind::Symbol=:recording) =
    (LibRerunC.rr_recording_stream_set_global(r.handle, _store_kind(kind)); r)

"""Like [`set_global!`](@ref) but for the current thread's scope."""
set_thread_local!(r::RecordingStream; kind::Symbol=:recording) =
    (LibRerunC.rr_recording_stream_set_thread_local(r.handle, _store_kind(kind)); r)

"""
    log_file(rec, path; entity_path_prefix="", static=false)

Log the file at `path` using all available importers (images, meshes, `.rrd`, …).
Blocks until at least one importer starts streaming or all fail.
"""
function log_file(r::RecordingStream, path::AbstractString;
                  entity_path_prefix::AbstractString="", static::Bool=false)
    _drain_exports()
    checked(err -> LibRerunC.rr_recording_stream_log_file_from_path(r.handle, path, entity_path_prefix, static, err))
    return r
end

"""
    log_file_contents(rec, path, contents::AbstractVector{UInt8}; entity_path_prefix="", static=false)

Like [`log_file`](@ref) but importing in-memory `contents` (`path` is used only
to guide importer selection).
"""
function log_file_contents(r::RecordingStream, path::AbstractString, contents::AbstractVector{UInt8};
                           entity_path_prefix::AbstractString="", static::Bool=false)
    _drain_exports()
    c = contents isa Vector{UInt8} ? contents : Vector{UInt8}(contents)
    GC.@preserve c checked(err -> LibRerunC.rr_recording_stream_log_file_from_contents(
        r.handle, path, c, entity_path_prefix, static, err))
    return r
end

# --- component-type registration (global, cached by the descriptor `component`) ---
# Bare component logs use component == component_type (empty archetype); archetype
# logs use the qualified field name (e.g. "Points3D:positions"), which is a
# distinct descriptor and therefore a distinct handle.
const _HANDLES = Dict{String,LibRerunC.rr_component_type_handle}()
const _HANDLES_LOCK = ReentrantLock()

function _handle(archetype::AbstractString, component::AbstractString,
                 component_type::AbstractString, t::ArrowType)
    lock(_HANDLES_LOCK)
    try
        # Fast path: cached lookup keyed by `component`, no String copy / closure.
        h = get(_HANDLES, component, LibRerunC.RR_COMPONENT_TYPE_HANDLE_INVALID)
        h == LibRerunC.RR_COMPONENT_TYPE_HANDLE_INVALID || return h
        # nullable=true: component batches are sparse — this lets us log `missing`
        # (null_count>0) against the same registered schema.
        schema = _build_schema(t, last(split(component_type, '.')), true)
        # rerun takes ownership of the schema and releases it (freeing the malloc'd
        # format/name/children) on both success and failure, including the
        # ARROW_FFI_SCHEMA_IMPORT_ERROR path. A Julia-side cleanup on the throwing
        # path would double-free, so there is none.
        a = String(archetype); c = String(component); ct = String(component_type)
        h = GC.@preserve a c ct begin
            desc = LibRerunC.rr_component_descriptor(_rrstr(a), _rrstr(c), _rrstr(ct))
            checked(err -> LibRerunC.rr_register_component_type(
                LibRerunC.rr_component_type(desc, schema), err))
        end
        _HANDLES[c] = h
        return h
    finally
        unlock(_HANDLES_LOCK)
    end
end

# Build one data row from `specs`, a *tuple* of `(handle, ArrowType, data)`.
# `specs` has a compile-time-known length, so `map` yields a stack `NTuple`
# (no heap Vector) whose address we hand to rerun. Each `data` is kept alive by
# the export registry until release; `bref`/`ep` are preserved across the call.
@inline function _log_tuple(r::RecordingStream, entity_path::AbstractString, specs::Tuple; inject_time::Bool=true)
    _drain_exports()
    isempty(specs) && return r
    batches = map(specs) do s
        LibRerunC.rr_component_batch(s[1], _build_component_array(s[2], s[3]))
    end
    try
        bref = Ref(batches)
        ep = String(entity_path)
        GC.@preserve bref ep begin
            pb = Ptr{LibRerunC.rr_component_batch}(Base.unsafe_convert(Ptr{typeof(batches)}, bref))
            row = LibRerunC.rr_data_row(_rrstr(ep), UInt32(length(specs)), pb)
            checked(err -> LibRerunC.rr_recording_stream_log(r.handle, row, inject_time, err))
        end
    catch
        # The log failed -> rerun never took ownership, so its release callback will
        # never fire. Release the built arrays ourselves (frees C bookkeeping and
        # unpins zero-copy roots) instead of leaking them and the GC roots forever.
        for b in batches; _release_unpublished(b.array); end
        rethrow()
    end
    return r
end

_lookup_component(ct) = get(COMPONENT_TYPES, ct) do
    error("unknown component type $ct (not in generated catalog)")
end

"""
    log(rec, entity_path, component_type, data::AbstractVector; inject_time=true)

Zero-copy log a single component batch. `data`'s element layout must match the
component's Arrow datatype (e.g. `Vector{NTuple{3,Float32}}` for
`"rerun.components.Position3D"`). `data` is kept alive until rerun releases it.
"""
function log(r::RecordingStream, entity_path::AbstractString,
             component_type::AbstractString, data::AbstractVector; inject_time::Bool=true)
    t = _lookup_component(component_type)
    h = _handle("", component_type, component_type, t)
    _log_tuple(r, entity_path, ((h, t, data),); inject_time=inject_time)
end

"""
    log(rec, entity_path, component_type => data, ...; inject_time=true)

Log several component batches as a single row, e.g.
`log(rec, "world/points", "rerun.components.Position3D"=>pts, "rerun.components.Color"=>cols)`.
"""
function log(r::RecordingStream, entity_path::AbstractString,
             batches::Pair{<:AbstractString,<:AbstractVector}...; inject_time::Bool=true)
    specs = map(batches) do (ct, data)
        t = _lookup_component(ct)
        (_handle("", ct, ct, t), t, data)
    end
    _log_tuple(r, entity_path, specs; inject_time=inject_time)
end

function _archetype_field(afields, name::Symbol, archetype)
    s = String(name)
    for f in afields
        f.field == s && return f
    end
    error("archetype $archetype has no field `$s` (fields: $(join([f.field for f in afields], ", ")))")
end

"""
    log_archetype(rec, entity_path, archetype; field=data, ...; inject_time=true)

Log an archetype as one row, e.g.
`log_archetype(rec, "world/points", "rerun.archetypes.Points3D"; positions=pts, colors=cols, radii=rad)`.
Each keyword names an archetype field; its component type and archetype-qualified
descriptor (e.g. `Points3D:positions`) are resolved from the generated catalog.
"""
function log_archetype(r::RecordingStream, entity_path::AbstractString,
                       archetype::AbstractString; inject_time::Bool=true, fields...)
    afields = get(ARCHETYPES, archetype) do
        error("unknown archetype $archetype (not in generated catalog)")
    end
    isempty(fields) && error("log_archetype: no fields given for $archetype")
    # keys(fields) is a compile-time tuple of Symbols, so specs is a tuple.
    specs = map(keys(fields)) do name
        af = _archetype_field(afields, name, archetype)
        t = _lookup_component(af.component_type)
        (_handle(archetype, af.component, af.component_type, t), t, fields[name])
    end
    _log_tuple(r, entity_path, specs; inject_time=inject_time)
end
