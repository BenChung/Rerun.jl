# Rerun.jl

Idiomatic Julia bindings over the [Rerun](https://rerun.io) C SDK (`rerun_c`,
pinned to SDK 0.33.0). Rerun.jl logs multimodal data — points, meshes, images,
tensors, scalars, transforms — to the Rerun Viewer for live or recorded
visualization.

The binding wraps the full `rerun_c` C API and implements the Arrow C Data
Interface by hand, so logging Julia arrays is **zero-copy** on the hot paths:
when a component's wire layout matches your data's element layout, the values
buffer points straight into your `Vector` (kept alive until Rerun releases it).

## Highlights

- **Typed components & archetypes** that double as data carriers *and* dispatch
  tags — `Position3D`, `Color`, `Points3D`, `Transform3D`, … — generated from the
  vendored Rerun IDL. They live in the `Rerun.Components` and `Rerun.Archetypes`
  submodules (and viewer-config enums in `Rerun.Blueprint`).
- **Zero-copy logging** for flat components, lists/blobs, and columnar
  (`send_columns`) data, with `missing`/validity support.
- **Multiple sinks**: write a `.rrd` file, connect to a running viewer over
  gRPC, spawn a viewer, serve gRPC in-process, or stream to stdout.
- **Helpers** like [`log_tensor`](@ref Rerun.log_tensor) for N-dimensional arrays.

## Quick start

```julia
using Rerun
using Rerun.Components, Rerun.Archetypes

rec = RecordingStream("my_app")
Rerun.save(rec, "out.rrd")          # or: Rerun.spawn(rec) to launch the viewer

pts  = [Position3D((Float32(i), 0f0, 0f0)) for i in 1:100]
cols = [Color(0x44aaffff) for _ in 1:100]
Rerun.log(rec, "world/points", Points3D(pts; colors = cols))

flush(rec)
```

Open the result with `rerun out.rrd`, or swap `save` for `Rerun.spawn(rec)` to
stream to a live viewer.

See the [Examples](examples/points3d.md) for points, a components tour, scalar
time series, and tensors; and the [API Reference](api.md) for the full surface.

## Three logging APIs

1. **Typed** — `log(rec, path, Points3D(pts; colors))` or
   `log(rec, path, points::Vector{Position3D}, colors::Vector{Color})`. No
   strings, fully specialized, zero-copy.
2. **Interop** — `log(rec, path, Position3D, data::AbstractVector)` logs any
   layout-compatible vector as a component (zero-copy when the layout matches).
3. **String** — `log(rec, path, "rerun.components.Position3D" => pts, …)` and
   `log_archetype(rec, path, "rerun.archetypes.Points3D"; positions = pts)` for
   dynamic, catalog-driven use.
