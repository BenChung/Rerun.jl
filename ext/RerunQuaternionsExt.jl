# RerunQuaternionsExt — map Quaternions.jl `Quaternion` to Rerun's rotation
# component.
#
# Follows the RerunStaticArraysExt convention (read that file first):
#
#   1. NO TYPE PIRACY. Every method here attaches either to `Rerun.log` or to a
#      constructor of a `Rerun.Components.*` type (functions OWNED by Rerun) and
#      dispatches on `Quaternions.Quaternion` (OWNED by Quaternions). We never
#      define a method whose function AND all argument types are foreign.
#
#   2. THIS MAPPING ALWAYS COPIES (never zero-copy). Two independent reasons make
#      a reinterpret illegal here:
#        (a) COMPONENT ORDER. `Quaternions.Quaternion(s, v1, v2, v3)` is
#            SCALAR-FIRST: `s` is the real/scalar part `w`, and `(v1, v2, v3)`
#            are the imaginary parts `(x, y, z)`. Its in-memory field order is
#            therefore `(w, x, y, z)`. Rerun's `RotationQuat` stores
#            `NTuple{4,Float32}` in `[x, y, z, w]` order (xyzw — scalar LAST; see
#            gen/idl/.../components/rotation_quat.fbs). So we must REORDER
#            `(s, v1, v2, v3) -> (v1, v2, v3, s)`.
#        (b) ELTYPE. `Quaternion{T}` is typically `T == Float64`; Rerun rotations
#            are `Float32`. Even a `Quaternion{Float32}` could not be reinterpreted
#            because of (a).
#      Because of (a), reinterpret would be wrong for EVERY eltype, so there is
#      no zero-copy fast path at all — we always materialize a fresh
#      `Vector{RotationQuat}`.
#
#   3. BARE-VECTOR SUGAR. A bare `Vector{<:Quaternion}` is unambiguous (a
#      quaternion is a rotation), so `Rerun.log(rec, path, qs)` maps to a
#      `RotationQuat` batch. To attach a rotation to a Transform3D, build the
#      archetype yourself: `Transform3D(quaternion = RotationQuat(q))` (or a
#      vector of them) and `Rerun.log` that.
module RerunQuaternionsExt

using Rerun
using Quaternions

# `RotationQuat` is OWNED by Rerun, so adding constructor methods to it is not
# piracy. `import` (not `using`) so extending its constructor is unambiguous
# (no Julia 1.12 deprecation warning).
import Rerun.Components: RotationQuat

# ---------------------------------------------------------------------------
# Layout invariant (checked at precompile time, not the hot path). Documents the
# wire layout the reorder below targets. If a future schema regen changes it,
# precompiling this extension fails loudly here.
# ---------------------------------------------------------------------------
@assert isbitstype(RotationQuat)
@assert sizeof(RotationQuat) == 4 * sizeof(Float32) "RotationQuat is 4×Float32 [x,y,z,w]"

# ===========================================================================
# Scalar constructor:  Rerun.Components.RotationQuat(::Quaternions.Quaternion)
#
# Method on a Rerun-owned constructor, dispatching on a Quaternions-owned type.
#
# REORDER (load-bearing, do not "fix"): Quaternions is scalar-FIRST
# (s, v1, v2, v3) = (w, x, y, z); Rerun RotationQuat is xyzw = [x, y, z, w].
# We pull `s` to the back and convert each coefficient to Float32 (COPIES).
# ===========================================================================
RotationQuat(q::Quaternion) =
    RotationQuat((Float32(q.v1), Float32(q.v2), Float32(q.v3), Float32(q.s)))

# ===========================================================================
# Batch convert helper. ALWAYS copies (see the module note (2a): reorder makes a
# reinterpret illegal for every eltype). Returns a fresh `Vector{RotationQuat}`
# ready for the typed `Rerun.log(rec, path, ::Type{RotationQuat}, batch)` path.
# ===========================================================================
@inline _as_rotation_batch(qs::AbstractVector{<:Quaternion}) =
    RotationQuat[RotationQuat(q) for q in qs]

# ===========================================================================
# Batch `Rerun.log` sugar — a quaternion is a rotation, so a bare vector maps to
# `RotationQuat`. Method on Rerun.log dispatching on a Quaternions-owned eltype.
# Keeps and forwards the `inject_time` kwarg per convention.
# ===========================================================================
function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   data::AbstractVector{<:Quaternion}; inject_time::Bool=true)
    Rerun.log(r, entity_path, RotationQuat, _as_rotation_batch(data);
              inject_time=inject_time)
end

end # module RerunQuaternionsExt
