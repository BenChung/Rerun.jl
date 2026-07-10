# Exercises the RerunStaticArraysExt package extension. Runs in an env that has
# StaticArrays as a (test) dependency, which triggers the extension to load.

using Rerun
using Rerun.Components: Position2D, Position3D, TransformMat3x3
using StaticArrays
using Test

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

    @testset "zero-copy batch reinterpret (Float32)" begin
        v3 = [SVector{3,Float32}(i, i + 1, i + 2) for i in 1:4]
        ext = Base.get_extension(Rerun, :RerunStaticArraysExt)
        batch = ext._as_position_batch(Position3D, v3)
        @test eltype(batch) === Position3D
        # ReinterpretArray shares the parent's memory -> zero-copy view.
        @test batch isa Base.ReinterpretArray
        @test parent(batch) === v3
        @test batch[1].xyz == (1f0, 2f0, 3f0)
        @test sizeof(SVector{3,Float32}) == sizeof(Position3D)

        v2 = [SVector{2,Float32}(i, -i) for i in 1:3]
        batch2 = ext._as_position_batch(Position2D, v2)
        @test batch2 isa Base.ReinterpretArray
        @test batch2[2].xy == (2f0, -2f0)
    end

    @testset "convert batch (Float64 copies, not a view)" begin
        ext = Base.get_extension(Rerun, :RerunStaticArraysExt)
        v3 = [SVector{3,Float64}(i, i, i) for i in 1:3]
        batch = ext._as_position_batch(Position3D, v3)
        @test eltype(batch) === Position3D
        @test !(batch isa Base.ReinterpretArray)   # converted copy
        @test batch[3].xyz == (3f0, 3f0, 3f0)
    end

    @testset "bare-vector log sugar defaults to positions" begin
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

        # Explicit interop form logs SVectors as Vector3D through the same
        # zero-copy base typed-batch path used for positions.
        Rerun.log(rec, "vecs", Rerun.Components.Vector3D, pts3)

        flush(rec)
        @test isfile(out) && filesize(out) > 0
    end
end
