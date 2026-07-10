# RerunStaticArraysExt — the canonical REFERENCE Rerun package extension.
#
# This is the template every other Rerun.jl extension follows. It demonstrates
# the full convention:
#
#   1. NO TYPE PIRACY. Every method added here attaches either to `Rerun.log`
#      or to a constructor of a `Rerun.Components.*` type (functions OWNED by
#      Rerun), and dispatches on a type OWNED by StaticArrays (`StaticVector`,
#      `SMatrix`). We never define a method whose function AND all argument
#      types are foreign.
#
#   2. ZERO-COPY ONLY ON AN EXACT BIT-LAYOUT MATCH. Rerun's flat geometry
#      components are isbits, wire-shaped structs (`Position3D` wraps
#      `NTuple{3,Float32}`, etc.). A `StaticVector{3,Float32}` is itself a
#      contiguous block of 3 `Float32`, so `reinterpret` to `Position3D` is a
#      legal, copy-free view — but ONLY when eltype is exactly `Float32` and the
#      `sizeof` matches. We guard every reinterpret with `@assert`s and route
#      the result through the existing typed-batch `Rerun.log` path (which is
#      itself zero-copy). For `Float64` or any other eltype we CONVERT to
#      `Float32` (this COPIES).
#
#   3. BARE-VECTOR SUGAR RESOLVES TO POSITIONS. A bare `StaticVector` of 2/3
#      `Float32` is the ambiguous case (could be a position, a vector/normal, a
#      translation, ...). We resolve it to the most common meaning: POSITIONS
#      (`Position2D`/`Position3D`). For vectors/normals/translations and any
#      other reuse, users call the explicit, already-zero-copy interop form
#      `Rerun.log(rec, path, Rerun.Components.Vector3D, data)`.
module RerunStaticArraysExt

using Rerun
using StaticArrays

# Pull in the concrete component types we target. These are OWNED by Rerun, so
# adding constructor methods to them is not piracy. `import` (not `using`) so
# extending their constructors is unambiguous (no Julia 1.12 deprecation warning).
import Rerun.Components: Position2D, Position3D, TransformMat3x3

# ---------------------------------------------------------------------------
# Layout invariants (checked at precompile time, off the hot path).
#
# These document and enforce the exact wire layouts the zero-copy reinterprets
# below depend on. If a future Rerun schema regen changes a layout, precompiling
# this extension fails loudly here instead of silently corrupting data.
# ---------------------------------------------------------------------------
@assert isbitstype(Position2D)      "Position2D must be isbits for zero-copy reinterpret"
@assert isbitstype(Position3D)      "Position3D must be isbits for zero-copy reinterpret"
@assert isbitstype(TransformMat3x3) "TransformMat3x3 must be isbits for zero-copy reinterpret"
@assert sizeof(Position2D)      == 2 * sizeof(Float32) "Position2D is 2×Float32"
@assert sizeof(Position3D)      == 3 * sizeof(Float32) "Position3D is 3×Float32"
@assert sizeof(TransformMat3x3) == 9 * sizeof(Float32) "TransformMat3x3 is 9×Float32"

# ===========================================================================
# Scalar constructors:  Rerun.Components.<C>(::StaticVector)
#
# Method on a Rerun-owned constructor, dispatching on a StaticArrays-owned type.
# These build a single materialized component. They always go through the
# component's own constructor (i.e. an NTuple), so they are correct for any
# input eltype — `convert` to Float32 happens inside the NTuple build.
# ===========================================================================

Position2D(v::StaticVector{2}) = Position2D((Float32(v[1]), Float32(v[2])))
Position3D(v::StaticVector{3}) = Position3D((Float32(v[1]), Float32(v[2]), Float32(v[3])))

# SMatrix{3,3} -> TransformMat3x3.
#
# MATRIX ELEMENT ORDER (this is the load-bearing detail, do not "fix" it):
#   Rerun stores TransformMat3x3 as a flat list of 9 coefficients in
#   COLUMN-MAJOR order (flat_columns): index 0,1,2 = column 0, 3,4,5 = column 1,
#   6,7,8 = column 2 (see gen/idl/.../components/transform_mat3x3.fbs).
#   Julia/StaticArrays `SMatrix` is ALSO stored column-major. So the SMatrix's
#   internal data tuple is already in Rerun's flat_columns order — no transpose,
#   no permutation. `Tuple(m)` yields elements in column-major order, which we
#   feed straight into the component. Element (row, col) of the math matrix sits
#   at flat index col*3 + row in both representations.
TransformMat3x3(m::SMatrix{3,3}) = TransformMat3x3(map(Float32, Tuple(m)))

# ===========================================================================
# Batch zero-copy / convert helpers.
#
# `_as_component_batch(C, v)` returns an `AbstractVector{C}` ready for the typed
# `Rerun.log(rec, path, ::Type{C}, batch)` path. It is zero-copy iff the source
# is a contiguous vector of `StaticVector{N,Float32}` whose `sizeof` matches `C`;
# otherwise it copies via the scalar constructor.
# ===========================================================================

# Zero-copy: contiguous Vector{SV} of the EXACT eltype Float32 and matching size.
@inline function _reinterpret_batch(::Type{C}, v::Vector{SV}) where {C,N,SV<:StaticVector{N,Float32}}
    # Guard the layout the reinterpret relies on. `SV` is N contiguous Float32,
    # `C` is the same N Float32 wire struct — sizes must be identical.
    @assert isbitstype(SV)
    @assert sizeof(SV) == sizeof(C) "zero-copy requires sizeof($SV)==sizeof($C)"
    return reinterpret(C, v)
end

# Float32 StaticVector vector, contiguous -> zero-copy view.
@inline _as_position_batch(::Type{C}, v::Vector{<:StaticVector{N,Float32}}) where {C,N} =
    _reinterpret_batch(C, v)

# Anything else (Float64, mixed eltype, non-contiguous AbstractVector): CONVERT.
# This COPIES into a fresh Vector{C}; not zero-copy.
@inline _as_position_batch(::Type{C}, v::AbstractVector{<:StaticVector{N}}) where {C,N} =
    C[C(x) for x in v]

# ===========================================================================
# Batch `Rerun.log` sugar — the bare-vector default is POSITIONS.
#
# Methods on Rerun.log dispatching on a StaticArrays-owned eltype.
#
# `Vector{<:StaticVector{3,Float32}}`  -> Position3D (zero-copy)
# `Vector{<:StaticVector{2,Float32}}`  -> Position2D (zero-copy)
# Float64 / non-contiguous variants    -> convert to Float32 (copies)
#
# This GENERIC `StaticVector` method is also what makes GeometryBasics'
# `Point{N,Float32}` log as positions zero-copy, because GeometryBasics.Point
# <: StaticArrays.StaticVector. The responsibility split: StaticArrays owns the
# StaticVector->Position/Vec mapping; GeometryBasics owns only its
# non-StaticVector types (Rect/Mesh/LineString/Polygon).
# ===========================================================================

# 3-vectors -> Position3D
function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   data::AbstractVector{<:StaticVector{3}}; inject_time::Bool=true)
    Rerun.log(r, entity_path, Position3D, _as_position_batch(Position3D, data);
              inject_time=inject_time)
end

# 2-vectors -> Position2D
function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   data::AbstractVector{<:StaticVector{2}}; inject_time::Bool=true)
    Rerun.log(r, entity_path, Position2D, _as_position_batch(Position2D, data);
              inject_time=inject_time)
end

end # module RerunStaticArraysExt
