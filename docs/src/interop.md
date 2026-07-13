# Interop (package extensions)

Rerun.jl maps ecosystem types onto components through package extensions:
loading the companion package activates its extension, and its types log
directly. Every mapping routes through the interop core; [Your own types](@ref)
shows how to attach yours to the same hooks.

Zero-copy holds whenever the element layout matches the component's wire
layout; every other mapping converts to the wire types (`Float32`, packed
`UInt32`, …) and copies.

With StaticArrays and ColorTypes loaded:

```julia
using Rerun, StaticArrays, ColorTypes
using Rerun.Components, Rerun.Archetypes

rec = RecordingStream("interop")
Rerun.save(rec, "interop.rrd")

helix = [SVector{3,Float32}(cos(t), sin(t), t / 8) for t in range(0, 8π; length = 200)]
shade = [RGB(t, 0.4, 1 - t) for t in range(0, 1; length = 200)]

Rerun.log(rec, "helix", helix)   # StaticVector batch logs as Position3D, zero-copy
Rerun.log(rec, "helix", shade)   # colorant batch packs into Color

# The same vectors as one row through an archetype: positions reinterpret,
# colorants convert through the Color constructor.
Rerun.log(rec, "helix", Points3D(helix; colors = Components.Color.(shade)))
flush(rec)
```

`Rerun.Components` and `ColorTypes` both export a `Color`; qualify it as
`Components.Color` when both are in scope.

## StaticArrays

| you have | maps to | notes |
|---|---|---|
| `Vector{<:StaticVector{3}}` | `Position3D` batch | zero-copy for `Float32` elements; other eltypes convert |
| `Vector{<:StaticVector{2}}` | `Position2D` batch | same |
| `StaticVector{2}` / `{3}` | `Position2D` / `Position3D` | constructor |
| `SMatrix{3,3}` | `TransformMat3x3` | constructor; both column-major, no transpose |

## ColorTypes

| you have | maps to | notes |
|---|---|---|
| RGB-family colorant | `Color` | constructor; packs `0xRRGGBBAA`, alpha-less get `0xff` |
| gray colorant | `Color` | constructor; r = g = b = value |
| `Vector{<:Colorant}` | `Color` batch | copies |

Convert other color spaces (HSV, Lab, …) with Colors.jl first.

## ImageCore

| you have | maps to | notes |
|---|---|---|
| `Matrix{<:Colorant}` (RGB family) | `Image` | RGB or RGBA from the channel count |
| gray or `Matrix{<:AbstractFloat}` | `DepthImage` | |
| `Matrix{<:Integer}` | `SegmentationImage` | |

Images re-layout into Rerun's row-major interleaved bytes (a copy).

## GeometryBasics

| you have | maps to | notes |
|---|---|---|
| `Rect{2}` / `Rect{3}` (or vectors) | `Boxes2D` / `Boxes3D` | origin + widths → center + half-size |
| `LineString`, `Polygon` | `LineStrips2D` / `LineStrips3D` | polygons log the exterior ring, loop closed |
| `Mesh`, `Triangle` | `Mesh3D` | vertices zero-copy; faces reindexed to 0-based |
| `HyperSphere{3}` (or vectors) | `Ellipsoids3D` | half-size `(r, r, r)` |

Points are `StaticVector`s, so the StaticArrays mapping covers them.

## Meshes

| you have | maps to | notes |
|---|---|---|
| `Meshes.Point` (or vectors) | `Position2D` / `Position3D` | 2D or 3D from the embedding dimension |
| `Segment`, `Rope`, `Ring` | `LineStrips2D` / `LineStrips3D` | `Ring` closes the loop |
| `Triangle`, `Ngon`, `SimpleMesh` | `Mesh3D` | fan-triangulated; indices reindexed to 0-based |
| `Box` (3D) | `Boxes3D` | min/max corners → center + half-size |
| `Ball`, `Sphere` | `Ellipsoids3D` | half-size `(r, r, r)` |

Coordinates convert to `Float32`, stripping Unitful units.

## Rotations

| you have | maps to | notes |
|---|---|---|
| `QuatRotation` (or any `Rotation{3}`) | `RotationQuat` | constructor; reordered to Rerun's `(x, y, z, w)` |
| `RotMatrix{3}` | `TransformMat3x3` | constructor |
| `AngleAxis`, `RotMatrix{3}`, `Rotation{3}` | `Transform3D(R; kwargs...)` | each through its faithful field: axis-angle, mat3x3, quaternion |

## Quaternions

| you have | maps to | notes |
|---|---|---|
| `Quaternion` | `RotationQuat` | constructor; scalar-first `(w, x, y, z)` reordered to `(x, y, z, w)` |
| `Vector{<:Quaternion}` | `RotationQuat` batch | logs directly |

## CoordinateTransformations

| you have | maps to | notes |
|---|---|---|
| `Translation` | `Transform3D` | translation field |
| `LinearMap` | `Transform3D` | rotation via the Rotations extension when loaded, generic `mat3x3` otherwise |
| `AffineMap` | `Transform3D` | translation + linear part |

All three log directly and build `Transform3D` constructors.

## Your own types

Custom types can be logged through one of two mechanisms depending on their
memory layout:

- **Element layout matches the component's wire layout**: log the vector
  directly. The batch is zero-copy.
- **Any other layout**: add a constructor method on the component. The
  conversion copies.

### Logging the vector directly

Flat components store a numeric scalar or a fixed-size vector of numbers on
the wire: `Position3D` is three `Float32`s, `Radius` is one `Float32`, and
`Color` is one packed `UInt32`. Direct logging applies when your element type
is isbits with exactly that wire layout. For example, a struct of three `Float32`
fields lays out like `Position3D`:

```julia
struct XYZ; x::Float32; y::Float32; z::Float32; end
```

`Rerun.log(rec, path, Component, data)` reinterprets `data` as a zero-copy
batch of `Component`. A mismatched element width throws an element-size
mismatch error.

```julia
xyzs = [XYZ(0, 0, 0), XYZ(1, 1, 1)]

Rerun.log(rec, "cloud", Position3D, xyzs)
```

### Adding a constructor method

A constructor method covers every other layout. `Waypoint` stores `Float64`
fields with latitude before longitude, so neither its width nor its field
order matches `Position3D`:

```julia
struct Waypoint; lat::Float64; lon::Float64; alt::Float64; end
```

Define a constructor method on the component and put the field reordering and
conversion inside it. The bundled extensions attach through this same hook.
Broadcast the constructor over your data to build a typed batch. The batch
logs directly or fills any archetype field:

```julia
Rerun.Components.Position3D(w::Waypoint) = Position3D((w.lon, w.lat, w.alt))

route = [Waypoint(48.86, 2.35, 35.0), Waypoint(48.85, 2.29, 32.0)]

Rerun.log(rec, "route", Position3D.(route))
```

### Adding a `Rerun.log` method

Bare vectors of your type can also log directly, like the extension-mapped
types above. Add a `Rerun.log` method that forwards through either mechanism:

```julia
Rerun.log(rec::RecordingStream, path::AbstractString, route::AbstractVector{Waypoint}) =
    Rerun.log(rec, path, Position3D.(route))

Rerun.log(rec, "route", route)
```
