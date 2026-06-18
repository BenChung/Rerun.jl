# Exercises the RerunQuaternionsExt package extension. Runs in an env that has
# Quaternions as a (test) dependency, which triggers the extension to load.

using Rerun
using Rerun.Components: RotationQuat
using Quaternions
using Test

@testset "RerunQuaternionsExt" begin
    # The extension must actually be loaded (Quaternions + Rerun both present).
    @test Base.get_extension(Rerun, :RerunQuaternionsExt) !== nothing

    @testset "scalar constructor reorders w-first -> xyzw (THE gotcha)" begin
        # Quaternions.Quaternion(s, v1, v2, v3) is SCALAR-FIRST:
        #   s  = real/scalar part = w
        #   v1 = x, v2 = y, v3 = z
        # Rerun RotationQuat stores [x, y, z, w] (scalar LAST). Pin the reorder
        # with distinct coefficients so a missed permutation can't pass.
        q = Quaternion(10.0, 1.0, 2.0, 3.0)   # (s=10=w, x=1, y=2, z=3)
        @test real(q) == 10.0                  # confirm scalar-first orientation
        rq = RotationQuat(q)
        @test rq isa RotationQuat
        # xyzw: x=1, y=2, z=3, w=10  (NOT (10,1,2,3))
        @test rq.quaternion === (1f0, 2f0, 3f0, 10f0)
        @test eltype(rq.quaternion) === Float32     # converted to Float32
    end

    @testset "scalar constructor matches manual reorder for random quats" begin
        for _ in 1:8
            s, v1, v2, v3 = randn(4)
            q = Quaternion(s, v1, v2, v3)
            rq = RotationQuat(q)
            @test rq.quaternion ===
                (Float32(v1), Float32(v2), Float32(v3), Float32(s))
        end
    end

    @testset "batch helper always copies (no reinterpret view)" begin
        ext = Base.get_extension(Rerun, :RerunQuaternionsExt)
        qs = [Quaternion(Float64(i), i + 0.1, i + 0.2, i + 0.3) for i in 1:4]
        batch = ext._as_rotation_batch(qs)
        @test eltype(batch) === RotationQuat
        # Reorder makes a reinterpret illegal for every eltype -> always a copy,
        # never a shared-memory view.
        @test !(batch isa Base.ReinterpretArray)
        # Element-wise reorder preserved through the batch.
        @test batch[2].quaternion ===
            (Float32(2.1), Float32(2.2), Float32(2.3), 2f0)
    end

    @testset "bare-vector log sugar maps to RotationQuat" begin
        rec = RecordingStream("rerun_jl_quaternions")
        out = tempname() * ".rrd"
        Rerun.save(rec, out)
        Rerun.set_time(rec, "frame", 0)

        qs = [Quaternion(Float64(i), 0.0, 0.0, 1.0) for i in 1:5]
        Rerun.log(rec, "rot", qs)

        # Build a Transform3D rotation by converting explicitly.
        Rerun.log(rec, "tf", Rerun.Archetypes.Transform3D(
            quaternion = [RotationQuat(Quaternion(1.0, 0.0, 0.0, 0.0))]))

        flush(rec)
        @test isfile(out) && filesize(out) > 0
    end
end
