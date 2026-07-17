# RerunCoordinateTransformationsExt — maps CoordinateTransformations.jl
# transforms onto Rerun's `Transform3D` archetype. Extension convention: see
# RerunStaticArraysExt.jl. Everything here converts Float64 -> Float32 (copies).
#
# Rotation handling delegates to RerunRotationsExt's `Transform3D(::Rotation)`
# constructor, which owns the quaternion-order trap — never re-derive it here.
# Rotations is an optional companion: this extension activates on
# CoordinateTransformations alone, and when RerunRotationsExt is absent the
# linear part falls back to a generic mat3x3.
module RerunCoordinateTransformationsExt

using Rerun
using CoordinateTransformations
using Rerun.Components: Translation3D, TransformMat3x3

# Look up Rotations among already-loaded modules at run time (it may load after
# this extension); never trigger a load.
const _ROTATIONS_PKGID = Base.PkgId(
    Base.UUID("6038ab10-8711-5258-84ad-4b1120ba62dc"), "Rotations")

@inline _rotations_module() = get(Base.loaded_modules, _ROTATIONS_PKGID, nothing)

# Wire-layout tripwires: a schema regen that changes a layout fails precompile here.
@assert isbitstype(Translation3D)   "Translation3D must be isbits"
@assert isbitstype(TransformMat3x3) "TransformMat3x3 must be isbits"
@assert fieldtype(Translation3D, :vector) == NTuple{3,Float32} "Translation3D wraps NTuple{3,Float32}"
@assert fieldtype(TransformMat3x3, :matrix) == NTuple{9,Float32} "TransformMat3x3 wraps NTuple{9,Float32} (flat_columns)"

# Converting builders (Float32 copies).
@inline _translation3d(t)::Translation3D =
    Translation3D((Float32(t[1]), Float32(t[2]), Float32(t[3])))

# Column-major emission matches Rerun's flat_columns — no transpose.
@inline function _mat3x3(m)::TransformMat3x3
    return TransformMat3x3((
        Float32(m[1, 1]), Float32(m[2, 1]), Float32(m[3, 1]),   # column 0
        Float32(m[1, 2]), Float32(m[2, 2]), Float32(m[3, 2]),   # column 1
        Float32(m[1, 3]), Float32(m[2, 3]), Float32(m[3, 3]),   # column 2
    ))
end

# True iff Rotations is loaded, `linear` is a Rotation, and RerunRotationsExt's
# Transform3D method is installed.
@inline function _delegates_rotation(linear)::Bool
    Rotations = _rotations_module()
    Rotations === nothing && return false
    linear isa Rotations.Rotation || return false
    return hasmethod(Rerun.Archetypes.Transform3D, Tuple{typeof(linear)})
end

# Transform3D builders. Archetype fields are batches, so a single transform
# wraps in a length-1 vector.

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

# Log a transform directly as a Transform3D archetype.

const _SupportedTransform = Union{Translation, LinearMap, AffineMap}

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   transform::_SupportedTransform; static::Bool=false,
                   inject_time::Bool=!static)
    Rerun.log(r, entity_path, Rerun.Archetypes.Transform3D(transform);
              inject_time=inject_time)
end

end # module RerunCoordinateTransformationsExt
