# API Reference

Functions are accessed as `Rerun.f(...)` unless exported. Materialized
component / archetype / enum types live in the `Rerun.Components`,
`Rerun.Archetypes`, and `Rerun.Blueprint` submodules (generated from the Rerun
IDL); bring them into scope with `using Rerun.Components`, etc.

```@contents
Pages = ["api.md"]
Depth = 2
```

## Recording streams

A [`RecordingStream`](@ref) is the write handle: everything you log goes
through one.

```@docs
RecordingStream
Rerun.is_enabled
Base.close(::Rerun.RecordingStream)
Base.flush(::Rerun.RecordingStream)
Rerun.set_global!
Rerun.set_thread_local!
```

## Sinks

Sinks decide where a stream's data goes: a file, a viewer, or an in-process
server.

```@docs
LogSink
GrpcSink
FileSink
Rerun.set_sinks
Rerun.save
Rerun.connect_grpc
Rerun.spawn
Rerun.SpawnOptions
Rerun.serve_grpc
Rerun.to_stdout
```

## Time & timelines

A [`Timeline`](@ref) names an index and its time representation; time values
are `Int64` (sequence), `Nanosecond` (duration), or [`TimePoint`](@ref)
(timestamp). The same types drive row logging ([`set_time`](@ref Rerun.set_time)),
columnar logging ([`TimeColumn`](@ref)), and query results.

```@docs
Timeline
Rerun.kind
TimePoint
Rerun.set_time
Rerun.reset_time
Rerun.disable_timeline
```

## Logging rows

Each call logs one row — component batches or an archetype — at the stream's
current time.

```@docs
Rerun.log
Rerun.log_archetype
Rerun.log_tensor
Rerun.log_file
Rerun.log_file_contents
```

## Logging columns

One call sends whole columns: time columns index the rows, component columns
carry the data. [`Rerun.columns`](@ref) tags the component columns with an
archetype so the viewer selects visualizers automatically.

```@docs
Rerun.send_columns
Rerun.columns
TimeColumn
```

## Querying recordings

Load an `.rrd`, build a view over one of its timelines, and read the result as
a Tables.jl source.

```@docs
Rerun.load_recording
Rerun.Recording
Rerun.timelines
Rerun.timeline
Rerun.view
Rerun.RecordingView
Rerun.set_contents!
Rerun.filter_range
Rerun.fill_latest_at
Rerun.select
Rerun.QueryResult
Rerun.ArrowColumn
```

## Interop (custom types)

Traits that map your own element types onto components; the [Interop](interop.md)
page shows the declarations in use.

```@docs
Rerun.component
Rerun.wire_compatible
Rerun.InteropError
```

## Introspection & utilities

```@docs
Rerun.component_arrow_type
Rerun.archetype_fields
Rerun.version
Rerun.escape_entity_path_part
Rerun.video_frame_timestamps_nanos
```

## Errors

```@docs
RerunError
```
