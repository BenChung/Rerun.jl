# Rerun.jl

Idiomatic Julia bindings over the [Rerun](https://rerun.io) C SDK (`rerun_c`,
pinned to SDK 0.33.0).

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

See the [Examples](examples/points3d.md) for points, a components tour, text
labels, scalar time series, tensors, driving a live viewer, reading data back
out as a DataFrame, and blueprint enums; and the [API Reference](api.md) for
the full surface.

## Three logging APIs

Every surface feeds the same zero-copy Arrow exporter; they differ only in how
they name the component.

### Logging typed components and archetypes

The generated structs in `Rerun.Components` and `Rerun.Archetypes` carry both
the data and the component identity, so dispatch resolves everything at compile
time and flat batches log zero-copy:

```julia
using Rerun.Components, Rerun.Archetypes

Rerun.log(rec, "world/points", Points3D(pts; colors = cols))  # archetype, kwargs per field
Rerun.log(rec, "world/points", pts, cols)                     # bare component batches
```

See [`Rerun.log`](@ref) and the [Points & archetypes](examples/points3d.md)
example.

### Logging your own types as components

Declarations map your element type onto a component: a constructor method
converts any layout, [`Rerun.wire_compatible`](@ref) claims an exact layout
zero-copy, and [`Rerun.component`](@ref) names the target for bare vectors.
Declared vectors log everywhere a component batch fits:

```julia
struct XYZ; x::Float32; y::Float32; z::Float32; end
Rerun.wire_compatible(::Type{XYZ}, ::Type{Position3D}) = true

Rerun.log(rec, "cloud", Position3D, xyzs)   # zero-copy
```

The package extensions declare these mappings for ecosystem types
(StaticArrays vectors, colorants, images, geometry, rotations, transforms).
[Interop](interop.md) lists each extension's mappings and walks through
declaring your own.

### Logging by catalog name

Catalog names from the Rerun IDL identify the component or archetype. Generic
tooling uses this form, and components without a generated struct (bool and
struct layouts) require it:

```julia
Rerun.log(rec, "world/points", "rerun.components.Position3D" => pts)
Rerun.log_archetype(rec, "world/points", "rerun.archetypes.Points3D"; positions = pts)
```

See [`Rerun.log_archetype`](@ref), with [`Rerun.component_arrow_type`](@ref)
and [`Rerun.archetype_fields`](@ref) for catalog introspection.

### Sending columns in bulk

[`Rerun.send_columns`](@ref) sends whole columns in one call, pairing
[`Timeline`](@ref) index columns with typed or string component columns.
[`Rerun.columns`](@ref) tags the component columns with an archetype (e.g.
`Scalars`), so the viewer plots them without manual blueprint setup — see
the [Scalar time series](examples/timeseries.md) example.
