using Rerun
using Dates
import Tables
using Test

# Alternating steps make each entity's column sparse -- NULL wherever the other was sampled.
function _sparse_recording()
    rec = RecordingStream("rrq_query_test")
    out = tempname() * ".rrd"
    Rerun.save(rec, out)
    ea = collect(0:2:98)
    eb = collect(1:2:99)
    Rerun.send_columns(rec, "m/a", ["step" => ea], ["rerun.components.Scalar" => Float64.(ea)])
    Rerun.send_columns(rec, "m/b", ["step" => eb], ["rerun.components.Scalar" => Float64.(eb)])
    flush(rec)
    sleep(0.2)
    out
end

_colnamed(cols, needle) = begin
    nm = Tables.columnnames(cols)
    nm[findfirst(n -> occursin(needle, String(n)), nm)]
end

@testset "dataframe query (read data out)" begin
    out = _sparse_recording()
    @test isfile(out) && filesize(out) > 0
    rec = Rerun.load_recording(out)

    @testset "zero-copy index + sparse missing slots" begin
        cols = Tables.columns(Rerun.select(Rerun.view(rec; index="step")))
        step = Tables.getcolumn(cols, :step)
        @test step isa Rerun.ArrowColumn{Int64}          # primitive index aliases the buffer
        @test sort(collect(step)) == collect(0:99)

        a = Tables.getcolumn(cols, _colnamed(cols, "m/a"))
        @test eltype(a) == Union{Missing,Vector{Float64}} # nullable list, not silently empty
        bystep = Dict(step[i] => a[i] for i in eachindex(step))
        @test bystep[0] == [0.0]
        @test bystep[2] == [2.0]
        @test bystep[1] === missing                       # NULL slot -> missing, not []
        @test bystep[99] === missing
    end

    @testset "empty result preserves schema" begin
        qr = Rerun.select(Rerun.filter_range(Rerun.view(rec; index="step"), 1000, 2000))
        sch = Tables.schema(qr)
        @test sch !== nothing
        @test :step in sch.names
        @test length(Tables.getcolumn(Tables.columns(qr), :step)) == 0
    end

    @testset "Timeline as query index" begin
        cols = Tables.columns(Rerun.select(Rerun.view(rec; index=Timeline("step"))))
        @test Tables.getcolumn(cols, :step) isa Rerun.ArrowColumn{Int64}
    end

    @testset "fill_latest_at + contents restriction" begin
        v = Rerun.fill_latest_at(Rerun.view(rec; index="step"))
        cols = Tables.columns(Rerun.select(v))
        step = Tables.getcolumn(cols, :step)
        a = Tables.getcolumn(cols, _colnamed(cols, "m/a"))
        bystep = Dict(step[i] => a[i] for i in eachindex(step))
        @test bystep[1] == [0.0]                       # odd step forward-filled from step 0
        @test bystep[99] == [98.0]

        vc = Rerun.view(rec; index="step", contents=["m/a"])
        names_c = Tables.columnnames(Tables.columns(Rerun.select(vc)))
        @test any(n -> occursin("m/a", String(n)), names_c)
        @test !any(n -> occursin("m/b", String(n)), names_c)
    end

    @testset "getcolumn unknown name throws KeyError" begin
        cols = Tables.columns(Rerun.select(Rerun.view(rec; index="step")))
        @test_throws KeyError Tables.getcolumn(cols, :does_not_exist)
    end

    @testset "recording pretty-printing" begin
        s = sprint(show, MIME("text/plain"), rec)
        @test occursin("Rerun.Recording", s)
        @test occursin("entities", s) && occursin("timelines", s)
        @test occursin(out, s)                          # the .rrd path is shown
        @test occursin("Recording(", sprint(show, rec)) # compact form
    end

    @testset "archetype-tagged columns keep their descriptor" begin
        rect = RecordingStream("rrq_tagged_test")
        outt = tempname() * ".rrd"
        Rerun.save(rect, outt)
        steps = collect(0:9)
        Rerun.send_columns(rect, "m/sin", ["step" => steps],
            Rerun.columns(Rerun.Archetypes.Scalars; scalars=Float64.(steps)))
        flush(rect)
        sleep(0.2)

        rec2 = Rerun.load_recording(outt)
        cols = Tables.columns(Rerun.select(Rerun.view(rec2; index="step")))
        nm = _colnamed(cols, "Scalars:scalars")     # archetype-qualified descriptor survives
        vals = Tables.getcolumn(cols, nm)
        @test [only(v) for v in vals] == Float64.(steps)
    end

    @testset "timestamp timeline: introspection + ns-exact roundtrip" begin
        rect = RecordingStream("rrq_ts_test")
        outt = tempname() * ".rrd"
        Rerun.save(rect, outt)
        tstamp = Timeline("time", :timestamp)
        tdur = Timeline("lag", :duration)
        ns = 1_700_000_000_000_000_000 .+ (0:9) .* 1_000_000 .+ 123    # deliberately not ms-aligned
        # TimePoint vector is aliased via reinterpret, not copied.
        Rerun.send_columns(rect, "m/x",
            [Rerun.TimeColumn(tstamp, TimePoint.(ns)), Rerun.TimeColumn(tdur, (0:9) .* 1_000)],
            ["rerun.components.Scalar" => Float64.(0:9)])
        flush(rect)
        sleep(0.2)

        rec2 = Rerun.load_recording(outt)
        tls = Rerun.timelines(rec2)                                    # concrete Timeline{T}s from the file
        @test Timeline{TimePoint}("time") in tls
        @test Timeline{Nanosecond}("lag") in tls
        tl = Rerun.timeline(rec2, "time")                              # the type-dynamic boundary
        @test tl isa Timeline{TimePoint}
        @test_throws RerunError Rerun.timeline(rec2, "nope")
        @test_throws RerunError Rerun.view(rec2; index=Timeline("time"))  # sequence vs timestamp kind check

        cols = Tables.columns(Rerun.select(Rerun.view(rec2; index=tl)))
        timecol = Tables.getcolumn(cols, :time)
        @test timecol isa Rerun.ArrowColumn{TimePoint}                 # typed AND zero-copy
        @test [t.ns for t in timecol] == collect(ns)                   # bit-exact roundtrip
        @test_throws InexactError DateTime(timecol[1])                 # sub-ms precision preserved
        @test round(DateTime, timecol[1]) == DateTime(2023, 11, 14, 22, 13, 20)
        lagcol = Tables.getcolumn(Tables.columns(Rerun.select(
            Rerun.view(rec2; index=Rerun.timeline(rec2, "lag")))), :lag)
        @test eltype(lagcol) == Nanosecond

        # typed filter_range through the resolved timeline
        v = Rerun.filter_range(Rerun.view(rec2; index=tl), TimePoint(ns[3]), TimePoint(ns[5]))
        @test length(Tables.getcolumn(Tables.columns(Rerun.select(v)), :time)) == 3
    end
end
