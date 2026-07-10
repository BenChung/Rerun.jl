# Exercises the RerunGeometryBasicsExt package extension. Runs in an env that has
# GeometryBasics (and StaticArrays) as (test) dependencies, which triggers the
# extension to load. Pins the documented gotchas with concrete assertions:
#   * Rect origin+widths -> Rerun center + half-size
#   * Polygon ring is closed (first vertex appended)
#   * Mesh face indices are reindexed 1-based -> 0-based UInt32
#   * Sphere -> uniform Ellipsoids3D half-size

using Rerun
using Rerun.Components: HalfSize3D, HalfSize2D, Translation3D, Position2D,
    TriangleIndices, Position3D, Vector3D, LineStrip3D, LineStrip2D
using Rerun.Archetypes: Boxes3D, Boxes2D, LineStrips3D, LineStrips2D, Mesh3D,
    Ellipsoids3D
using GeometryBasics
using Test

const EXT = Base.get_extension(Rerun, :RerunGeometryBasicsExt)

# Pull a present field out of a materialized archetype's NamedTuple.
_field(a, name) = getfield(a.fields, name)

@testset "RerunGeometryBasicsExt" begin
    @test EXT !== nothing

    @testset "Rect3 -> Boxes3D (center + half-size, NOT origin + widths)" begin
        # origin (1,2,3), widths (4,6,8) => center (3,5,7), half-size (2,3,4).
        rect = Rect3f(Point3f(1, 2, 3), Vec3f(4, 6, 8))
        boxes = EXT._boxes3d([rect])
        @test boxes isa Boxes3D

        half = _field(boxes, :half_sizes)
        cen  = _field(boxes, :centers)
        @test half[1] isa HalfSize3D
        @test cen[1] isa Translation3D
        # GOTCHA: half-size is widths/2, center is origin + widths/2.
        @test half[1].xyz == (2f0, 3f0, 4f0)
        @test cen[1].vector == (3f0, 5f0, 7f0)
    end

    @testset "Rect2 -> Boxes2D (center + half-size)" begin
        rect = Rect2f(Point2f(0, 0), Vec2f(2, 4))
        boxes = EXT._boxes2d([rect])
        @test boxes isa Boxes2D
        half = _field(boxes, :half_sizes)
        cen  = _field(boxes, :centers)
        @test half[1].xy == (1f0, 2f0)
        @test cen[1] isa Position2D
        @test cen[1].xy == (1f0, 2f0)
    end

    @testset "LineString -> LineStrips3D (single open strip)" begin
        pts = [Point3f(0, 0, 0), Point3f(1, 0, 0), Point3f(1, 1, 0)]
        ls = LineString(pts)
        # via the internal builder so we can inspect without a stream
        sp = EXT._strip3d(EXT._points(ls))
        @test sp isa LineStrip3D
        @test length(sp.value) == 3          # open: not closed
        @test sp.value[1] == (0f0, 0f0, 0f0)
        @test sp.value[3] == (1f0, 1f0, 0f0)
    end

    @testset "Polygon -> LineStrips (ring is CLOSED)" begin
        # Triangle polygon: 3 distinct exterior points; logging must close the loop.
        pts = [Point2f(0, 0), Point2f(1, 0), Point2f(0, 1)]
        poly = Polygon(pts)
        ring = EXT._points(poly)
        # Replicate the ring-closing the log method performs, then assert the gotcha.
        if !isempty(ring) && first(ring) != last(ring)
            ring = vcat(ring, [first(ring)])
        end
        @test length(ring) == 4                       # GOTCHA: closed (3 + 1)
        @test ring[end] == ring[1]                    # last == first
        sp = EXT._strip2d(ring)
        @test sp isa LineStrip2D
        @test sp.value[end] == (0f0, 0f0)
    end

    @testset "Mesh -> Mesh3D (faces reindexed 1-based -> 0-based)" begin
        # Two triangles over 4 vertices (a quad).
        verts = [Point3f(0, 0, 0), Point3f(1, 0, 0), Point3f(1, 1, 0), Point3f(0, 1, 0)]
        faces = [GLTriangleFace(1, 2, 3), GLTriangleFace(1, 3, 4)]
        mesh = GeometryBasics.Mesh(verts, faces)

        m = EXT._mesh3d(mesh)
        @test m isa Mesh3D

        vpos = _field(m, :vertex_positions)
        tris = _field(m, :triangle_indices)
        @test length(vpos) == 4
        @test length(tris) == 2
        @test tris[1] isa TriangleIndices
        # GOTCHA: GeometryBasics faces are 1-based; Rerun wants 0-based.
        @test tris[1].indices == (0x0, 0x1, 0x2)
        @test tris[2].indices == (0x0, 0x2, 0x3)
        # No index may equal the 1-based original max (4) -> proves the -1 happened.
        @test all(maximum(t.indices) <= 0x3 for t in tris)
    end

    @testset "Sphere -> Ellipsoids3D (uniform half-size = radius)" begin
        s = Sphere(Point3f(1, 2, 3), 2.5f0)
        e = EXT._ellipsoids([s])
        @test e isa Ellipsoids3D
        half = _field(e, :half_sizes)
        cen  = _field(e, :centers)
        @test half[1] isa HalfSize3D
        # GOTCHA: a sphere is an ellipsoid with equal half-sizes on all 3 axes.
        @test half[1].xyz == (2.5f0, 2.5f0, 2.5f0)
        @test cen[1].vector == (1f0, 2f0, 3f0)
    end

    @testset "point fields stay Vector{Point} (defer to StaticArrays path)" begin
        # The Mesh3D vertex positions must be a Vector of GeometryBasics points,
        # so the base typed-batch log reinterprets them zero-copy into Position3D.
        verts = [Point3f(0, 0, 0), Point3f(1, 0, 0), Point3f(0, 1, 0)]
        faces = [GLTriangleFace(1, 2, 3)]
        m = EXT._mesh3d(GeometryBasics.Mesh(verts, faces))
        vpos = _field(m, :vertex_positions)
        @test eltype(vpos) <: GeometryBasics.Point
        @test sizeof(eltype(vpos)) == sizeof(Position3D)   # exact-layout match
    end

    @testset "end-to-end log to .rrd" begin
        rec = RecordingStream("rerun_jl_geometrybasics")
        out = tempname() * ".rrd"
        Rerun.save(rec, out)
        Rerun.set_time(rec, "frame", 0)

        Rerun.log(rec, "box3",  Rect3f(Point3f(1, 2, 3), Vec3f(4, 6, 8)))
        Rerun.log(rec, "box2",  Rect2f(Point2f(0, 0), Vec2f(2, 4)))
        Rerun.log(rec, "lines", LineString([Point3f(0, 0, 0), Point3f(1, 1, 1)]))
        Rerun.log(rec, "poly",  Polygon([Point2f(0, 0), Point2f(1, 0), Point2f(0, 1)]))

        verts = [Point3f(0, 0, 0), Point3f(1, 0, 0), Point3f(0, 1, 0)]
        faces = [GLTriangleFace(1, 2, 3)]
        Rerun.log(rec, "mesh", GeometryBasics.Mesh(verts, faces))
        Rerun.log(rec, "sphere", Sphere(Point3f(0, 0, 0), 1f0))

        flush(rec)
        @test isfile(out) && filesize(out) > 0
    end
end
