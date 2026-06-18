# RerunMeshesExt — Rerun.jl package extension for Meshes.jl (JuliaGeometry).
#
# Follows the convention established by RerunStaticArraysExt (read that file
# first). Two rules dominate:
#
#   1. NO TYPE PIRACY. Every method here attaches either to `Rerun.log` or to a
#      constructor of a `Rerun.Components.*` / `Rerun.Archetypes.*` type
#      (functions/types OWNED by Rerun) and dispatches on a type OWNED by Meshes
#      (`Meshes.Point`, `Meshes.Segment`, `Meshes.SimpleMesh`, ...). We never
#      define a method whose function AND all argument types are foreign.
#
#   2. NO ZERO-COPY HERE. Meshes geometries are NOT wire-shaped: a `Meshes.Point`
#      is its own CRS-aware struct (NOT a `StaticVector`), its coordinates are
#      `Float64` by default and may carry Unitful units. So there is NO exact
#      bit-layout match with Rerun's `Float32` components. Every mapping in this
#      file therefore CONVERTS (extract coords -> `ustrip` -> `Float32`), which
#      COPIES. This is documented per-method. (Contrast: the StaticArrays ext is
#      zero-copy because a `StaticVector{3,Float32}` IS the wire layout.)
#
# RESPONSIBILITY SPLIT: Meshes owns ITS types only. `Meshes.Point` is not a
# `StaticVector`, so there is no overlap with the StaticArrays or GeometryBasics
# exts; Meshes owns its full conversion (coordinate extraction included).
#
# API DEFENSIVENESS: Meshes' public API has shifted across versions. We funnel
# all coordinate extraction through one helper (`_coords`) built on the stable
# trio `to` / `ustrip` / `embeddim`, and all connectivity extraction through
# `topology` + `elements` + `indices`. If a future Meshes renames these, the
# failure is localized to the helper, not scattered across every mapping.
module RerunMeshesExt

using Rerun
using Meshes

# Rerun-owned component/archetype types we target. Adding methods to these is
# not piracy — Rerun owns them.
using Rerun.Components: Position2D, Position3D, HalfSize3D, TriangleIndices
using Rerun.Archetypes: Points2D, Points3D, LineStrips2D, LineStrips3D,
                        Mesh3D, Boxes3D, Ellipsoids3D

# ---------------------------------------------------------------------------
# Layout invariants (precompile-time, off the hot path). These document the
# shapes the conversions below build into. Not zero-copy guards (nothing here is
# zero-copy) — just a tripwire if a schema regen changes a wire layout.
# ---------------------------------------------------------------------------
@assert isbitstype(Position2D)
@assert isbitstype(Position3D)
@assert isbitstype(HalfSize3D)
@assert isbitstype(TriangleIndices)
@assert sizeof(Position3D)     == 3 * sizeof(Float32)
@assert sizeof(HalfSize3D)     == 3 * sizeof(Float32)
@assert sizeof(TriangleIndices) == 3 * sizeof(UInt32)

# ===========================================================================
# Coordinate extraction — the single defensive choke point.
#
# `to(p)` returns the coordinate vector of a Meshes.Point (displacement from the
# origin). Elements may be Unitful quantities, so we strip units, then narrow to
# Float32. Works for 2D and 3D points alike; `embeddim(p)` tells us which.
# This COPIES (Float64/Unitful -> Float32). There is no zero-copy path for
# Meshes points.
#
# UNIT STRIPPING WITHOUT A UNITFUL DEPENDENCY: Meshes does `using Unitful` but
# does NOT re-export `ustrip`, and Rerun does not depend on Unitful. Dividing by
# `oneunit(x)` cancels the unit of a `Unitful.Quantity` (yielding a bare number)
# and is a no-op for a plain `Real` (`oneunit(1.0) === 1.0`). This is the
# idiomatic dependency-free unit strip and keeps this ext from needing Unitful.
# ===========================================================================

@inline _f32(x) = Float32(x / oneunit(x))

# NTuple{2,Float32} / NTuple{3,Float32} from a Meshes.Point's coordinates.
@inline function _coords2(p::Meshes.Point)
    c = Meshes.to(p)
    return (_f32(c[1]), _f32(c[2]))
end
# 3D coords; a 2D point is lifted to the z=0 plane so 2D polygons can feed the
# 3D-only Mesh3D archetype.
@inline function _coords3(p::Meshes.Point)
    c = Meshes.to(p)
    return length(c) >= 3 ? (_f32(c[1]), _f32(c[2]), _f32(c[3])) :
                            (_f32(c[1]), _f32(c[2]), 0f0)
end

# ===========================================================================
# Scalar component constructors: Rerun.Components.<C>(::Meshes.Point)
#
# Method on a Rerun-owned constructor dispatching on a Meshes-owned type. These
# CONVERT (copy) coords to Float32.
# ===========================================================================

# Qualify the method target (`Rerun.Components.PositionND`) so Julia 1.12 does
# not warn about extending a constructor brought in via `using` while Meshes is
# also in scope.
Rerun.Components.Position2D(p::Meshes.Point) = Position2D(_coords2(p))
Rerun.Components.Position3D(p::Meshes.Point) = Position3D(_coords3(p))

# ===========================================================================
# Per-geometry helpers that build vectors of Rerun components (all COPY).
# ===========================================================================

# Vector{Position3D} from any iterable of Meshes.Points.
_positions3(pts) = Position3D[Position3D(_coords3(p)) for p in pts]
_positions2(pts) = Position2D[Position2D(_coords2(p)) for p in pts]

# A single LineStrip3D value (Vector{NTuple{3,Float32}}) from Meshes.Points.
_strip3(pts) = NTuple{3,Float32}[_coords3(p) for p in pts]
_strip2(pts) = NTuple{2,Float32}[_coords2(p) for p in pts]

# ===========================================================================
# Point -> Position2D / Position3D batch log sugar.
#
# Bare-vector default is POSITIONS (per the shared convention). A vector of
# Meshes.Points logs as Points-flavored positions. We pick 2D vs 3D from the
# element's embedding dimension. CONVERTS (copies) to Float32.
# ===========================================================================

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   pts::AbstractVector{<:Meshes.Point}; inject_time::Bool=true)
    isempty(pts) && throw(ArgumentError("log: empty Meshes.Point vector"))
    if Meshes.embeddim(first(pts)) == 2
        Rerun.log(r, entity_path, Position2D, _positions2(pts); inject_time=inject_time)
    else
        Rerun.log(r, entity_path, Position3D, _positions3(pts); inject_time=inject_time)
    end
end

# Single point -> one-element position batch.
function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   p::Meshes.Point; inject_time::Bool=true)
    Rerun.log(r, entity_path, [p]; inject_time=inject_time)
end

# ===========================================================================
# Polyline geometries -> LineStrips2D / LineStrips3D.
#
# Segment (2 vertices), Rope (open chain), Ring (closed chain — we append the
# first vertex to close it visually). Each becomes ONE strip. CONVERTS (copies).
#
# `Meshes.Polytope`-with-`vertices` covers Segment/Rope/Ring uniformly. We
# dispatch on the concrete Meshes types so we don't accidentally capture
# polygons/meshes.
# ===========================================================================

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
          inject_time::Bool=true) =
    _log_one_strip(r, entity_path, g; close=false, inject_time=inject_time)

Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString, g::Meshes.Rope;
          inject_time::Bool=true) =
    _log_one_strip(r, entity_path, g; close=false, inject_time=inject_time)

Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString, g::Meshes.Ring;
          inject_time::Bool=true) =
    _log_one_strip(r, entity_path, g; close=true, inject_time=inject_time)

# ===========================================================================
# Triangle / Ngon -> Mesh3D (single polygon, fan-triangulated).
#
# A polygon's own vertices become the Mesh3D vertex_positions; the triangle
# faces fan from vertex 0: (0,1,2),(0,2,3),... 0-BASED (Rerun is 0-based;
# this local fan is already 0-based). CONVERTS (copies).
# ===========================================================================

# Fan-triangulate n local 0-based vertices -> Vector{TriangleIndices}.
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
          inject_time::Bool=true) =
    Rerun.log(r, entity_path, _polygon_mesh(g); inject_time=inject_time)

Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString, g::Meshes.Ngon;
          inject_time::Bool=true) =
    Rerun.log(r, entity_path, _polygon_mesh(g); inject_time=inject_time)

# ===========================================================================
# SimpleMesh -> Mesh3D.
#
# vertices(mesh) -> vertex_positions (converted to Float32 Position3D, COPY).
# topology(mesh) -> elements; each element's `indices` is a 1-BASED vertex-index
# tuple. THE GOTCHA: Meshes is 1-based, Rerun is 0-based, so we subtract 1.
# Non-triangle elements (quads, ngons) are fan-triangulated in GLOBAL mesh-index
# space. CONVERTS (copies) both positions and indices.
# ===========================================================================

# 1-based global vertex-index tuple -> 0-based Rerun TriangleIndices, fan-split.
function _faces_from_indices(idx)
    inds = collect(idx)              # 1-based global vertex indices
    n = length(inds)
    n < 3 && return TriangleIndices[]
    faces = Vector{TriangleIndices}(undef, n - 2)
    # Fan from the first vertex; convert 1-based -> 0-based (subtract 1).
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
          inject_time::Bool=true) =
    Rerun.log(r, entity_path, _simplemesh_mesh3d(m); inject_time=inject_time)

# ===========================================================================
# Box -> Boxes3D (center + half-size).
#
# Meshes.Box exposes minimum/maximum corners. Rerun Boxes3D wants a CENTER and a
# HALF-SIZE (NOT min/max, NOT full size). THE GOTCHA:
#   center    = (min + max) / 2
#   half_size = (max - min) / 2
# CONVERTS (copies) to Float32. The `Rerun.log` method below rejects non-3D boxes.
# ===========================================================================

function _box_center_halfsize(b::Meshes.Box)
    # `minimum`/`maximum` are Base functions that Meshes extends for Box — they
    # return the lower/upper corner Points.
    lo = Meshes.to(minimum(b))
    hi = Meshes.to(maximum(b))
    center = ntuple(i -> (_f32(lo[i]) + _f32(hi[i])) / 2f0, 3)
    half   = ntuple(i -> (_f32(hi[i]) - _f32(lo[i])) / 2f0, 3)
    return Position3D(center), HalfSize3D(half)
end

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString, b::Meshes.Box;
                   inject_time::Bool=true)
    Meshes.embeddim(b) == 3 ||
        throw(ArgumentError("RerunMeshesExt: only 3D Meshes.Box -> Boxes3D is supported"))
    c, h = _box_center_halfsize(b)
    Rerun.log(r, entity_path, Boxes3D([h]; centers=[c]); inject_time=inject_time)
end

# ===========================================================================
# Ball / Sphere -> Ellipsoids3D (center + equal half-sizes = radius).
#
# An Ellipsoids3D with half_size (r,r,r) is a sphere. center(g) and radius(g)
# are the stable accessors. CONVERTS (copies) to Float32.
# ===========================================================================

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
          inject_time::Bool=true) =
    _log_sphere(r, entity_path, g; inject_time=inject_time)

Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString, g::Meshes.Sphere;
          inject_time::Bool=true) =
    _log_sphere(r, entity_path, g; inject_time=inject_time)

end # module RerunMeshesExt
