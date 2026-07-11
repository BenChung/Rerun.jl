# Exercises the RerunMeshesExt package extension.
#
# Pins the load-bearing gotchas with concrete assertions:
#   * SimpleMesh face reindexing: Meshes is 1-based, Rerun is 0-based.
#   * Box -> Boxes3D: center = (min+max)/2, half_size = (max-min)/2, not the
#     corners and not the full size.
#   * Coordinate extraction narrows Float64 -> Float32 (Meshes points are not
#     wire-shaped; every mapping copies).

using Rerun
using Rerun.Components: Position2D, Position3D, HalfSize3D, TriangleIndices
using Rerun.Archetypes: Mesh3D, Boxes3D, Ellipsoids3D, LineStrips3D
using Meshes
using Test

@testset "RerunMeshesExt" begin
    ext = Base.get_extension(Rerun, :RerunMeshesExt)
    @test ext !== nothing

    @testset "Point -> Position (Float64 -> Float32 copy)" begin
        p3 = Meshes.Point(1.0, 2.0, 3.0)
        c3 = Position3D(p3)
        @test c3 isa Position3D
        @test c3.xyz === (1f0, 2f0, 3f0)        # narrowed to Float32

        p2 = Meshes.Point(4.0, 5.0)
        c2 = Position2D(p2)
        @test c2.xy === (4f0, 5f0)
    end

    @testset "coords helper strips units / narrows to Float32" begin
        p = Meshes.Point(1.5, 2.5, 3.5)
        @test ext._coords3(p) === (1.5f0, 2.5f0, 3.5f0)
        # 2D point lifted to z=0 so it can feed 3D-only Mesh3D.
        p2 = Meshes.Point(1.0, 2.0)
        @test ext._coords3(p2) === (1f0, 2f0, 0f0)
    end

    @testset "SimpleMesh -> Mesh3D: face reindexing 1-based -> 0-based (GOTCHA)" begin
        # A unit square split into two triangles. Meshes connectivity is 1-based.
        # SimpleMesh needs a concretely-typed point vector, so build it with a bare
        # comprehension; `Meshes.Point[...]` widens to an abstract eltype.
        pts = [
            Meshes.Point(0.0, 0.0, 0.0),
            Meshes.Point(1.0, 0.0, 0.0),
            Meshes.Point(1.0, 1.0, 0.0),
            Meshes.Point(0.0, 1.0, 0.0),
        ]
        connec = connect.([(1, 2, 3), (1, 3, 4)], Triangle)  # 1-based
        mesh = SimpleMesh(pts, connec)

        m3 = ext._simplemesh_mesh3d(mesh)
        @test m3 isa Mesh3D

        verts = m3.fields.vertex_positions
        faces = m3.fields.triangle_indices
        @test length(verts) == 4
        @test verts[1].xyz === (0f0, 0f0, 0f0)
        @test verts[3].xyz === (1f0, 1f0, 0f0)

        @test length(faces) == 2
        # 1-based (1,2,3),(1,3,4) become 0-based (0,1,2),(0,2,3).
        @test faces[1].indices === (UInt32(0), UInt32(1), UInt32(2))
        @test faces[2].indices === (UInt32(0), UInt32(2), UInt32(3))
        # Every emitted index is strictly < vertex count (no off-by-one overflow).
        @test all(all(i -> i < length(verts), f.indices) for f in faces)
    end

    @testset "Triangle / Ngon -> Mesh3D fan (local 0-based)" begin
        tri = Meshes.Triangle(Meshes.Point(0.0, 0.0, 0.0),
                              Meshes.Point(1.0, 0.0, 0.0),
                              Meshes.Point(0.0, 1.0, 0.0))
        mt = ext._polygon_mesh(tri)
        @test length(mt.fields.vertex_positions) == 3
        @test mt.fields.triangle_indices[1].indices === (UInt32(0), UInt32(1), UInt32(2))

        # A quad fans into 2 triangles: (0,1,2),(0,2,3).
        quad = Meshes.Quadrangle(Meshes.Point(0.0, 0.0, 0.0),
                                 Meshes.Point(1.0, 0.0, 0.0),
                                 Meshes.Point(1.0, 1.0, 0.0),
                                 Meshes.Point(0.0, 1.0, 0.0))
        mq = ext._polygon_mesh(quad)
        @test length(mq.fields.triangle_indices) == 2
        @test mq.fields.triangle_indices[1].indices === (UInt32(0), UInt32(1), UInt32(2))
        @test mq.fields.triangle_indices[2].indices === (UInt32(0), UInt32(2), UInt32(3))
    end

    @testset "Box -> Boxes3D: center + half-size (GOTCHA)" begin
        # Box from (2,4,6) to (4,8,12): center (3,6,9), half_size (1,2,3), not the corners or full extents.
        b = Meshes.Box(Meshes.Point(2.0, 4.0, 6.0), Meshes.Point(4.0, 8.0, 12.0))
        c, h = ext._box_center_halfsize(b)
        @test c isa Position3D
        @test h isa HalfSize3D
        @test c.xyz === (3f0, 6f0, 9f0)
        @test h.xyz === (1f0, 2f0, 3f0)
    end

    @testset "Ball / Sphere -> Ellipsoids3D (equal half-sizes = radius)" begin
        ball = Meshes.Ball(Meshes.Point(1.0, 2.0, 3.0), 5.0)
        center, rad = ext._sphere_center_radius(ball)
        @test center.xyz === (1f0, 2f0, 3f0)
        @test rad === 5f0
    end

    @testset "Segment -> LineStrips3D (one strip, converted)" begin
        seg = Meshes.Segment(Meshes.Point(0.0, 0.0, 0.0), Meshes.Point(1.0, 1.0, 1.0))
        strip, is3d = ext._line_strip(seg; close=false)
        @test is3d
        @test strip isa Rerun.Components.LineStrip3D
        @test strip.value == NTuple{3,Float32}[(0f0, 0f0, 0f0), (1f0, 1f0, 1f0)]
    end

    @testset "Ring -> LineStrips3D closes the loop" begin
        ring = Meshes.Ring(Meshes.Point(0.0, 0.0, 0.0),
                           Meshes.Point(1.0, 0.0, 0.0),
                           Meshes.Point(0.0, 1.0, 0.0))
        strip, is3d = ext._line_strip(ring; close=true)
        @test is3d
        # Closing appends the first vertex again.
        @test length(strip.value) == 4
        @test strip.value[1] == strip.value[end]
    end

    @testset "end-to-end log smoke test (writes a .rrd)" begin
        rec = RecordingStream("rerun_jl_meshes")
        out = tempname() * ".rrd"
        Rerun.save(rec, out)
        Rerun.set_time(rec, "frame", 0)

        pts = Meshes.Point[Meshes.Point(Float64(i), 0.0, 0.0) for i in 1:5]
        Rerun.log(rec, "points", pts)                                  # -> Points3D positions

        seg = Meshes.Segment(Meshes.Point(0.0, 0.0, 0.0), Meshes.Point(1.0, 1.0, 1.0))
        Rerun.log(rec, "seg", seg)                                     # -> LineStrips3D

        mesh = SimpleMesh(
            [Meshes.Point(0.0, 0.0, 0.0), Meshes.Point(1.0, 0.0, 0.0),
             Meshes.Point(0.0, 1.0, 0.0)],
            connect.([(1, 2, 3)], Triangle),
        )
        Rerun.log(rec, "mesh", mesh)                                   # -> Mesh3D

        Rerun.log(rec, "box", Meshes.Box(Meshes.Point(0.0, 0.0, 0.0),
                                         Meshes.Point(1.0, 1.0, 1.0)))  # -> Boxes3D
        Rerun.log(rec, "ball", Meshes.Ball(Meshes.Point(0.0, 0.0, 0.0), 1.0)) # -> Ellipsoids3D

        flush(rec)
        @test isfile(out) && filesize(out) > 0
    end
end
