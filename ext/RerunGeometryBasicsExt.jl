# RerunGeometryBasicsExt — maps GeometryBasics COMPOSITE geometry types to Rerun
# archetypes. Modelled on RerunStaticArraysExt (read that first); follows the same
# convention:
#
#   1. NO TYPE PIRACY. Every method added here attaches to `Rerun.log` or to a
#      constructor of a `Rerun.Components.*` / `Rerun.Archetypes.*` type (all
#      OWNED by Rerun) and dispatches on a type OWNED by GeometryBasics
#      (`Rect`, `LineString`, `Polygon`, `Mesh`, `Ngon`, `HyperSphere`, ...).
#      We never define a method whose function AND all argument types are foreign.
#
#   2. RESPONSIBILITY SPLIT — this ext does NOT touch points/vectors. A
#      GeometryBasics `Point{N,Float32}` IS a `StaticArrays.StaticVector`, so the
#      `StaticVector -> Position` mapping (and its zero-copy reinterpret) already
#      lives in RerunStaticArraysExt. Adding `Point`/`StaticVector` methods here
#      would overlap/clash with it. Instead we build archetypes whose point
#      fields are `Vector{<:Point}` and let the StaticArrays path (and the base
#      typed-batch `Rerun.log`) handle per-point layout. We own ONLY the
#      composite types GeometryBasics adds on top of points.
#
#   3. ZERO-COPY ONLY ON AN EXACT BIT-LAYOUT MATCH. The only place that holds in
#      this ext is when a `Vector{Point3f}`/`Vector{Point2f}` flows straight into
#      a Position3D/Position2D field of an archetype: that vector is reinterpreted
#      (shared memory) by the existing typed path. Everything else here is a
#      structural transform (center/half-size split, ring closing, face
#      reindexing, decompose) that necessarily COPIES — documented per mapping.
module RerunGeometryBasicsExt

using Rerun
using GeometryBasics
# StaticArrays is also a weakdep of this ext (Point <: StaticVector). We do not
# add StaticVector methods here, but having it loaded guarantees the StaticArrays
# ext is active so the point batches below reinterpret zero-copy.
using StaticArrays

# `import` (not `using`): HalfSize2D/HalfSize3D/Translation3D constructors are
# extended below, so importing them makes that unambiguous (no Julia 1.12 warning).
import Rerun.Components: Position2D, Position3D, HalfSize2D, HalfSize3D,
    Translation3D, TriangleIndices, Vector3D, LineStrip2D, LineStrip3D, Radius
using Rerun.Archetypes: Boxes2D, Boxes3D, LineStrips2D, LineStrips3D, Mesh3D,
    Ellipsoids3D

# ---------------------------------------------------------------------------
# Layout invariants (checked at precompile time, not the hot path). These pin
# the wire layouts the conversions below assume; a schema regen that changes a
# layout fails precompilation here instead of corrupting data silently.
# ---------------------------------------------------------------------------
@assert isbitstype(Position3D)
@assert isbitstype(TriangleIndices)
@assert sizeof(HalfSize3D)      == 3 * sizeof(Float32)
@assert sizeof(HalfSize2D)      == 2 * sizeof(Float32)
@assert sizeof(Translation3D)   == 3 * sizeof(Float32)
@assert sizeof(TriangleIndices) == 3 * sizeof(UInt32)

# ===========================================================================
# Small element converters (always copy; trivial). Each builds ONE Rerun
# component from one GeometryBasics value, going through the component's own
# NTuple constructor so the Float32 conversion is correct for any input eltype.
# ===========================================================================

@inline _f32x2(p) = (Float32(p[1]), Float32(p[2]))
@inline _f32x3(p) = (Float32(p[1]), Float32(p[2]), Float32(p[3]))

HalfSize2D(v::GeometryBasics.Vec{2})    = HalfSize2D(_f32x2(v))
HalfSize3D(v::GeometryBasics.Vec{3})    = HalfSize3D(_f32x3(v))
Translation3D(p::GeometryBasics.Point{3}) = Translation3D(_f32x3(p))

# ===========================================================================
# Rect / HyperRectangle -> Boxes2D / Boxes3D.
#
# GOTCHA (pinned in the test): GeometryBasics `Rect` stores ORIGIN + WIDTHS
# (a corner and the extents), while Rerun boxes store CENTER + HALF-SIZE. So:
#     center    = origin + widths/2
#     half_size = widths/2
# This is a structural transform -> it COPIES (one center + one half-size per
# rect). NOT zero-copy.
# ===========================================================================

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   rect::GeometryBasics.Rect{3}; inject_time::Bool=true)
    Rerun.log(r, entity_path, _boxes3d([rect]); inject_time=inject_time)
end

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   rect::GeometryBasics.Rect{2}; inject_time::Bool=true)
    Rerun.log(r, entity_path, _boxes2d([rect]); inject_time=inject_time)
end

# Vectors of rects -> a single Boxes archetype (one row, many boxes).
function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   rects::AbstractVector{<:GeometryBasics.Rect{3}}; inject_time::Bool=true)
    Rerun.log(r, entity_path, _boxes3d(rects); inject_time=inject_time)
end

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   rects::AbstractVector{<:GeometryBasics.Rect{2}}; inject_time::Bool=true)
    Rerun.log(r, entity_path, _boxes2d(rects); inject_time=inject_time)
end

# center = origin + widths/2, half_size = widths/2. We compute on the raw
# GeometryBasics vectors and convert each coordinate to Float32 ourselves
# (via _f32xN), so we never depend on the return type of `origin .+ widths`.
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

# ===========================================================================
# LineString / Polygon -> LineStrips2D / LineStrips3D.
#
# A LineString is one open polyline; we log it as a single strip. A Polygon is a
# closed region; we log its exterior ring and CLOSE THE LOOP (append the first
# vertex) so Rerun draws the closing edge, which is what a polygon means.
#
# Per-point Float32 conversion goes through `_strip3d`/`_strip2d`; this COPIES
# the points into the LineStrip wire layout (Vector{NTuple{N,Float32}}). Not
# zero-copy (the strip component owns its own Vector). Only a
# Polygon's exterior ring is logged; interior rings (holes) are dropped.
# ===========================================================================

# --- coordinate extraction (version-robust): get a Vector of Points. ---
_points(x) = collect(GeometryBasics.coordinates(x))

_strip3d(pts) = LineStrip3D(NTuple{3,Float32}[_f32x3(p) for p in pts])
_strip2d(pts) = LineStrip2D(NTuple{2,Float32}[_f32x2(p) for p in pts])

_is3d(pts) = !isempty(pts) && length(first(pts)) == 3

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   ls::GeometryBasics.LineString; inject_time::Bool=true)
    pts = _points(ls)
    arch = _is3d(pts) ? LineStrips3D([_strip3d(pts)]) : LineStrips2D([_strip2d(pts)])
    Rerun.log(r, entity_path, arch; inject_time=inject_time)
end

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   poly::GeometryBasics.Polygon; inject_time::Bool=true)
    pts = _points(poly)
    if !isempty(pts) && first(pts) != last(pts)
        pts = vcat(pts, [first(pts)])
    end
    arch = _is3d(pts) ? LineStrips3D([_strip3d(pts)]) : LineStrips2D([_strip2d(pts)])
    Rerun.log(r, entity_path, arch; inject_time=inject_time)
end

# ===========================================================================
# Mesh / normal_mesh / Ngon{3} (Triangle) -> Mesh3D.
#
# Vertices  : decompose(Point3f, mesh) -> Vector{Point3f}. This flows into the
#             Mesh3D `vertex_positions` (Position3D) field; the base typed path
#             reinterprets the Vector{Point3f} zero-copy (Point3f is 3×Float32,
#             == Position3D). The only zero-copy hop in this ext.
# Faces     : decompose(GLTriangleFace, mesh). GeometryBasics faces are 1-BASED
#             (OffsetInteger handles GL 0-based storage transparently); Rerun
#             TriangleIndices are 0-BASED UInt32. GOTCHA (pinned in the test):
#             subtract 1 per index. `GeometryBasics.value(face[i])` yields the
#             1-based index (see _idx0 below).
# Normals   : GeometryBasics.normals(mesh), if present, -> Vector3D.
# These face/normal steps COPY (structural transform).
# ===========================================================================

# Convert one face vertex reference to a 0-based UInt32 GL index.
#
# GeometryBasics faces index a vertex array as 1-BASED Julia indices: a face
# element is a `GLIndex` (`OffsetInteger{-1,UInt32}`) and `verts[face[i]]` is the
# right vertex. `GeometryBasics.value(face[i])` returns that 1-BASED index (e.g.
# `GLTriangleFace(1,2,3)` -> values 1,2,3). Rerun `TriangleIndices` are 0-BASED
# UInt32. GOTCHA (pinned in the test): subtract one. Note `Int`/`UInt32` are NOT
# directly defined on `OffsetInteger`, so we MUST go through `value` (not a raw
# numeric conversion) to get a plain integer.
@inline _idx0(x)::UInt32 = UInt32(GeometryBasics.value(x) - 1)

@inline _tri(face) =
    TriangleIndices((_idx0(face[1]), _idx0(face[2]), _idx0(face[3])))

function _mesh3d(mesh::GeometryBasics.Mesh)
    verts = decompose(GeometryBasics.Point3f, mesh)               # Vector{Point3f}, zero-copy into Position3D
    faces = decompose(GeometryBasics.GLTriangleFace, mesh)        # GL faces (0-based storage)
    tris  = TriangleIndices[_tri(f) for f in faces]               # -> 0-based UInt32
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
                   mesh::GeometryBasics.Mesh; inject_time::Bool=true)
    Rerun.log(r, entity_path, _mesh3d(mesh); inject_time=inject_time)
end

# A single triangle (Ngon{Dim,T,3} / Triangle) -> a 1-triangle Mesh3D. Its three
# corner points become the vertices; the single face is (0,1,2). COPIES.
function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   tri::GeometryBasics.Ngon{Dim,T,3}; inject_time::Bool=true) where {Dim,T}
    pts   = GeometryBasics.coordinates(tri)
    verts = GeometryBasics.Point3f[GeometryBasics.Point3f(_pt3(p)) for p in pts]
    Rerun.log(r, entity_path,
              Mesh3D(verts; triangle_indices=[TriangleIndices((0x0, 0x1, 0x2))]);
              inject_time=inject_time)
end

# Pad a 2D triangle corner to 3D (z=0); pass a 3D corner through.
@inline _pt3(p) = length(p) == 3 ? (Float32(p[1]), Float32(p[2]), Float32(p[3])) :
                                   (Float32(p[1]), Float32(p[2]), 0f0)

# ===========================================================================
# Sphere / HyperSphere -> Ellipsoids3D (uniform half-size = radius on all axes).
# center = the sphere's center point; COPIES.
# ===========================================================================

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   s::GeometryBasics.HyperSphere{3}; inject_time::Bool=true)
    Rerun.log(r, entity_path, _ellipsoids([s]); inject_time=inject_time)
end

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   spheres::AbstractVector{<:GeometryBasics.HyperSphere{3}}; inject_time::Bool=true)
    Rerun.log(r, entity_path, _ellipsoids(spheres); inject_time=inject_time)
end

function _ellipsoids(spheres)
    rad  = [Float32(GeometryBasics.radius(s)) for s in spheres]
    half = HalfSize3D[HalfSize3D((rr, rr, rr)) for rr in rad]
    cen  = Translation3D[Translation3D(_f32x3(GeometryBasics.origin(s))) for s in spheres]
    Ellipsoids3D(half; centers=cen)
end

# NOTE: Cylinder -> Capsules3D is intentionally NOT implemented. A GeometryBasics
# `Cylinder` is a flat-capped cylinder (origin/extremity + radius), whereas Rerun
# `Capsules3D` describes hemispherical-capped capsules (length + radius along an
# axis with a translation/rotation). The geometry does not match, so emitting a
# Capsule would misrepresent the shape, so this mapping is omitted.

end # module RerunGeometryBasicsExt
