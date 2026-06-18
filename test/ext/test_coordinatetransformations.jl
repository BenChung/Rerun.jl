# Exercises the RerunCoordinateTransformationsExt package extension. Runs in an
# env that has CoordinateTransformations (and Rotations) as test dependencies,
# which triggers the extension to load.
#
# These tests pin the LOAD-BEARING gotcha for this mapping: the quaternion
# component order. Rotations.jl stores quaternions scalar-FIRST (w, x, y, z);
# Rerun's RotationQuat stores them scalar-LAST (x, y, z, w). The extension must
# reorder. We assert the exact emitted tuple. We also pin the column-major
# flat_columns matrix layout for the mat3x3 fallback.

using Rerun
using Rerun.Components: Translation3D, RotationQuat, TransformMat3x3
using Rerun.Archetypes: Transform3D
using CoordinateTransformations
using Rotations
using StaticArrays
using Test

@testset "RerunCoordinateTransformationsExt" begin
    @test Base.get_extension(Rerun, :RerunCoordinateTransformationsExt) !== nothing

    @testset "Translation -> translation-only Transform3D" begin
        t = Translation(1.0, 2.0, 3.0)
        tf = Transform3D(t)
        @test tf isa Transform3D
        # Only the translation field is populated (everything else nothing).
        @test tf.fields.translation isa AbstractVector{Translation3D}
        @test length(tf.fields.translation) == 1
        @test tf.fields.translation[1].vector === (1f0, 2f0, 3f0)
        @test tf.fields.rotation_axis_angle === nothing
        @test tf.fields.quaternion === nothing
        @test tf.fields.mat3x3 === nothing
        # Float64 input was converted to Float32 (this mapping COPIES, never reinterprets).
        @test eltype(tf.fields.translation[1].vector) === Float32
    end

    @testset "LinearMap{<:Rotation} -> quaternion (PINS w-order gotcha)" begin
        # A 90 degree rotation about +Z. Its unit quaternion (scalar-first, as
        # Rotations.params returns) is (w, x, y, z) = (cos45, 0, 0, sin45).
        # RerunRotationsExt maps a non-RotMatrix/non-AngleAxis rotation to a
        # quaternion; this extension delegates to it. The scalar-last reorder is
        # the load-bearing gotcha and is pinned below.
        rot = RotZ(pi / 2)
        lm = LinearMap(rot)
        tf = Transform3D(lm)
        @test tf isa Transform3D
        @test tf.fields.translation === nothing      # LinearMap is rotation-only
        @test tf.fields.quaternion isa AbstractVector{RotationQuat}
        @test tf.fields.mat3x3 === nothing            # rotation delegated -> quaternion

        q_rerun = tf.fields.quaternion[1].quaternion  # NTuple{4,Float32} == (x, y, z, w)

        # Ground-truth scalar-first params straight from Rotations.
        wxyz = Rotations.params(QuatRotation(rot))    # (w, x, y, z)
        c = Float32(cos(pi / 4))
        s = Float32(sin(pi / 4))

        # GOTCHA: Rerun stores (x, y, z, w) — scalar (w) LAST. If the reorder were
        # skipped, q_rerun[1] would be ~0.707 (the scalar) and q_rerun[4] ~0.
        @test q_rerun[1] ≈ Float32(wxyz[2]) atol=1e-6   # x
        @test q_rerun[2] ≈ Float32(wxyz[3]) atol=1e-6   # y
        @test q_rerun[3] ≈ Float32(wxyz[4]) atol=1e-6   # z
        @test q_rerun[4] ≈ Float32(wxyz[1]) atol=1e-6   # w  (scalar LAST)

        # Concrete numeric pin for RotZ(90deg): xyzw = (0, 0, sin45, cos45).
        @test q_rerun[1] ≈ 0f0 atol=1e-6
        @test q_rerun[2] ≈ 0f0 atol=1e-6
        @test q_rerun[3] ≈ s atol=1e-6
        @test q_rerun[4] ≈ c atol=1e-6
        # Scalar component is NOT in the first slot (would be if mis-ordered w,x,y,z).
        @test !isapprox(q_rerun[1], c; atol=1e-6)
    end

    @testset "LinearMap{plain matrix} -> mat3x3 fallback (column-major flat_columns)" begin
        # A plain (non-Rotations) linear part falls back to TransformMat3x3.
        # Math matrix:
        #   [1 4 7]
        #   [2 5 8]
        #   [3 6 9]
        # Rerun flat_columns (column-major) must be (1,2,3, 4,5,6, 7,8,9).
        M = @SMatrix Float64[1 4 7; 2 5 8; 3 6 9]
        lm = LinearMap(M)
        tf = Transform3D(lm)
        @test tf.fields.mat3x3 isa AbstractVector{TransformMat3x3}
        @test tf.fields.quaternion === nothing       # plain matrix -> mat3x3, not quaternion
        @test tf.fields.translation === nothing
        @test tf.fields.mat3x3[1].matrix == (1f0, 2f0, 3f0, 4f0, 5f0, 6f0, 7f0, 8f0, 9f0)
    end

    @testset "AffineMap -> translation + quaternion (Rotation linear part)" begin
        rot = RotZ(pi / 2)
        am = AffineMap(rot, SVector(10.0, 20.0, 30.0))
        tf = Transform3D(am)
        @test tf.fields.translation[1].vector === (10f0, 20f0, 30f0)
        @test tf.fields.quaternion isa AbstractVector{RotationQuat}
        @test tf.fields.mat3x3 === nothing
        q = tf.fields.quaternion[1].quaternion
        @test q[4] ≈ Float32(cos(pi / 4)) atol=1e-6   # w last
        @test q[3] ≈ Float32(sin(pi / 4)) atol=1e-6   # z
    end

    @testset "AffineMap -> translation + mat3x3 (plain matrix linear part)" begin
        M = @SMatrix Float64[1 4 7; 2 5 8; 3 6 9]
        am = AffineMap(M, SVector(-1.0, -2.0, -3.0))
        tf = Transform3D(am)
        @test tf.fields.translation[1].vector === (-1f0, -2f0, -3f0)
        @test tf.fields.mat3x3[1].matrix == (1f0, 2f0, 3f0, 4f0, 5f0, 6f0, 7f0, 8f0, 9f0)
        @test tf.fields.quaternion === nothing
    end

    @testset "Rerun.log sugar end-to-end (writes a .rrd)" begin
        rec = RecordingStream("rerun_jl_coordtransforms")
        out = tempname() * ".rrd"
        Rerun.save(rec, out)
        Rerun.set_time(rec, "frame", 0)

        Rerun.log(rec, "world/translate", Translation(1.0, 2.0, 3.0))
        Rerun.log(rec, "world/rotate", LinearMap(RotZ(pi / 4)))
        Rerun.log(rec, "world/affine",
                  AffineMap(RotY(0.3), SVector(0.0, 1.0, 2.0)))
        Rerun.log(rec, "world/linmat", LinearMap(@SMatrix Float64[1 0 0; 0 1 0; 0 0 1]))

        flush(rec)
        @test isfile(out) && filesize(out) > 0
    end
end
