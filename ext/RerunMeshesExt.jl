# RerunMeshesExt — maps Meshes.jl (JuliaGeometry) geometries to Rerun
# archetypes. Extension convention: see RerunStaticArraysExt.jl.
#
# A `Meshes.Point` is a CRS-aware struct with Float64 (possibly Unitful)
# coordinates, so every mapping converts to Float32 and copies. Meshes' API has
# shifted across versions, so coordinate extraction funnels through `_coords*`
# (built on the stable `to`/`embeddim`) and connectivity through
# `topology`/`elements`/`indices` — a future rename breaks one helper, not
# every mapping.
module RerunMeshesExt

using Rerun
using Meshes

using Rerun.Components: Position2D, Position3D, HalfSize3D, TriangleIndices
using Rerun.Archetypes: Points2D, Points3D, LineStrips2D, LineStrips3D,
                        Mesh3D, Boxes3D, Ellipsoids3D

# Wire-layout tripwires: a schema regen that changes a layout fails precompile here.
@assert isbitstype(Position2D)
@assert isbitstype(Position3D)
@assert isbitstype(HalfSize3D)
@assert isbitstype(TriangleIndices)
@assert sizeof(Position3D)     == 3 * sizeof(Float32)
@assert sizeof(HalfSize3D)     == 3 * sizeof(Float32)
@assert sizeof(TriangleIndices) == 3 * sizeof(UInt32)

# `to(p)` is the coordinate vector; elements may be Unitful quantities.
# Dividing by `oneunit(x)` cancels the unit (and is the identity for plain
# Reals), which strips units without a Unitful dependency.
@inline _f32(x) = Float32(x / oneunit(x))

@inline function _coords2(p::Meshes.Point)
    c = Meshes.to(p)
    return (_f32(c[1]), _f32(c[2]))
end
# A 2D point lifts to z=0 so 2D polygons can feed the 3D-only Mesh3D archetype.
@inline function _coords3(p::Meshes.Point)
    c = Meshes.to(p)
    return length(c) >= 3 ? (_f32(c[1]), _f32(c[2]), _f32(c[3])) :
                            (_f32(c[1]), _f32(c[2]), 0f0)
end

# Qualified method targets so Julia 1.12 does not warn about extending a
# constructor brought in via `using`.
Rerun.Components.Position2D(p::Meshes.Point) = Position2D(_coords2(p))
Rerun.Components.Position3D(p::Meshes.Point) = Position3D(_coords3(p))

# Component-vector builders (Float32 copies).
_positions3(pts) = Position3D[Position3D(_coords3(p)) for p in pts]
_positions2(pts) = Position2D[Position2D(_coords2(p)) for p in pts]
_strip3(pts) = NTuple{3,Float32}[_coords3(p) for p in pts]
_strip2(pts) = NTuple{2,Float32}[_coords2(p) for p in pts]

# A bare vector of points logs as positions; 2D vs 3D from the embedding dimension.

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   pts::AbstractVector{<:Meshes.Point}; static::Bool=false, inject_time::Bool=!static)
    isempty(pts) && throw(ArgumentError("log: empty Meshes.Point vector"))
    if Meshes.embeddim(first(pts)) == 2
        Rerun.log(r, entity_path, Position2D, _positions2(pts); inject_time=inject_time)
    else
        Rerun.log(r, entity_path, Position3D, _positions3(pts); inject_time=inject_time)
    end
end

# Single point -> one-element position batch.
function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   p::Meshes.Point; static::Bool=false, inject_time::Bool=!static)
    Rerun.log(r, entity_path, [p]; inject_time=inject_time)
end

# Segment, Rope (open), and Ring (closed — append the first vertex) each log
# as one strip. Dispatch is on the concrete types so polygons/meshes stay with
# their own methods.

_is3d(g) = Meshes.embeddim(g) == 3

# Build one strip (closing it if `close`).
function _line_strip(g; close::Bool=false)
    vs = collect(Meshes.vertices(g))
    if _is3d(g)
        s = _strip3(vs)
        close && !isempty(s) && push!(s, s[1])
        return (Rerun.Components.LineStrip3D(s), true)
    else
        s = _strip2(vs)
        close && !isempty(s) && push!(s, s[1])
        return (Rerun.Components.LineStrip2D(s), false)
    end
end

function _log_one_strip(r, entity_path, g; close::Bool, inject_time::Bool)
    strip, is3d = _line_strip(g; close=close)
    if is3d
        Rerun.log(r, entity_path, LineStrips3D([strip]); inject_time=inject_time)
    else
        Rerun.log(r, entity_path, LineStrips2D([strip]); inject_time=inject_time)
    end
end

Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString, g::Meshes.Segment;
          static::Bool=false, inject_time::Bool=!static) =
    _log_one_strip(r, entity_path, g; close=false, inject_time=inject_time)

Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString, g::Meshes.Rope;
          static::Bool=false, inject_time::Bool=!static) =
    _log_one_strip(r, entity_path, g; close=false, inject_time=inject_time)

Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString, g::Meshes.Ring;
          static::Bool=false, inject_time::Bool=!static) =
    _log_one_strip(r, entity_path, g; close=true, inject_time=inject_time)

# A single polygon fan-triangulates from vertex 0: (0,1,2),(0,2,3),... —
# already 0-based.
function _fan_faces(n::Integer)
    n < 3 && return TriangleIndices[]
    faces = Vector{TriangleIndices}(undef, n - 2)
    @inbounds for i in 1:(n - 2)
        faces[i] = TriangleIndices((UInt32(0), UInt32(i), UInt32(i + 1)))
    end
    return faces
end

function _polygon_mesh(g)
    vs = collect(Meshes.vertices(g))
    verts = _positions3(vs)
    faces = _fan_faces(length(verts))
    return Mesh3D(verts; triangle_indices=faces)
end

Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString, g::Meshes.Triangle;
          static::Bool=false, inject_time::Bool=!static) =
    Rerun.log(r, entity_path, _polygon_mesh(g); inject_time=inject_time)

Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString, g::Meshes.Ngon;
          static::Bool=false, inject_time::Bool=!static) =
    Rerun.log(r, entity_path, _polygon_mesh(g); inject_time=inject_time)

# SimpleMesh -> Mesh3D. The trap: Meshes vertex indices are 1-based, Rerun's
# 0-based — subtract one. Non-triangle elements fan-triangulate in global
# index space.
function _faces_from_indices(idx)
    inds = collect(idx)
    n = length(inds)
    n < 3 && return TriangleIndices[]
    faces = Vector{TriangleIndices}(undef, n - 2)
    # Fan from the first vertex; 1-based -> 0-based.
    i0 = UInt32(inds[1] - 1)
    @inbounds for k in 1:(n - 2)
        faces[k] = TriangleIndices((i0,
                                    UInt32(inds[k + 1] - 1),
                                    UInt32(inds[k + 2] - 1)))
    end
    return faces
end

function _simplemesh_mesh3d(m::Meshes.SimpleMesh)
    verts = _positions3(Meshes.vertices(m))
    topo = Meshes.topology(m)
    faces = TriangleIndices[]
    for e in Meshes.elements(topo)
        append!(faces, _faces_from_indices(Meshes.indices(e)))
    end
    return Mesh3D(verts; triangle_indices=faces)
end

Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString, m::Meshes.SimpleMesh;
          static::Bool=false, inject_time::Bool=!static) =
    Rerun.log(r, entity_path, _simplemesh_mesh3d(m); inject_time=inject_time)

# Meshes.Box exposes min/max corners; Rerun boxes store center + half-size:
# center = (min+max)/2, half_size = (max-min)/2.
function _box_center_halfsize(b::Meshes.Box)
    # Base minimum/maximum, extended by Meshes to return the corner Points.
    lo = Meshes.to(minimum(b))
    hi = Meshes.to(maximum(b))
    center = ntuple(i -> (_f32(lo[i]) + _f32(hi[i])) / 2f0, 3)
    half   = ntuple(i -> (_f32(hi[i]) - _f32(lo[i])) / 2f0, 3)
    return Position3D(center), HalfSize3D(half)
end

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString, b::Meshes.Box;
                   static::Bool=false, inject_time::Bool=!static)
    Meshes.embeddim(b) == 3 ||
        throw(ArgumentError("RerunMeshesExt: only 3D Meshes.Box -> Boxes3D is supported"))
    c, h = _box_center_halfsize(b)
    Rerun.log(r, entity_path, Boxes3D([h]; centers=[c]); inject_time=inject_time)
end

# Ball/Sphere -> Ellipsoids3D with half_size (r,r,r).

function _sphere_center_radius(g)
    c = Meshes.to(Meshes.center(g))
    r = _f32(Meshes.radius(g))
    return Position3D((_f32(c[1]), _f32(c[2]), _f32(c[3]))), r
end

function _log_sphere(r, entity_path, g; inject_time::Bool)
    Meshes.embeddim(g) == 3 ||
        throw(ArgumentError("RerunMeshesExt: only 3D Ball/Sphere -> Ellipsoids3D is supported"))
    center, rad = _sphere_center_radius(g)
    half = HalfSize3D((rad, rad, rad))
    Rerun.log(r, entity_path, Ellipsoids3D([half]; centers=[center]); inject_time=inject_time)
end

Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString, g::Meshes.Ball;
          static::Bool=false, inject_time::Bool=!static) =
    _log_sphere(r, entity_path, g; inject_time=inject_time)

Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString, g::Meshes.Sphere;
          static::Bool=false, inject_time::Bool=!static) =
    _log_sphere(r, entity_path, g; inject_time=inject_time)

end # module RerunMeshesExt
