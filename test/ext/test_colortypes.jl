# Exercises the RerunColorTypesExt package extension. Runs in an env that has
# ColorTypes as a (test) dependency, which triggers the extension to load.

using Rerun
using Rerun.Components: Color
using ColorTypes
using ColorTypes.FixedPointNumbers: N0f8
using Test

@testset "RerunColorTypesExt" begin
    @test Base.get_extension(Rerun, :RerunColorTypesExt) !== nothing

    @testset "byte order is pinned (THE gotcha)" begin
        # Rerun Color packs 0xRRGGBBAA: red in the most-significant byte, alpha
        # in the least.
        @test Color(RGBA{N0f8}(1, 0, 0, 1)).rgba === 0xff0000ff   # pure red, opaque
        @test Color(RGBA{N0f8}(0, 1, 0, 1)).rgba === 0x00ff00ff   # pure green
        @test Color(RGBA{N0f8}(0, 0, 1, 1)).rgba === 0x0000ffff   # pure blue
        @test Color(RGBA{N0f8}(0, 0, 0, 0)).rgba === 0x00000000   # fully transparent black
    end

    @testset "channel positions are semantic, not field order" begin
        # red()/green()/blue()/alpha() return channels by semantics regardless
        # of storage order (ARGB is alpha-first, BGRA blue-first), so all pack
        # to 0xRRGGBBAA.
        @test Color(ARGB{N0f8}(1, 0, 0, 1)).rgba === 0xff0000ff   # red, despite A-first storage
        @test Color(BGRA{N0f8}(0, 0, 1, 1)).rgba === 0x0000ffff   # blue, despite B-first storage
        # Half alpha (N0f8 0.5 -> raw byte 0x80) lands in the LSB.
        @test Color(ARGB{N0f8}(1, 0, 0, 0.5)).rgba === 0xff000080
    end

    @testset "alpha-less colorants get 0xff" begin
        @test Color(RGB{N0f8}(1, 0, 0)).rgba === 0xff0000ff
        @test Color(BGR{N0f8}(0, 0, 1)).rgba === 0x0000ffff   # BGR red/green/blue still semantic
    end

    @testset "gray maps to r=g=b=value" begin
        @test Color(Gray{N0f8}(1.0)).rgba === 0xffffffff
        @test Color(Gray{N0f8}(0.0)).rgba === 0x000000ff
        # GrayA carries a real alpha; value replicated across r,g,b.
        @test Color(GrayA{N0f8}(1.0, 0.5)).rgba === 0xffffff80
    end

    @testset "float eltype scales by 255 and rounds" begin
        @test Color(RGB{Float32}(1f0, 0f0, 0f0)).rgba === 0xff0000ff
        @test Color(RGBA{Float64}(0.0, 1.0, 0.0, 1.0)).rgba === 0x00ff00ff
        # round-to-nearest: 0.5 * 255 = 127.5 -> 128 = 0x80
        @test Color(Gray{Float64}(0.5)).rgba === 0x808080ff
    end

    @testset "batch log path (copies into Vector{Color})" begin
        ext = Base.get_extension(Rerun, :RerunColorTypesExt)
        @test ext !== nothing

        # Colorants always copy into a fresh Vector{Color}: the channel reorder
        # and scaling rule out a zero-copy reinterpret.
        cs = [RGBA{N0f8}(1, 0, 0, 1), RGBA{N0f8}(0, 1, 0, 1), RGBA{N0f8}(0, 0, 1, 1)]
        converted = Color[Color(c) for c in cs]
        @test converted == Color[Color(0xff0000ff), Color(0x00ff00ff), Color(0x0000ffff)]
        @test eltype(converted) === Color

        rec = RecordingStream("rerun_jl_colortypes")
        out = tempname() * ".rrd"
        Rerun.save(rec, out)
        Rerun.set_time(rec, "frame", 0)

        # Bare Vector{<:Colorant} -> logs as Color batch.
        Rerun.log(rec, "colors", cs)
        Rerun.log(rec, "rgb", [RGB{Float32}(0.5f0, 0.25f0, 0f0)])
        Rerun.log(rec, "gray", [Gray{N0f8}(0.5), Gray{N0f8}(1.0)])

        flush(rec)
        @test isfile(out) && filesize(out) > 0
    end
end
