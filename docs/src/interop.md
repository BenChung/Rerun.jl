# Interop (package extensions)

Rerun.jl maps ecosystem types onto components through package extensions:
loading the companion package activates its extension, and its types log
directly. Every mapping routes through the interop core, which works for your
own types too:

```julia
Rerun.log(rec, path, Component, data)   # any layout-compatible vector logs as Component
```

Zero-copy holds whenever the element layout matches the component's wire
layout; every other mapping converts to the wire types (`Float32`, packed
`UInt32`, …) and copies.

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
