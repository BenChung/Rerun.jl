# RerunQuaternionsExt — maps Quaternions.jl `Quaternion` to Rerun's rotation
# component. Extension convention: see RerunStaticArraysExt.jl.
#
# The trap: `Quaternion(s, v1, v2, v3)` stores the scalar first (w,x,y,z) and
# Rerun's `RotationQuat` stores it last (x,y,z,w), so every conversion reorders
# and copies. To attach a rotation to a transform, build
# `Transform3D(quaternion = [RotationQuat(q)])` and log that.
module RerunQuaternionsExt

using Rerun
using Quaternions

# `import` so extending the constructor is unambiguous (extending a `using`-ed
# binding deprecates on Julia 1.12).
import Rerun.Components: RotationQuat

# Wire-layout tripwire: a schema regen that changes RotationQuat fails precompile here.
@assert isbitstype(RotationQuat)
@assert sizeof(RotationQuat) == 4 * sizeof(Float32) "RotationQuat is 4×Float32 [x,y,z,w]"

# (s, v1, v2, v3) = (w, x, y, z) -> (x, y, z, w).
RotationQuat(q::Quaternion) =
    RotationQuat((Float32(q.v1), Float32(q.v2), Float32(q.v3), Float32(q.s)))

# A quaternion is unambiguously a rotation, so a bare vector logs as
# RotationQuat. The reorder rules out zero-copy for every eltype, so batches
# always convert through the constructor (a copy).
Rerun.component(::Type{<:Quaternion}) = RotationQuat

end # module RerunQuaternionsExt
