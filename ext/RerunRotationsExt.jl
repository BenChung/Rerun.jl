# RerunRotationsExt — maps Rotations.jl rotations onto the Rerun rotation
# components that feed `Transform3D`. Extension convention: see
# RerunStaticArraysExt.jl.
#
# The trap: Rotations.jl stores quaternions as (w,x,y,z) and Rerun's
# `RotationQuat` as (x,y,z,w), so every conversion reorders and copies
# (test/ext/test_rotations.jl pins the order with a known rotation).
module RerunRotationsExt

using Rerun
using Rotations

# `import` so extending these constructors is unambiguous (extending a
# `using`-ed binding deprecates on Julia 1.12).
import Rerun.Components: RotationQuat, TransformMat3x3
import Rerun.Archetypes: Transform3D

# Wire-layout tripwires: a schema regen that changes a layout fails precompile here.
@assert isbitstype(RotationQuat)    "RotationQuat must be isbits"
@assert isbitstype(TransformMat3x3) "TransformMat3x3 must be isbits"
@assert sizeof(RotationQuat)    == 4 * sizeof(Float32) "RotationQuat is 4×Float32 (x,y,z,w)"
@assert sizeof(TransformMat3x3) == 9 * sizeof(Float32) "TransformMat3x3 is 9×Float32"

# `Rotations.params(q)` is (w,x,y,z); RotationQuat wants (x,y,z,w).
function RotationQuat(q::QuatRotation)
    p = Rotations.params(q)
    return RotationQuat((Float32(p[2]), Float32(p[3]), Float32(p[4]), Float32(p[1])))
end

# `RotationAxisAngle` is a multi-field struct component with no generated Julia
# struct, so the reachable surface is the archetype field: the assembled export
# reads `axis`/`angle` off each batch element, and a NamedTuple with exactly
# those fields exports correctly. Consumed by the Transform3D methods below.
function _rotation_axis_angle(aa::AngleAxis)
    ax = rotation_axis(aa)             # unit SVector{3}
    return (axis  = (Float32(ax[1]), Float32(ax[2]), Float32(ax[3])),
            angle = Float32(rotation_angle(aa)))
end

# Rerun flat_columns and `SMatrix` are both column-major, so `Tuple(r.mat)` is
# already in wire order (the test pins this with an asymmetric rotation).
TransformMat3x3(r::RotMatrix{3}) = TransformMat3x3(map(Float32, Tuple(r.mat)))

# Any other Rotation{3} (RotationVec, MRP, RotXYZ, ...) converts via quaternion.
RotationQuat(r::Rotation{3}) = RotationQuat(QuatRotation(r))

# Each rotation type maps to its most faithful Rerun field, with quaternion as
# the general fallback. Archetype fields are batches, so single values wrap in
# length-1 vectors; extra kwargs (translation, ...) forward through.
Transform3D(aa::AngleAxis; kwargs...) =
    Transform3D(; rotation_axis_angle = [_rotation_axis_angle(aa)], kwargs...)

Transform3D(r::RotMatrix{3}; kwargs...) =
    Transform3D(; mat3x3 = [TransformMat3x3(r)], kwargs...)

Transform3D(r::Rotation{3}; kwargs...) =
    Transform3D(; quaternion = [RotationQuat(r)], kwargs...)

end # module RerunRotationsExt
