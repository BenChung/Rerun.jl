# RerunGeometryBasicsExt — maps GeometryBasics composite geometry (Rect,
# LineString, Polygon, Mesh, Sphere, ...) to Rerun archetypes. Extension
# convention: see RerunStaticArraysExt.jl.
#
# Points stay out of this file: `GeometryBasics.Point` is a `StaticVector`, so
# RerunStaticArraysExt already owns the point mapping. This ext adds the
# zero-copy declarations for `Point{N,Float32}` and builds archetypes whose
# point fields are `Vector{<:Point}`; its own structural transforms
# (center/half-size splits, ring closing, face reindexing) copy.
module RerunGeometryBasicsExt

using Rerun
using GeometryBasics
# Loading StaticArrays activates its ext, so point batches reinterpret zero-copy.
using StaticArrays

# `import` so extending the constructors below is unambiguous (extending a
# `using`-ed binding deprecates on Julia 1.12).
import Rerun.Components: Position2D, Position3D, HalfSize2D, HalfSize3D,
    Translation3D, TriangleIndices, Vector3D, LineStrip2D, LineStrip3D, Radius
using Rerun.Archetypes: Boxes2D, Boxes3D, LineStrips2D, LineStrips3D, Mesh3D,
    Ellipsoids3D

# Wire-layout tripwires: a schema regen that changes a layout fails precompile here.
@assert isbitstype(Position3D)
@assert isbitstype(TriangleIndices)
@assert sizeof(HalfSize3D)      == 3 * sizeof(Float32)
@assert sizeof(HalfSize2D)      == 2 * sizeof(Float32)
@assert sizeof(Translation3D)   == 3 * sizeof(Float32)
@assert sizeof(TriangleIndices) == 3 * sizeof(UInt32)

# One-value converters (Float32 copies) through the components' NTuple constructors.
@inline _f32x2(p) = (Float32(p[1]), Float32(p[2]))
@inline _f32x3(p) = (Float32(p[1]), Float32(p[2]), Float32(p[3]))

HalfSize2D(v::GeometryBasics.Vec{2})    = HalfSize2D(_f32x2(v))
HalfSize3D(v::GeometryBasics.Vec{3})    = HalfSize3D(_f32x3(v))
Translation3D(p::GeometryBasics.Point{3}) = Translation3D(_f32x3(p))

# Point{N,Float32} is N contiguous Float32s, so point batches (mesh vertices,
# position fields) log zero-copy.
Rerun.wire_compatible(::Type{GeometryBasics.Point{2,Float32}}, ::Type{Position2D}) = true
Rerun.wire_compatible(::Type{GeometryBasics.Point{3,Float32}}, ::Type{Position3D}) = true

# Rect stores origin + widths; Rerun boxes store center + half-size:
# center = origin + widths/2, half_size = widths/2 (pinned in the test).

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   rect::GeometryBasics.Rect{3}; static::Bool=false, inject_time::Bool=!static)
    Rerun.log(r, entity_path, _boxes3d([rect]); inject_time=inject_time)
end

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   rect::GeometryBasics.Rect{2}; static::Bool=false, inject_time::Bool=!static)
    Rerun.log(r, entity_path, _boxes2d([rect]); inject_time=inject_time)
end

# Vectors of rects -> a single Boxes archetype (one row, many boxes).
function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   rects::AbstractVector{<:GeometryBasics.Rect{3}}; static::Bool=false, inject_time::Bool=!static)
    Rerun.log(r, entity_path, _boxes3d(rects); inject_time=inject_time)
end

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   rects::AbstractVector{<:GeometryBasics.Rect{2}}; static::Bool=false, inject_time::Bool=!static)
    Rerun.log(r, entity_path, _boxes2d(rects); inject_time=inject_time)
end

# Convert each coordinate with _f32xN, independent of the eltype
# `origin .+ widths` returns.
function _boxes3d(rects)
    half = HalfSize3D[HalfSize3D(_f32x3(GeometryBasics.widths(b) ./ 2)) for b in rects]
    cen  = Translation3D[Translation3D(_f32x3(GeometryBasics.origin(b) .+ GeometryBasics.widths(b) ./ 2)) for b in rects]
    Boxes3D(half; centers=cen)
end

function _boxes2d(rects)
    half = HalfSize2D[HalfSize2D(_f32x2(GeometryBasics.widths(b) ./ 2)) for b in rects]
    cen  = Position2D[Position2D(_f32x2(GeometryBasics.origin(b) .+ GeometryBasics.widths(b) ./ 2)) for b in rects]
    Boxes2D(half; centers=cen)
end

# A LineString logs as one open strip; a Polygon logs its exterior ring with
# the loop closed (first vertex appended), and interior rings are dropped.

# Version-robust coordinate extraction: a Vector of Points.
_points(x) = collect(GeometryBasics.coordinates(x))

_strip3d(pts) = LineStrip3D(NTuple{3,Float32}[_f32x3(p) for p in pts])
_strip2d(pts) = LineStrip2D(NTuple{2,Float32}[_f32x2(p) for p in pts])

_is3d(pts) = !isempty(pts) && length(first(pts)) == 3

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   ls::GeometryBasics.LineString; static::Bool=false, inject_time::Bool=!static)
    pts = _points(ls)
    arch = _is3d(pts) ? LineStrips3D([_strip3d(pts)]) : LineStrips2D([_strip2d(pts)])
    Rerun.log(r, entity_path, arch; inject_time=inject_time)
end

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   poly::GeometryBasics.Polygon; static::Bool=false, inject_time::Bool=!static)
    pts = _points(poly)
    if !isempty(pts) && first(pts) != last(pts)
        pts = vcat(pts, [first(pts)])
    end
    arch = _is3d(pts) ? LineStrips3D([_strip3d(pts)]) : LineStrips2D([_strip2d(pts)])
    Rerun.log(r, entity_path, arch; inject_time=inject_time)
end

# Mesh -> Mesh3D. Vertices decompose to Vector{Point3f}, which the typed path
# reinterprets zero-copy into Position3D — the one zero-copy hop in this ext.
# Faces are the trap: GeometryBasics indices are 1-based, Rerun's are 0-based,
# so subtract one (pinned in the test).

# `GeometryBasics.value(face[i])` is the 1-based index — OffsetInteger has no
# direct Int/UInt32 conversion, so go through `value`.
@inline _idx0(x)::UInt32 = UInt32(GeometryBasics.value(x) - 1)

@inline _tri(face) =
    TriangleIndices((_idx0(face[1]), _idx0(face[2]), _idx0(face[3])))

function _mesh3d(mesh::GeometryBasics.Mesh)
    verts = decompose(GeometryBasics.Point3f, mesh)
    faces = decompose(GeometryBasics.GLTriangleFace, mesh)
    tris  = TriangleIndices[_tri(f) for f in faces]
    ns    = _mesh_normals(mesh)
    if ns === nothing
        return Mesh3D(verts; triangle_indices=tris)
    else
        return Mesh3D(verts; triangle_indices=tris, vertex_normals=ns)
    end
end

# Extract per-vertex normals if the mesh carries them, else nothing.
function _mesh_normals(mesh::GeometryBasics.Mesh)
    ns = try
        GeometryBasics.normals(mesh)
    catch
        nothing
    end
    ns === nothing && return nothing
    return Vector3D[Vector3D(_f32x3(n)) for n in ns]
end

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   mesh::GeometryBasics.Mesh; static::Bool=false, inject_time::Bool=!static)
    Rerun.log(r, entity_path, _mesh3d(mesh); inject_time=inject_time)
end

# A single triangle becomes a 1-triangle Mesh3D with face (0,1,2).
function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   tri::GeometryBasics.Ngon{Dim,T,3}; static::Bool=false, inject_time::Bool=!static) where {Dim,T}
    pts   = GeometryBasics.coordinates(tri)
    verts = GeometryBasics.Point3f[GeometryBasics.Point3f(_pt3(p)) for p in pts]
    Rerun.log(r, entity_path,
              Mesh3D(verts; triangle_indices=[TriangleIndices((0x0, 0x1, 0x2))]);
              inject_time=inject_time)
end

# Pad a 2D triangle corner to 3D (z=0); pass a 3D corner through.
@inline _pt3(p) = length(p) == 3 ? (Float32(p[1]), Float32(p[2]), Float32(p[3])) :
                                   (Float32(p[1]), Float32(p[2]), 0f0)

# Sphere -> Ellipsoids3D with half_size (r,r,r).

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   s::GeometryBasics.HyperSphere{3}; static::Bool=false, inject_time::Bool=!static)
    Rerun.log(r, entity_path, _ellipsoids([s]); inject_time=inject_time)
end

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   spheres::AbstractVector{<:GeometryBasics.HyperSphere{3}}; static::Bool=false, inject_time::Bool=!static)
    Rerun.log(r, entity_path, _ellipsoids(spheres); inject_time=inject_time)
end

function _ellipsoids(spheres)
    rad  = [Float32(GeometryBasics.radius(s)) for s in spheres]
    half = HalfSize3D[HalfSize3D((rr, rr, rr)) for rr in rad]
    cen  = Translation3D[Translation3D(_f32x3(GeometryBasics.origin(s))) for s in spheres]
    Ellipsoids3D(half; centers=cen)
end

# Cylinder is deliberately unmapped: GeometryBasics cylinders are flat-capped,
# Rerun Capsules3D are hemispherical-capped — a capsule would misrepresent the shape.

end # module RerunGeometryBasicsExt
