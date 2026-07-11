# Exercises the RerunRotationsExt package extension.

using Rerun
using Rerun.Components: RotationQuat, TransformMat3x3
using Rerun.Archetypes: Transform3D
using Rotations
using Test

@testset "RerunRotationsExt" begin
    @test Base.get_extension(Rerun, :RerunRotationsExt) !== nothing
    ext = Base.get_extension(Rerun, :RerunRotationsExt)

    @testset "QuatRotation -> RotationQuat (scalar-last w-order: THE gotcha)" begin
        # A known, non-symmetric quaternion. Rotations/Quaternions store it scalar-first
        # as (w, x, y, z); Rerun RotationQuat is scalar-last (x, y, z, w). Distinct
        # components catch a wrong permutation.
        q = QuatRotation(0.1, 0.2, 0.3, 0.4)   # constructor is (w, x, y, z), normalized
        p = Rotations.params(q)                # SVector(w, x, y, z)
        rq = RotationQuat(q)
        @test rq isa RotationQuat
        # Pin the reorder: Rerun slot order is (x, y, z, w) == params (2,3,4,1).
        @test rq.quaternion == (Float32(p[2]), Float32(p[3]), Float32(p[4]), Float32(p[1]))
        # The scalar (w) lands in the last slot, not the first.
        @test rq.quaternion[4] == Float32(p[1])          # w last
        @test rq.quaternion[1] == Float32(p[2])          # x first
        @test rq.quaternion[1] != rq.quaternion[4]       # would coincide if mis-ordered as [w,x,y,z]
    end

    @testset "AngleAxis -> rotation_axis_angle NamedTuple (unit axis + radians)" begin
        aa = AngleAxis(0.7, 0.0, 0.0, 1.0)     # 0.7 rad about +z; axis auto-normalized
        nt = ext._rotation_axis_angle(aa)
        @test nt.axis isa NTuple{3,Float32}
        @test nt.angle isa Float32
        @test nt.angle == Float32(rotation_angle(aa)) == 0.7f0
        ax = rotation_axis(aa)
        @test nt.axis == (Float32(ax[1]), Float32(ax[2]), Float32(ax[3]))
        @test nt.axis == (0f0, 0f0, 1f0)       # unit axis along +z
        # The NamedTuple field names must match the Rerun RotationAxisAngle Arrow struct
        # (axis, angle) so the assembled export path's getfield works.
        @test propertynames(nt) == (:axis, :angle)
    end

    @testset "RotMatrix{3} -> TransformMat3x3 (column-major flat_columns, no transpose)" begin
        # Asymmetric rotation: 90° about +z.  Math matrix is
        #   [0 -1 0]
        #   [1  0 0]
        #   [0  0 1]
        # Column-major flat_columns must be (0,1,0, -1,0,0, 0,0,1). A stray
        # transpose would instead give (0,-1,0, 1,0,0, 0,0,1) and fail here.
        r = RotMatrix(RotZ(Float32(pi / 2)))
        m = r.mat
        @test m[1, 1] ≈ 0 atol = 1e-6
        @test m[2, 1] ≈ 1 atol = 1e-6          # (row=2,col=1) -> flat index col*3+row = 1
        @test m[1, 2] ≈ -1 atol = 1e-6         # (row=1,col=2) -> flat index 3
        tm = TransformMat3x3(r)
        @test tm isa TransformMat3x3
        @test tm.matrix == map(Float32, Tuple(m))               # exactly column-major data
        @test tm.matrix[2] ≈ 1f0 atol = 1e-6                    # sin term in col 0
        @test tm.matrix[4] ≈ -1f0 atol = 1e-6                   # -sin term in col 1
    end

    @testset "general Rotation{3} -> RotationQuat via QuatRotation" begin
        # A representation that is neither QuatRotation, AngleAxis nor RotMatrix.
        r = RotXYZ(0.1, 0.2, 0.3)
        rq = RotationQuat(r)
        @test rq isa RotationQuat
        # Must agree with converting to a quaternion explicitly, scalar-last.
        q = QuatRotation(r)
        @test rq.quaternion == RotationQuat(q).quaternion
    end

    @testset "Transform3D(::Rotation) picks the faithful field" begin
        # AngleAxis -> rotation_axis_angle
        ta = Transform3D(AngleAxis(0.5, 1.0, 0.0, 0.0))
        @test ta.fields.rotation_axis_angle !== nothing
        @test ta.fields.quaternion === nothing
        @test ta.fields.mat3x3 === nothing

        # RotMatrix{3} -> mat3x3
        tm = Transform3D(RotMatrix(RotZ(0.3)))
        @test tm.fields.mat3x3 !== nothing
        @test tm.fields.rotation_axis_angle === nothing

        # Any other rotation (incl. QuatRotation) -> quaternion
        tq = Transform3D(QuatRotation(0.1, 0.2, 0.3, 0.4))
        @test tq.fields.quaternion !== nothing
        @test tq.fields.mat3x3 === nothing

        # Extra kwargs compose (translation forwarded).
        tt = Transform3D(QuatRotation(0.1, 0.2, 0.3, 0.4); translation = [(1f0, 2f0, 3f0)])
        @test tt.fields.translation !== nothing
        @test tt.fields.quaternion !== nothing
    end

    @testset "end-to-end log to .rrd" begin
        rec = RecordingStream("rerun_jl_rotations")
        out = tempname() * ".rrd"
        Rerun.save(rec, out)
        Rerun.set_time(rec, "frame", 0)

        # Each rotation flavour through the Transform3D archetype path (exercises
        # the assembled struct export for RotationAxisAngle too).
        Rerun.log(rec, "aa",   Transform3D(AngleAxis(0.5, 0.0, 0.0, 1.0)))
        Rerun.log(rec, "mat",  Transform3D(RotMatrix(RotZ(0.3))))
        Rerun.log(rec, "quat", Transform3D(QuatRotation(0.1, 0.2, 0.3, 0.4)))
        Rerun.log(rec, "xyz",  Transform3D(RotXYZ(0.1, 0.2, 0.3)))

        flush(rec)
        @test isfile(out) && filesize(out) > 0
    end
end
