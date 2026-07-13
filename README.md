# Rerun.jl

Julia bindings for [Rerun](https://rerun.io), a viewer and SDK for multimodal, time-indexed data. `Rerun.log` saves native Julia types, your own declared types, or Rerun archetypes to a live viewer, an `.rrd` file, or a gRPC server; flat batches export zero-copy through Arrow.

Two features round out the logging core:

- Package extensions log StaticArrays vectors, colorants, images, geometry, rotations, and transforms directly as components.
- A query API loads recordings back as Tables.jl sources.

The [documentation](https://benchung.github.io/Rerun.jl/dev/) covers the whole surface: the logging APIs, [runnable examples](https://benchung.github.io/Rerun.jl/dev/examples/points3d/), the [interop mappings](https://benchung.github.io/Rerun.jl/dev/interop/), and the [API reference](https://benchung.github.io/Rerun.jl/dev/api/).

A spinning spiral of points, streamed to the live viewer:

```julia
using Rerun
using Rerun.Components, Rerun.Archetypes

rec = RecordingStream("spiral")
Rerun.spawn(rec)                # launch a viewer; or Rerun.save(rec, "spiral.rrd")

frame = Timeline("frame")
for f in 0:119
    Rerun.set_time(rec, frame, f)
    pts = [Position3D((cos(8π*i/200 + f/25), sin(8π*i/200 + f/25), i/100 - 1)) for i in 1:200]
    Rerun.log(rec, "spiral", Points3D(pts; colors = fill(Color(0x44aaffff), 200)))
end
flush(rec)
```
