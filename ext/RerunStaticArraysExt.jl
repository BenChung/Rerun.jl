# RerunStaticArraysExt — StaticArrays vectors/matrices as Rerun components, and
# the reference for the convention every Rerun.jl extension follows:
#
#   * No type piracy: methods attach to Rerun-owned functions (`Rerun.log`,
#     `Rerun.Components.*` constructors) and dispatch on the weakdep's types.
#   * Zero-copy only on an exact bit-layout match (here: a contiguous
#     `Vector{StaticVector{N,Float32}}` reinterprets to the wire component);
#     any other eltype converts to Float32 and copies.
#   * A bare vector logs as positions, the common meaning; other components use
#     the explicit `Rerun.log(rec, path, Component, data)` form.
module RerunStaticArraysExt

using Rerun
using StaticArrays

# `import` so extending these constructors is unambiguous (extending a
# `using`-ed binding deprecates on Julia 1.12).
import Rerun.Components: Position2D, Position3D, TransformMat3x3

# Wire-layout tripwires for the reinterprets below: a schema regen that changes
# a layout fails precompile here instead of corrupting data.
@assert isbitstype(Position2D)      "Position2D must be isbits for zero-copy reinterpret"
@assert isbitstype(Position3D)      "Position3D must be isbits for zero-copy reinterpret"
@assert isbitstype(TransformMat3x3) "TransformMat3x3 must be isbits for zero-copy reinterpret"
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

# Batch conversion: zero-copy reinterpret for a contiguous Float32 vector whose
# layout equals the component's, converting copy otherwise.
@inline function _reinterpret_batch(::Type{C}, v::Vector{SV}) where {C,N,SV<:StaticVector{N,Float32}}
    # `SV` is N contiguous Float32 — sizes must match for the reinterpret.
    @assert isbitstype(SV)
    @assert sizeof(SV) == sizeof(C) "zero-copy requires sizeof($SV)==sizeof($C)"
    return reinterpret(C, v)
end

@inline _as_position_batch(::Type{C}, v::Vector{<:StaticVector{N,Float32}}) where {C,N} =
    _reinterpret_batch(C, v)

# Any other eltype or container: convert (copies).
@inline _as_position_batch(::Type{C}, v::AbstractVector{<:StaticVector{N}}) where {C,N} =
    C[C(x) for x in v]

# Bare-vector log sugar: positions. These generic StaticVector methods also
# cover GeometryBasics.Point (<: StaticVector), so that ext maps only its
# composite types.
function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   data::AbstractVector{<:StaticVector{3}}; inject_time::Bool=true)
    Rerun.log(r, entity_path, Position3D, _as_position_batch(Position3D, data);
              inject_time=inject_time)
end

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   data::AbstractVector{<:StaticVector{2}}; inject_time::Bool=true)
    Rerun.log(r, entity_path, Position2D, _as_position_batch(Position2D, data);
              inject_time=inject_time)
end

end # module RerunStaticArraysExt
