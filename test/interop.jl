# BYO-type interop: the component/wire_compatible traits, materialization, and
# the InteropError messages (the messages are API surface — the docs quote them).

using Rerun
using Rerun.Components, Rerun.Archetypes
using Test

# Declarations must sit at top level.
struct WirePoint; x::Float32; y::Float32; z::Float32; end
Rerun.wire_compatible(::Type{WirePoint}, ::Type{Position3D}) = true

struct Waypoint; lat::Float64; lon::Float64; alt::Float64; end
Rerun.component(::Type{Waypoint}) = Position3D
Rerun.Components.Position3D(w::Waypoint) = Position3D((w.lon, w.lat, w.alt))

struct Unmapped; a::Int; end

struct WrongSize; a::Float64; b::Float64; end
Rerun.wire_compatible(::Type{WrongSize}, ::Type{Position3D}) = true

@testset "interop traits + materialization" begin
    @testset "resolution order" begin
        pts = [Position3D((1f0, 2f0, 3f0))]
        @test Rerun._materialize(Position3D, pts) === pts               # component eltype

        wire = NTuple{3,Float32}[(1, 2, 3)]
        @test Rerun._materialize(Position3D, wire) === wire             # storage type

        wps = [WirePoint(1, 2, 3), WirePoint(4, 5, 6)]
        @test Rerun._materialize(Position3D, wps) === wps               # declared wire-compatible

        route = [Waypoint(48.86, 2.35, 35.0)]
        batch = Rerun._materialize(Position3D, route)                   # constructor copy
        @test batch isa Vector{Position3D}
        @test batch[1].xyz === (2.35f0, 48.86f0, 35f0)                  # lon/lat reordered

        withmissing = [Waypoint(1.0, 2.0, 3.0), missing]
        mbatch = Rerun._materialize(Position3D, withmissing)
        @test mbatch[2] === missing && mbatch[1] isa Position3D
    end

    @testset "trait-driven logging end to end" begin
        rec = RecordingStream("rerun_jl_interop")
        out = tempname() * ".rrd"
        Rerun.save(rec, out)
        Rerun.set_time(rec, "frame", 0)

        route = [Waypoint(48.86, 2.35, 35.0), Waypoint(48.85, 2.29, 32.0)]
        Rerun.log(rec, "bare", route)                                   # component trait
        Rerun.log(rec, "explicit", Position3D, route)                   # explicit component
        Rerun.log(rec, "wire", Position3D, [WirePoint(0, 0, 0)])        # zero-copy declaration
        Rerun.log(rec, "arch", Points3D(route; radii = [0.5, 1.0]))     # archetype fields convert
        Rerun.send_columns(rec, "cols",
            (Timeline("frame") => Int64[0, 1],),
            (Position3D => route,))                                     # columns convert
        Rerun.log(rec, "radii", "rerun.components.Radius", Float64[1.0, 2.0])  # catalog form converts too

        flush(rec)
        @test isfile(out) && filesize(out) > 0
    end

    @testset "error messages name the missing declaration" begin
        rec = RecordingStream("rerun_jl_interop_err")

        err = try; Rerun.log(rec, "x", [Unmapped(1)]); catch e; e; end
        @test err isa Rerun.InteropError
        @test occursin("no component mapping for", sprint(showerror, err))
        @test occursin("Rerun.component(::Type{", sprint(showerror, err))

        err = try; Rerun.log(rec, "x", Position3D, [Unmapped(1)]); catch e; e; end
        @test err isa Rerun.InteropError
        @test occursin("converting element 1", sprint(showerror, err))
        @test occursin("Rerun.Components.Position3D(x::", sprint(showerror, err))
        @test occursin("wire_compatible", sprint(showerror, err))

        err = try; Rerun.log(rec, "x", Position3D, [WrongSize(1, 2)]); catch e; e; end
        @test err isa Rerun.InteropError
        @test occursin("sizeof(", sprint(showerror, err))
        @test occursin("16 bytes", sprint(showerror, err))
        @test occursin("12 bytes", sprint(showerror, err))

        err = try; Rerun.log(rec, "x", Position3D, [Color(0xff0000ff)]); catch e; e; end
        @test err isa Rerun.InteropError
        @test occursin("different component", sprint(showerror, err))
    end
end
