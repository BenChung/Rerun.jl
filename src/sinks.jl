# Log sinks: the `rr_log_sink` tagged union (gRPC or file) + `set_sinks`.
#
# `set_sinks` attaches several sinks at once and drops any previously active ones;
# `save` and `connect_grpc` are single-sink shortcuts.

abstract type LogSink end

"""Stream to a gRPC server. Scheme must be `rerun://`, `rerun+http://`, or `rerun+https://`."""
struct GrpcSink <: LogSink
    url::String
end
GrpcSink(; url::AbstractString="rerun+http://127.0.0.1:9876/proxy") = GrpcSink(String(url))

"""Write to a `.rrd` file."""
struct FileSink <: LogSink
    path::String
end
FileSink(path::AbstractString) = FileSink(String(path))

# Fill a pre-allocated rr_log_sink (tagged union) in place. The backing url/path
# String must be kept alive by the caller for the duration of the C call.
function _fill_sink!(p::Ptr{LibRerunC.rr_log_sink}, s::GrpcSink)
    p.kind = UInt8(LibRerunC.RR_LOG_SINK_KIND_GRPC)
    p.grpc = LibRerunC.rr_grpc_sink(_rrstr(s.url))
    return
end
function _fill_sink!(p::Ptr{LibRerunC.rr_log_sink}, s::FileSink)
    p.kind = UInt8(LibRerunC.RR_LOG_SINK_KIND_FILE)
    p.file = LibRerunC.rr_file_sink(_rrstr(s.path))
    return
end

"""
    set_sinks(rec, sinks::LogSink...)

Route log data to one or more sinks, e.g.
`set_sinks(rec, FileSink("out.rrd"), GrpcSink())`. Replaces any previously
active sinks.
"""
function set_sinks(r::RecordingStream, sinks::LogSink...)
    _drain_exports()
    isempty(sinks) && throw(ArgumentError("set_sinks: provide at least one sink"))
    n = length(sinks)
    arr = Vector{LibRerunC.rr_log_sink}(undef, n)
    GC.@preserve sinks arr begin
        base = pointer(arr)
        for (i, s) in enumerate(sinks)
            _fill_sink!(base + (i - 1) * sizeof(LibRerunC.rr_log_sink), s)
        end
        checked(err -> LibRerunC.rr_recording_stream_set_sinks(r.handle, base, UInt32(n), err))
    end
    return r
end
