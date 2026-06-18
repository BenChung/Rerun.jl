# RerunCoordinateTransformationsExt — maps CoordinateTransformations.jl transforms
# onto Rerun's `Transform3D` archetype.
#
# Convention (mirrors RerunStaticArraysExt — read that first):
#
#   1. NO TYPE PIRACY. Every method added here attaches either to `Rerun.log`
#      or to a constructor of a `Rerun.Archetypes.Transform3D` (a type OWNED by
#      Rerun), and dispatches on a type OWNED by CoordinateTransformations
#      (`Translation`, `LinearMap`, `AffineMap`). We never define a method whose
#      function AND all argument types are foreign.
#
#   2. NOT ZERO-COPY. A `Transform3D` is a single small transform, not a bulk
#      buffer, and CoordinateTransformations stores its data as `Float64`
#      SVectors / matrices while Rerun's components are `Float32`. Every mapping
#      here CONVERTS (copies) into freshly-built `Float32` components. There is no
#      `reinterpret` and nothing to share — this is deliberate and documented; do
#      not "optimize" it into a reinterpret.
#
#   3. ROTATION DELEGATION (the load-bearing detail). The rotation -> Rerun field
#      conversion is DELEGATED to the RerunRotationsExt extension, via the
#      Rerun-owned constructor `Rerun.Archetypes.Transform3D(::Rotations.Rotation;
#      translation=...)`. That sibling extension owns the faithful per-rotation
#      mapping (AngleAxis -> rotation_axis_angle, RotMatrix -> mat3x3, everything
#      else -> a RotationQuat with the SCALAR-LAST (x,y,z,w) reorder that Rerun
#      requires while Rotations stores scalar-FIRST). We must NOT re-derive the
#      quaternion order here — we route through that constructor so the gotcha is
#      handled in exactly one place.
#
#      Rotations is therefore an additional weakdep of this extension. It is an
#      OPTIONAL companion: this extension triggers on CoordinateTransformations
#      ALONE, and when Rotations (hence RerunRotationsExt) is NOT loaded we fall
#      back to treating the linear part as a generic `TransformMat3x3` (mat3x3).
#
#   4. MATRIX ORDER. Rerun's `TransformMat3x3` is 9 coefficients in COLUMN-MAJOR
#      (flat_columns) order; StaticArrays/RotMatrix are also column-major, so the
#      column-major emission below needs no transpose. Element (row,col) lives at
#      flat index col*3 + row.
module RerunCoordinateTransformationsExt

using Rerun
using CoordinateTransformations
using Rerun.Components: Translation3D, TransformMat3x3

# This extension triggers on CoordinateTransformations ALONE (its [extensions]
# value is the single package "CoordinateTransformations"). Rotations is listed in
# [weakdeps] as an OPTIONAL companion so the rotation->quaternion delegation works
# when present, while the generic mat3x3 fallback still works when it is absent.
# We detect Rotations at RUN TIME (it may be loaded after this extension); we only
# look up an ALREADY-loaded module, never triggering a load.
const _ROTATIONS_PKGID = Base.PkgId(
    Base.UUID("6038ab10-8711-5258-84ad-4b1120ba62dc"), "Rotations")

@inline _rotations_module() = get(Base.loaded_modules, _ROTATIONS_PKGID, nothing)

# ---------------------------------------------------------------------------
# Layout invariants (checked at precompile time, off the hot path). A schema
# regen that changes a layout fails precompile here instead of corrupting data.
# ---------------------------------------------------------------------------
@assert isbitstype(Translation3D)   "Translation3D must be isbits"
@assert isbitstype(TransformMat3x3) "TransformMat3x3 must be isbits"
@assert fieldtype(Translation3D, :vector) == NTuple{3,Float32} "Translation3D wraps NTuple{3,Float32}"
@assert fieldtype(TransformMat3x3, :matrix) == NTuple{9,Float32} "TransformMat3x3 wraps NTuple{9,Float32} (flat_columns)"

# ===========================================================================
# Local converting builders (each COPIES into Float32).
# ===========================================================================

# Translation vector (any AbstractVector of length 3) -> Translation3D.
@inline _translation3d(t)::Translation3D =
    Translation3D((Float32(t[1]), Float32(t[2]), Float32(t[3])))

# 3x3 linear part (column-major matrix) -> TransformMat3x3 (flat_columns). Laid
# out column-major to match Rerun's flat_columns. No transpose.
@inline function _mat3x3(m)::TransformMat3x3
    return TransformMat3x3((
        Float32(m[1, 1]), Float32(m[2, 1]), Float32(m[3, 1]),   # column 0
        Float32(m[1, 2]), Float32(m[2, 2]), Float32(m[3, 2]),   # column 1
        Float32(m[1, 3]), Float32(m[2, 3]), Float32(m[3, 3]),   # column 2
    ))
end

# Can we DELEGATE this `linear` part to RerunRotationsExt's faithful
# `Transform3D(::Rotation; kwargs...)` constructor? True iff Rotations is loaded,
# `linear` is a `Rotations.Rotation`, and that extension's method is installed.
@inline function _delegates_rotation(linear)::Bool
    Rotations = _rotations_module()
    Rotations === nothing && return false
    linear isa Rotations.Rotation || return false
    # The RerunRotationsExt method dispatches on `Rotations.Rotation{3}`; require
    # an applicable Transform3D(linear; ...) method (i.e. it is loaded).
    return hasmethod(Rerun.Archetypes.Transform3D, Tuple{typeof(linear)})
end

# ===========================================================================
# Transform3D archetype builders.  `Rerun.Archetypes.Transform3D` is OWNED by
# Rerun; adding constructor methods dispatching on CoordinateTransformations
# types is not piracy. Each archetype field carries a 1-element component vector
# (a single transform == one instance; the C exporter consumes a pointer+length,
# so a scalar must be wrapped in a length-1 vector).
#
# Rotation handling is DELEGATED to RerunRotationsExt's
# `Transform3D(::Rotation; kwargs...)` (which picks the faithful field and owns
# the scalar-last quaternion reorder). When Rotations / RerunRotationsExt is not
# loaded, or the linear part is a plain matrix, we fall back to a generic mat3x3.
# `Transform3D(::Rotation; kwargs...)` forwards extra kwargs, so we pass
# `translation=...` straight through for the AffineMap case.
# ===========================================================================

# Translation only.
Rerun.Archetypes.Transform3D(t::Translation) =
    Rerun.Archetypes.Transform3D(; translation = [_translation3d(t.translation)])

# LinearMap: rotation-only.
function Rerun.Archetypes.Transform3D(m::LinearMap)
    if _delegates_rotation(m.linear)
        return Rerun.Archetypes.Transform3D(m.linear)            # delegate to RerunRotationsExt
    else
        return Rerun.Archetypes.Transform3D(; mat3x3 = [_mat3x3(m.linear)])
    end
end

# AffineMap: translation + rotation field.
function Rerun.Archetypes.Transform3D(a::AffineMap)
    trans = [_translation3d(a.translation)]
    if _delegates_rotation(a.linear)
        return Rerun.Archetypes.Transform3D(a.linear; translation = trans)  # kwargs forwarded
    else
        return Rerun.Archetypes.Transform3D(; translation = trans,
                                            mat3x3 = [_mat3x3(a.linear)])
    end
end

# ===========================================================================
# `Rerun.log` sugar: log a CoordinateTransformations transform directly as a
# Transform3D archetype. Method on Rerun.log dispatching on a
# CoordinateTransformations-owned type. Forwards `inject_time` as required.
# ===========================================================================

const _SupportedTransform = Union{Translation, LinearMap, AffineMap}

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   transform::_SupportedTransform; inject_time::Bool=true)
    Rerun.log(r, entity_path, Rerun.Archetypes.Transform3D(transform);
              inject_time=inject_time)
end

end # module RerunCoordinateTransformationsExt
