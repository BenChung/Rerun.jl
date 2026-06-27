using Rerun
import Tables
using Test

# Log two entities on alternating steps so the queried-back columns are sparse
# (each entity is NULL on the steps where the other was sampled).
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

    @testset "timestamp index timeline decodes (temporal -> Int64)" begin
        rect = RecordingStream("rrq_ts_test")
        outt = tempname() * ".rrd"
        Rerun.save(rect, outt)
        t = collect(0:9)
        t0 = 1_700_000_000_000_000_000
        Rerun.send_columns(rect, "m/x",
            [Rerun.TimeColumn("time", t0 .+ t .* 1_000_000; kind=:timestamp)],
            ["rerun.components.Scalar" => Float64.(t)])
        flush(rect)
        sleep(0.2)
        timecol = Tables.getcolumn(Tables.columns(Rerun.select(Rerun.view(Rerun.load_recording(outt); index="time"))), :time)
        @test eltype(timecol) == Int64
        @test length(timecol) == 10
    end
end
