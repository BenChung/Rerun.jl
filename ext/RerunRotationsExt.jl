# RerunRotationsExt — maps Rotations.jl rotation representations onto the Rerun
# rotation components that feed `Transform3D` (and the other pose archetypes).
#
# Follows the Rerun extension convention (see ext/RerunStaticArraysExt.jl, the
# canonical reference):
#
#   1. NO TYPE PIRACY. Every method added here attaches either to a constructor
#      of a `Rerun.Components.*` type, or to a constructor of the Rerun-owned
#      `Rerun.Archetypes.Transform3D`, and dispatches on a type OWNED by
#      Rotations.jl (`QuatRotation`, `AngleAxis`, `RotMatrix`, the abstract
#      `Rotation{3}`). We never define a method whose function AND all argument
#      types are foreign.
#
#   2. ZERO-COPY ONLY ON AN EXACT BIT-LAYOUT MATCH. None of these mappings are
#      zero-copy: Rotations.jl stores quaternions SCALAR-FIRST ([w,x,y,z]) while
#      Rerun's `RotationQuat` is SCALAR-LAST ([x,y,z,w]), so every quaternion
#      must be REORDERED (a copy). AngleAxis and RotMatrix likewise materialize
#      fresh component values. All conversions COPY.
#      A rotation is also a tiny fixed-size value (4/9 Float32), so there is no
#      bulk buffer to share even in principle.
#
#   3. QUATERNION COMPONENT ORDER IS THE LOAD-BEARING GOTCHA. Rerun
#      `RotationQuat` wraps `NTuple{4,Float32}` in [x, y, z, w] order (scalar
#      LAST). Rotations.jl / Quaternions.jl store the scalar (w) FIRST:
#      `Rotations.params(q)` is `[w, x, y, z]`. We reorder to [x, y, z, w].
#      `test/ext/test_rotations.jl` pins this with a known rotation.
module RerunRotationsExt

using Rerun
using Rotations

# Rerun-owned target types. Adding constructor methods to these is not piracy.
# `import` (not `using`) so extending their constructors is unambiguous (no Julia
# 1.12 deprecation warning).
import Rerun.Components: RotationQuat, TransformMat3x3
import Rerun.Archetypes: Transform3D

# ---------------------------------------------------------------------------
# Layout invariants (checked at precompile time, off the hot path). These
# document and enforce the wire layouts the conversions below depend on.
# ---------------------------------------------------------------------------
@assert isbitstype(RotationQuat)    "RotationQuat must be isbits"
@assert isbitstype(TransformMat3x3) "TransformMat3x3 must be isbits"
@assert sizeof(RotationQuat)    == 4 * sizeof(Float32) "RotationQuat is 4×Float32 (x,y,z,w)"
@assert sizeof(TransformMat3x3) == 9 * sizeof(Float32) "TransformMat3x3 is 9×Float32"

# ===========================================================================
# QuatRotation -> RotationQuat
#
# Method on the Rerun-owned `RotationQuat` constructor, dispatching on the
# Rotations-owned `QuatRotation`.
#
# `Rotations.params(q)` returns the quaternion parameters SCALAR-FIRST as
# `SVector(w, x, y, z)`. Rerun `RotationQuat` is SCALAR-LAST `[x, y, z, w]`, so
# we REORDER. This COPIES (4 scalars); it is NOT a reinterpret — a blind
# reinterpret would silently swap w into the x slot and corrupt the rotation.
# ===========================================================================
function RotationQuat(q::QuatRotation)
    p = Rotations.params(q)            # SVector(w, x, y, z) — scalar FIRST
    return RotationQuat((Float32(p[2]), Float32(p[3]), Float32(p[4]), Float32(p[1])))  # -> (x, y, z, w)
end

# ===========================================================================
# AngleAxis -> RotationAxisAngle (carried as a NamedTuple)
#
# Rerun's `RotationAxisAngle` is a MULTI-FIELD struct component
# (`{ axis: FixedSizeList<3,f32>, angle: f32 }`) and therefore has NO generated
# `Rerun.Components.*` Julia struct (the generator only materializes
# single-field "flat" components). So there is no component type to add a
# constructor to and no typed-batch `log` overload to route through.
#
# The reachable, piracy-free surface is the archetype FIELD: the assembled
# Arrow export path reads `getfield(x, :axis)` / `getfield(x, :angle)` from each
# element of the `rotation_axis_angle` batch, so a NamedTuple with exactly those
# fields exports correctly. `_rotation_axis_angle` builds that NamedTuple; it is
# consumed by the `Transform3D(::Rotation)` methods below (NOT exported as a
# loose `log`, which would have a foreign function + foreign arg type = piracy).
#
# `Rotations.rotation_angle` / `rotation_axis` return the angle (radians) and a
# UNIT axis. This COPIES into a fresh NamedTuple.
# ===========================================================================
function _rotation_axis_angle(aa::AngleAxis)
    ax = rotation_axis(aa)             # unit SVector{3}
    return (axis  = (Float32(ax[1]), Float32(ax[2]), Float32(ax[3])),
            angle = Float32(rotation_angle(aa)))
end

# ===========================================================================
# RotMatrix3 / RotMatrix{3} -> TransformMat3x3
#
# Method on the Rerun-owned `TransformMat3x3` constructor, dispatching on the
# Rotations-owned `RotMatrix{3}`.
#
# MATRIX ELEMENT ORDER (load-bearing — verified, not assumed):
#   Rerun `TransformMat3x3` stores 9 coefficients in COLUMN-MAJOR flat_columns
#   order (idx 0,1,2 = col 0; 3,4,5 = col 1; 6,7,8 = col 2). A `RotMatrix{3}`
#   wraps a `StaticArrays.SMatrix{3,3}` (`r.mat`), which is ALSO column-major, so
#   its data tuple is already in flat_columns order — NO transpose. `Tuple(m)`
#   yields column-major elements; element (row,col) sits at flat index col*3+row
#   in both. The test pins this with an asymmetric rotation so a stray transpose
#   would fail. This COPIES (converts 9 scalars to Float32).
# ===========================================================================
TransformMat3x3(r::RotMatrix{3}) = TransformMat3x3(map(Float32, Tuple(r.mat)))

# Any other Rotation{3} (RotationVec, RodriguesParam, MRP, RotXYZ, ...): convert
# to a quaternion first, then reuse the QuatRotation path. COPIES.
RotationQuat(r::Rotation{3}) = RotationQuat(QuatRotation(r))

# ===========================================================================
# Transform3D sugar — log any Rotations.jl rotation as a rotation-only transform.
#
# Methods on the Rerun-owned `Transform3D` constructor, dispatching on
# Rotations-owned rotation types. These pick the MOST FAITHFUL Rerun field per
# representation (no lossy round-trips):
#   * AngleAxis        -> rotation_axis_angle (preserves axis+angle exactly)
#   * RotMatrix{3}     -> mat3x3
#   * any other Rotation{3} (incl. QuatRotation) -> quaternion
#
# Each Rerun archetype field is a BATCH, so we wrap the single value in a
# length-1 vector. Extra Transform3D kwargs (translation, scale, child_frame, …)
# are forwarded so `Transform3D(R; translation=...)` composes naturally.
# ===========================================================================
Transform3D(aa::AngleAxis; kwargs...) =
    Transform3D(; rotation_axis_angle = [_rotation_axis_angle(aa)], kwargs...)

Transform3D(r::RotMatrix{3}; kwargs...) =
    Transform3D(; mat3x3 = [TransformMat3x3(r)], kwargs...)

Transform3D(r::Rotation{3}; kwargs...) =
    Transform3D(; quaternion = [RotationQuat(r)], kwargs...)

end # module RerunRotationsExt
