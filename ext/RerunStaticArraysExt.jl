# RerunStaticArraysExt — StaticArrays vectors/matrices as Rerun components, and
# the reference for the convention every Rerun.jl extension follows:
#
#   * No type piracy: methods attach to Rerun-owned functions (`Rerun.component`,
#     `Rerun.wire_compatible`, `Rerun.Components.*` constructors) and dispatch
#     on the weakdep's types.
#   * `Rerun.component` declares which component a batch logs as; constructors
#     carry the value conversion; `Rerun.wire_compatible` claims zero-copy for
#     the exact wire-layout eltypes only.
module RerunStaticArraysExt

using Rerun
using StaticArrays

# `import` so extending these constructors is unambiguous (extending a
# `using`-ed binding deprecates on Julia 1.12).
import Rerun.Components: Position2D, Position3D, TransformMat3x3

# Wire-layout tripwires for the wire_compatible declarations below: a schema
# regen that changes a layout fails precompile here instead of corrupting data.
@assert isbitstype(Position2D)      "Position2D must be isbits for zero-copy"
@assert isbitstype(Position3D)      "Position3D must be isbits for zero-copy"
@assert isbitstype(TransformMat3x3) "TransformMat3x3 must be isbits for zero-copy"
@assert sizeof(Position2D)      == 2 * sizeof(Float32) "Position2D is 2×Float32"
@assert sizeof(Position3D)      == 3 * sizeof(Float32) "Position3D is 3×Float32"
@assert sizeof(TransformMat3x3) == 9 * sizeof(Float32) "TransformMat3x3 is 9×Float32"

# Scalar constructors build through the component's NTuple constructor, so any
# input eltype converts correctly.
Position2D(v::StaticVector{2}) = Position2D((Float32(v[1]), Float32(v[2])))
Position3D(v::StaticVector{3}) = Position3D((Float32(v[1]), Float32(v[2]), Float32(v[3])))

# Rerun flat_columns and `SMatrix` are both column-major, so `Tuple(m)` is
# already in wire order — no transpose.
TransformMat3x3(m::SMatrix{3,3}) = TransformMat3x3(map(Float32, Tuple(m)))

# A bare vector logs as positions, the common meaning. These generic
# StaticVector declarations also cover GeometryBasics.Point (<: StaticVector),
# so that ext maps only its composite types.
Rerun.component(::Type{<:StaticVector{2}}) = Position2D
Rerun.component(::Type{<:StaticVector{3}}) = Position3D

# Zero-copy only for the exact wire eltypes; every other StaticVector converts
# through the constructors above (a copy). MVector and friends stay on the
# constructor path: they are not isbits.
Rerun.wire_compatible(::Type{SVector{2,Float32}}, ::Type{Position2D}) = true
Rerun.wire_compatible(::Type{SVector{3,Float32}}, ::Type{Position3D}) = true
Rerun.wire_compatible(::Type{SMatrix{3,3,Float32,9}}, ::Type{TransformMat3x3}) = true

end # module RerunStaticArraysExt
