# Interop

Rerun.jl maps foreign types onto components through declarations.
[Your own types](@ref) documents the declarations; [Extensions](@ref) lists
the mappings the bundled package extensions declare for ecosystem types
(StaticArrays vectors, colorants, images, geometry, rotations, transforms).

## Your own types

Custom types plug in through three declarations, each a single method:

- **Any layout**: a constructor method `C(::T)` on the component. Batches
  convert element by element. The conversion copies.
- **Bare vectors, with no component at the call site**: a
  [`Rerun.component`](@ref) declaration. It names the component `Vector{T}`
  logs as and composes with either value mapping.
- **Element layout matches the component's wire layout exactly**: a
  [`Rerun.wire_compatible`](@ref) declaration. Batches log zero-copy.

A vector with no applicable declaration fails with an
[`Rerun.InteropError`](@ref) naming the declaration that fixes it.

### Mapping with a constructor

A constructor method covers any layout. For example, `Waypoint` stores `Float64` fields
with latitude before longitude, so neither its width nor its field order
matches `Position3D`:

```julia
struct Waypoint; lat::Float64; lon::Float64; alt::Float64; end

Rerun.component(::Type{Waypoint}) = Position3D
Rerun.Components.Position3D(w::Waypoint) = Position3D((w.lon, w.lat, w.alt))
```

The `component` declaration names the target. The constructor does the field
reordering and conversion. The bundled extensions attach through these same
hooks. `Waypoint` vectors then log everywhere a component batch fits:

```julia
route = [Waypoint(48.86, 2.35, 35.0), Waypoint(48.85, 2.29, 32.0)]

Rerun.log(rec, "route", route)                                # bare vector
Rerun.log(rec, "route", Points3D(route; radii = [0.5, 1.0]))  # archetype fields
```

### Claiming zero-copy

When your element type is isbits with exactly the component's wire layout,
declare it wire-compatible and batches log zero-copy. Flat components store a
numeric scalar or a fixed-size vector of numbers on the wire: `Position3D` is
three `Float32`s, `Radius` is one `Float32`, and `Color` is one packed
`UInt32`. For example, a struct of three `Float32` fields lays out like
`Position3D`:

```julia
struct XYZ; x::Float32; y::Float32; z::Float32; end

Rerun.component(::Type{XYZ}) = Position3D
Rerun.wire_compatible(::Type{XYZ}, ::Type{Position3D}) = true

Rerun.log(rec, "cloud", [XYZ(0, 0, 0), XYZ(1, 1, 1)])
```

The two declarations compose: `component` routes the bare vector to
`Position3D`, and `wire_compatible` passes the batch through as-is. Every log
checks the declaration against the two types: a wrong width or a non-isbits
element type throws an [`Rerun.InteropError`](@ref). The checks compile away
for concrete element types.

### Errors name the missing declaration

Logging a vector with no declaration produces the recipe to add one:

```
InteropError: no component mapping for Waypoint.
To log Vector{Waypoint}, declare its component and how to build it:
  Rerun.component(::Type{Waypoint}) = <Component>
  Rerun.Components.<Component>(x::Waypoint) = ...
Or name the component at the call site: Rerun.log(rec, path, Component, data).
```

### Mapping to an archetype

When a type carries more than one component's worth of data, map it to an
archetype. Attach a `Rerun.log` method and build the archetype inside it. The
component declarations above keep working in archetype fields, so a
`Vector{Waypoint}` fills the positions field directly:

```julia
struct Track
    waypoints::Vector{Waypoint}
    color::UInt32
end

function Rerun.log(rec::RecordingStream, path::AbstractString, t::Track;
                   static::Bool = false, inject_time::Bool = !static)
    colors = fill(Color(t.color), length(t.waypoints))
    Rerun.log(rec, path, Points3D(t.waypoints; colors = colors); inject_time = inject_time)
end

Rerun.log(rec, "track", Track(route, 0x44aaffff))
```

The bundled extensions map composite types this way: ImageCore logs a
`Matrix{<:Colorant}` as an `Image`, and GeometryBasics logs a `Mesh` as
`Mesh3D`.

## Extensions

The package extensions ship these declarations for ecosystem types: loading
the companion package activates its extension, and its types log directly.
Zero-copy holds where the extension declares an element type wire-compatible
(the exact wire eltypes, e.g. `SVector{3,Float32}`); every other mapping
converts to the wire types (`Float32`, packed `UInt32`, …) and copies.

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

# One archetype row from the same vectors: positions pass zero-copy,
# colorants convert.
Rerun.log(rec, "helix", Points3D(helix; colors = shade))
flush(rec)
```

`Rerun.Components` and `ColorTypes` both export a `Color`; qualify it as
`Components.Color` when both are in scope.

### StaticArrays

| you have | maps to | notes |
|---|---|---|
| `Vector{<:StaticVector{3}}` | `Position3D` batch | zero-copy for `Float32` elements; other eltypes convert |
| `Vector{<:StaticVector{2}}` | `Position2D` batch | same |
| `StaticVector{2}` / `{3}` | `Position2D` / `Position3D` | constructor |
| `SMatrix{3,3}` | `TransformMat3x3` | constructor; both column-major, no transpose |

### ColorTypes

| you have | maps to | notes |
|---|---|---|
| RGB-family colorant | `Color` | constructor; packs `0xRRGGBBAA`, alpha-less get `0xff` |
| gray colorant | `Color` | constructor; r = g = b = value |
| `Vector{<:Colorant}` | `Color` batch | copies |

Convert other color spaces (HSV, Lab, …) with Colors.jl first.

### ImageCore

| you have | maps to | notes |
|---|---|---|
| `Matrix{<:Colorant}` (RGB family) | `Image` | RGB or RGBA from the channel count |
| gray or `Matrix{<:AbstractFloat}` | `DepthImage` | |
| `Matrix{<:Integer}` | `SegmentationImage` | |

Images re-layout into Rerun's row-major interleaved bytes (a copy).

### GeometryBasics

| you have | maps to | notes |
|---|---|---|
| `Rect{2}` / `Rect{3}` (or vectors) | `Boxes2D` / `Boxes3D` | origin + widths → center + half-size |
| `LineString`, `Polygon` | `LineStrips2D` / `LineStrips3D` | polygons log the exterior ring, loop closed |
| `Mesh`, `Triangle` | `Mesh3D` | vertices zero-copy; faces reindexed to 0-based |
| `HyperSphere{3}` (or vectors) | `Ellipsoids3D` | half-size `(r, r, r)` |

Points are `StaticVector`s, so the StaticArrays mapping covers them.

### Meshes

| you have | maps to | notes |
|---|---|---|
| `Meshes.Point` (or vectors) | `Position2D` / `Position3D` | 2D or 3D from the embedding dimension |
| `Segment`, `Rope`, `Ring` | `LineStrips2D` / `LineStrips3D` | `Ring` closes the loop |
| `Triangle`, `Ngon`, `SimpleMesh` | `Mesh3D` | fan-triangulated; indices reindexed to 0-based |
| `Box` (3D) | `Boxes3D` | min/max corners → center + half-size |
| `Ball`, `Sphere` | `Ellipsoids3D` | half-size `(r, r, r)` |

Coordinates convert to `Float32`, stripping Unitful units.

### Rotations

| you have | maps to | notes |
|---|---|---|
| `QuatRotation` (or any `Rotation{3}`) | `RotationQuat` | constructor; reordered to Rerun's `(x, y, z, w)` |
| `RotMatrix{3}` | `TransformMat3x3` | constructor |
| `AngleAxis`, `RotMatrix{3}`, `Rotation{3}` | `Transform3D(R; kwargs...)` | each through its faithful field: axis-angle, mat3x3, quaternion |

### Quaternions

| you have | maps to | notes |
|---|---|---|
| `Quaternion` | `RotationQuat` | constructor; scalar-first `(w, x, y, z)` reordered to `(x, y, z, w)` |
| `Vector{<:Quaternion}` | `RotationQuat` batch | logs directly |

### CoordinateTransformations

| you have | maps to | notes |
|---|---|---|
| `Translation` | `Transform3D` | translation field |
| `LinearMap` | `Transform3D` | rotation via the Rotations extension when loaded, generic `mat3x3` otherwise |
| `AffineMap` | `Transform3D` | translation + linear part |

All three log directly and build `Transform3D` constructors.
