# Exercises the RerunStaticArraysExt package extension.

using Rerun
using Rerun.Components: Position2D, Position3D, TransformMat3x3, Vector3D
using StaticArrays
using Test

# Zero-copy declaration for a component outside the extension's default
# mapping (method definitions must sit at top level).
Rerun.wire_compatible(::Type{SVector{3,Float32}}, ::Type{Vector3D}) = true

@testset "RerunStaticArraysExt" begin
    @test Base.get_extension(Rerun, :RerunStaticArraysExt) !== nothing

    @testset "scalar constructors" begin
        p3 = Position3D(SVector{3,Float32}(1, 2, 3))
        @test p3 isa Position3D
        @test p3.xyz == (1f0, 2f0, 3f0)

        p2 = Position2D(SVector{2,Float32}(4, 5))
        @test p2.xy == (4f0, 5f0)

        # Float64 input is accepted and converted to Float32.
        p3d = Position3D(SVector{3,Float64}(1.5, 2.5, 3.5))
        @test p3d.xyz === (1.5f0, 2.5f0, 3.5f0)
    end

    @testset "SMatrix{3,3} -> TransformMat3x3 (column-major flat_columns)" begin
        # Math matrix:
        #   [1 4 7]
        #   [2 5 8]
        #   [3 6 9]
        # Rerun flat_columns (column-major) must be (1,2,3, 4,5,6, 7,8,9).
        m = SMatrix{3,3,Float32}(1, 2, 3, 4, 5, 6, 7, 8, 9)  # SMatrix ctor is column-major
        @test m[1, 1] == 1f0 && m[2, 1] == 2f0 && m[1, 2] == 4f0  # confirm orientation
        tm = TransformMat3x3(m)
        @test tm isa TransformMat3x3
        @test tm.matrix == (1f0, 2f0, 3f0, 4f0, 5f0, 6f0, 7f0, 8f0, 9f0)
    end

    @testset "traits: component mapping + wire compatibility" begin
        @test Rerun.component(SVector{3,Float32}) === Position3D
        @test Rerun.component(SVector{3,Float64}) === Position3D
        @test Rerun.component(SVector{2,Float32}) === Position2D

        @test Rerun.wire_compatible(SVector{3,Float32}, Position3D)
        @test Rerun.wire_compatible(SVector{2,Float32}, Position2D)
        @test Rerun.wire_compatible(SMatrix{3,3,Float32,9}, TransformMat3x3)
        @test !Rerun.wire_compatible(SVector{3,Float64}, Position3D)
        @test !Rerun.wire_compatible(MVector{3,Float32}, Position3D)
    end

    @testset "materialization: declared eltypes pass through, others copy" begin
        v3 = [SVector{3,Float32}(i, i + 1, i + 2) for i in 1:4]
        @test Rerun._materialize(Position3D, v3) === v3        # zero-copy pass-through

        v2 = [SVector{2,Float32}(i, -i) for i in 1:3]
        @test Rerun._materialize(Position2D, v2) === v2

        v3d = [SVector{3,Float64}(i, i, i) for i in 1:3]
        batch = Rerun._materialize(Position3D, v3d)            # converted copy
        @test eltype(batch) === Position3D
        @test batch !== v3d
        @test batch[3].xyz == (3f0, 3f0, 3f0)
    end

    @testset "bare-vector log defaults to positions" begin
        rec = RecordingStream("rerun_jl_staticarrays")
        out = tempname() * ".rrd"
        Rerun.save(rec, out)
        Rerun.set_time(rec, "frame", 0)

        pts3 = [SVector{3,Float32}(i, 0, 0) for i in 1:5]      # zero-copy Position3D
        pts2 = [SVector{2,Float32}(i, i) for i in 1:5]         # zero-copy Position2D
        pts3d = [SVector{3,Float64}(i, 0, 0) for i in 1:5]     # converted Position3D

        Rerun.log(rec, "p3", pts3)
        Rerun.log(rec, "p2", pts2)
        Rerun.log(rec, "p3d", pts3d)

        # Explicit form with the top-level wire_compatible declaration above.
        Rerun.log(rec, "vecs", Vector3D, pts3)

        flush(rec)
        @test isfile(out) && filesize(out) > 0
    end
end
