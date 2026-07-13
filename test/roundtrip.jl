using Rerun
using Rerun.Components, Rerun.Archetypes
import Rerun.Components: Text, Blob       # Text clashes with Base.Text
using Dates
using Test

const POS = NTuple{3,Float32}[(0,0,0), (1,2,3), (4,5,6)]
const COL = UInt32[0xff0000ff, 0x00ff00ff, 0x0000ffff]
const RAD = Float32[0.1, 0.2, 0.3]

# BYO interop: a foreign 12-byte isbits point type, declared wire-compatible.
struct _P3; x::Float32; y::Float32; z::Float32; end
Rerun.wire_compatible(::Type{_P3}, ::Type{Position3D}) = true

@testset "single-component zero-copy round-trip" begin
    rec = RecordingStream("rerun_jl_test"; recording_id="rt")
    @test Rerun.is_enabled(rec)
    out = tempname() * ".rrd"
    Rerun.save(rec, out)
    Rerun.set_time(rec, "frame", 0; kind=:sequence)
    Rerun.log(rec, "world/points", "rerun.components.Position3D", POS)
    Rerun.log(rec, "world/points", "rerun.components.Color",      COL)
    Rerun.log(rec, "world/points", "rerun.components.Radius",     RAD)
    flush(rec)
    @test isfile(out) && filesize(out) > 0
end

@testset "multi-component row + archetype log" begin
    rec = RecordingStream("rerun_jl_multi")
    out = tempname() * ".rrd"
    Rerun.save(rec, out)
    Rerun.set_time(rec, "frame", 1)
    # explicit multi-component row
    Rerun.log(rec, "world/a",
        "rerun.components.Position3D" => POS,
        "rerun.components.Color"      => COL,
        "rerun.components.Radius"     => RAD)
    # archetype-driven (component types resolved from the catalog)
    Rerun.log_archetype(rec, "world/b", "rerun.archetypes.Points3D";
        positions=POS, colors=COL, radii=RAD)
    flush(rec)
    @test isfile(out) && filesize(out) > 0
    # archetype field validation
    @test_throws ErrorException Rerun.log_archetype(rec, "world/b",
        "rerun.archetypes.Points3D"; not_a_field=POS)
    @test_throws ErrorException Rerun.log_archetype(rec, "world/b", "rerun.archetypes.Nope"; positions=POS)
end

@testset "typed components + archetypes (materialized structs)" begin
    rec = RecordingStream("rerun_jl_typed")
    out = tempname() * ".rrd"
    Rerun.save(rec, out)
    Rerun.set_time(rec, "frame", 0)
    pts  = [Position3D((Float32(i), 0f0, 0f0)) for i in 1:4]
    cols = [Color(0xff0000ff) for _ in 1:4]
    rads = [Radius(0.2f0) for _ in 1:4]
    @test sizeof(Position3D) == 12 && sizeof(Color) == 4   # exact wire layout

    Rerun.log(rec, "a", pts)                       # single typed batch
    Rerun.log(rec, "b", pts, cols, rads)           # multi-component row (varargs)
    Rerun.log(rec, "c", Points3D(pts; colors=cols, radii=rads))  # archetype instance

    # interop: the declared wire-compatible vector logs zero-copy, no wrapping
    Rerun.log(rec, "d", Position3D, [_P3(Float32(i), 0f0, 0f0) for i in 1:4])

    # enum-backed components: per-type variant namespace + wire layout
    @test Colormap.Inferno.value == 2 && sizeof(Colormap) == 1 && sizeof(VideoCodec) == 4
    @test :Inferno in propertynames(Colormap)
    Rerun.log(rec, "e", [Colormap.Inferno, Colormap.Turbo])

    flush(rec)
    @test isfile(out) && filesize(out) > 0

    # the typed component hot path allocates nothing once warmed (pool reused)
    Rerun.log(rec, "a", pts); flush(rec)
    @test (@allocated Rerun.log(rec, "a", pts)) <= 64

    # multi-component (fixed-arity) is also 0-alloc — no varargs heap tuple
    Rerun.log(rec, "b", pts, cols, rads); flush(rec)
    @test (@allocated Rerun.log(rec, "b", pts, cols, rads)) <= 64

    # logging a prebuilt archetype is also 0-alloc (generated, type-stable fold)
    arch = Points3D(pts; colors=cols, radii=rads)
    Rerun.log(rec, "c", arch); flush(rec)
    @test (@allocated Rerun.log(rec, "c", arch)) <= 64
end

@testset "assembled exporter (utf8 / list / bool / struct)" begin
    rec = RecordingStream("rerun_jl_assembled")
    out = tempname() * ".rrd"
    Rerun.save(rec, out)
    Rerun.set_time(rec, "frame", 0)
    Rerun.log(rec, "labels", "rerun.components.Text", ["hello", "world", ""])      # utf8
    Rerun.log(rec, "blob",   "rerun.components.Blob", [UInt8[1,2,3], UInt8[], UInt8[9]])  # list<u8>
    Rerun.log(rec, "flag",   "rerun.components.ShowLabels", [true, false, true])   # bool (bit-packed)
    Rerun.log(rec, "edges",  "rerun.components.GraphEdge",                          # struct{utf8,utf8}
        [(first="a", second="b"), (first="c", second="d")])
    Rerun.log(rec, "dim",    "rerun.components.TensorWidthDimension",               # struct{u32,bool}
        [(dimension=UInt32(640), invert=false)])
    Rerun.log(rec, "rot",    "rerun.components.RotationAxisAngle",                   # struct{FixedList<3,f32>, f32}
        [(axis=(0f0,0f0,1f0), angle=0.5f0), (axis=(1f0,0f0,0f0), angle=1.5f0)])
    flush(rec)
    @test isfile(out) && filesize(out) > 0

    # assembled fixed-size-list child (the RotationAxisAngle `axis` field): [validity]
    # + 1 child of n*3 f32 (no offsets).
    aa = Rerun.component_arrow_type("rerun.components.RotationAxisAngle")
    @test any(f -> f.type isa Rerun.ArrowFixedList && f.type.n == 3, aa.fields)

    # assembled buffers are freed by the owned release on rerun's bg thread
    for i in 1:200
        Rerun.log(rec, "labels", "rerun.components.Text", ["s$(i)_$(j)" for j in 1:10])
        i % 40 == 0 && GC.gc()
    end
    flush(rec); GC.gc(); flush(rec)
    @test true   # no crash / no leak-blowup under stress
end

@testset "send_columns (columnar / temporal)" begin
    rec = RecordingStream("rerun_jl_cols")
    out = tempname() * ".rrd"
    Rerun.save(rec, out)
    pts = [Position3D((Float32(i), 0f0, 0f0)) for i in 1:50]
    # mono (1/row, zero-copy), multi (variable/row), string-API scalar, multi-column
    Rerun.send_columns(rec, "traj", ["frame" => 0:49], [Position3D => pts])
    Rerun.send_columns(rec, "clouds", ["frame" => 0:9],
        [Position3D => [[Position3D((Float32(j),0f0,0f0)) for j in 1:i] for i in 1:10]])
    Rerun.send_columns(rec, "metric",
        [Rerun.TimeColumn("t", (0:9) .* 1_000_000; kind=:timestamp)],
        ["rerun.components.Scalar" => Float64.(1:10)])
    Rerun.send_columns(rec, "pc", ["frame" => 0:49],
        [Position3D => pts, Color => [Color(0xff00ffff) for _ in 1:50]])
    # typed carrier columns (Text/Blob) must work like `log`
    Rerun.send_columns(rec, "names", ["frame" => 0:2],
        [Text => [Text("a"), Text("bb"), Text("ccc")]])                 # mono carrier
    Rerun.send_columns(rec, "tags", ["frame" => 0:1],
        [Text => [[Text("x"), Text("y")], [Text("z")]]])                # multi carrier (batch/row)
    Rerun.send_columns(rec, "blobs", ["frame" => 0:1],
        [Blob => [Blob(UInt8[1,2,3]), Blob(UInt8[4,5])]])               # mono Blob carrier
    # tuple form: concretely-typed pairs, statically resolved columns
    Rerun.send_columns(rec, "traj_t", (Timeline("frame") => 0:49,), (Position3D => pts,))
    Rerun.send_columns(rec, "pc_t", ("frame" => 0:49,),
        (Position3D => pts, Color => [Color(0xff00ffff) for _ in 1:50]))
    flush(rec)
    @test isfile(out) && filesize(out) > 0

    for k in 1:150
        Rerun.send_columns(rec, "traj", ["frame" => (k*100):(k*100+49)], [Position3D => pts])
        k % 40 == 0 && GC.gc()
    end
    flush(rec); GC.gc(); flush(rec)
    @test true
end

@testset "Timeline (typed index timelines)" begin
    @test_throws ErrorException Timeline("t"; kind=:nope)
    tl = Timeline("stamp", :timestamp)
    @test tl isa Timeline{TimePoint}
    @test tl.name == "stamp" && Rerun.kind(tl) == :timestamp
    @test Timeline("frame") isa Timeline{Int64}
    @test eltype(Timeline("lag", :duration)) == Nanosecond

    rec = RecordingStream("rerun_jl_timeline")
    out = tempname() * ".rrd"
    Rerun.save(rec, out)
    Rerun.set_time(rec, tl, 1_700_000_000_000_000_000)          # raw ns
    Rerun.set_time(rec, tl, DateTime(2026, 7, 10))              # exact DateTime conversion
    Rerun.set_time(rec, Timeline("lag", :duration), Second(5))  # exact Period conversion
    @test_throws ErrorException Rerun.set_time(rec, Timeline("frame"), DateTime(2026, 7, 10))
    Rerun.log(rec, "p", [Position3D((1f0, 2f0, 3f0))])
    Rerun.send_columns(rec, "m", [Timeline("frame") => 0:4],    # pair sugar with a Timeline
        ["rerun.components.Scalar" => Float64.(0:4)])
    Rerun.send_columns(rec, "m2", [Rerun.TimeColumn(tl, (0:4) .* 1_000_000)],
        ["rerun.components.Scalar" => Float64.(5:9)])
    @test Rerun.disable_timeline(rec, tl) === rec
    @test Rerun.reset_time(rec) === rec
    Rerun.log(rec, "p", [Position3D((0f0, 0f0, 0f0))])   # logging still works after reset

    # wire-layout vectors are aliased, not copied; other inputs convert
    raw = collect(Int64, 0:4)
    @test Rerun.TimeColumn("t", raw).values === raw
    tps = TimePoint.(1_000_000_000 .* collect(1:5))
    @test parent(Rerun.TimeColumn(tl, tps).values) === tps
    @test Rerun.TimeColumn(Timeline("f"), 0:4).values isa Vector{Int64}
    flush(rec)
    @test filesize(out) > 0
end

@testset "TimePoint (ns instants, exact conversions)" begin
    dt = DateTime(2026, 7, 10, 12, 34, 56, 789)
    ts = TimePoint(dt)
    @test DateTime(ts) == dt                                    # ms-aligned: exact both ways
    ts1 = ts + Nanosecond(123)
    @test_throws InexactError DateTime(ts1)                     # sub-ms: rounding must be explicit
    @test floor(DateTime, ts1) == dt
    @test round(DateTime, ts1) == dt
    @test ceil(DateTime, ts1) == dt + Millisecond(1)
    @test ts1 - ts == Nanosecond(123)
    @test ts1 - Nanosecond(123) == ts
    @test ts < ts1
    @test DateTime(TimePoint(0)) == DateTime(1970)
end

@testset "missing / validity bitmaps" begin
    rec = RecordingStream("rerun_jl_missing")
    out = tempname() * ".rrd"; Rerun.save(rec, out); Rerun.set_time(rec, "frame", 0)
    rad = Union{Radius,Missing}[Radius(0.1f0), missing, Radius(0.3f0), missing]
    pos = Union{Position3D,Missing}[Position3D((1f0,2f0,3f0)), missing, Position3D((4f0,5f0,6f0))]
    Rerun.log(rec, "r", rad)                                       # atom + missing
    Rerun.log(rec, "p", pos)                                       # FSL + missing
    Rerun.log(rec, "s", "rerun.components.Scalar",
        Union{Float64,Missing}[1.0, missing, 3.0])                 # string API + missing
    Rerun.log(rec, "ok", [Position3D((0f0,0f0,0f0))])              # non-missing
    flush(rec)
    @test isfile(out) && filesize(out) > 0

    bm, nc = Rerun._validity_bitmap(rad)
    @test nc == 2 && (bm[1] & 0x0f) == 0x05                        # valid,null,valid,null
    @test Rerun._validity_bitmap([Radius(1f0)]) === (nothing, 0)   # type-stable no-missing path
    nm = [Position3D((1f0, 2f0, 3f0))]; Rerun.log(rec, "ok", nm); flush(rec)
    @test (@allocated Rerun.log(rec, "ok", nm)) == 0              # non-missing still 0-alloc
end

@testset "dense union (TensorData) + variant resolution" begin
    rec = RecordingStream("rerun_jl_union")
    out = tempname() * ".rrd"; Rerun.save(rec, out); Rerun.set_time(rec, "frame", 0)
    # TensorBuffer arms are the bare List<T> (no wrapping struct), so the buffer
    # value is the tagged vector — `:F32 => data`, or a bare Vector matched structurally.
    f32 = (shape=UInt64[2,3], names=String[], buffer=Float32[1,2,3,4,5,6])
    u8  = (shape=UInt64[2,2], names=String[], buffer=UInt8[10,20,30,40])
    Rerun.log(rec, "t",   "rerun.components.TensorData", [f32])         # F32 variant
    Rerun.log(rec, "i",   "rerun.components.TensorData", [u8])          # U8 variant
    Rerun.log(rec, "mix", "rerun.components.TensorData", [f32, u8])     # mixed-variant column
    flush(rec)
    @test isfile(out) && filesize(out) > 0

    buf = Rerun.COMPONENT_TYPES["rerun.components.TensorData"].fields[3].type
    @test buf.fields[2].type isa Rerun.ArrowList && buf.fields[12].name == "F64"  # arms unwrapped to List<T>
    @test Rerun._union_variant(Float32[1], buf.fields) == 11           # F32 (structural)
    @test Rerun._union_variant(UInt8[1],   buf.fields) == 2            # U8
    @test Rerun._union_variant(:F32 => Float32[], buf.fields) == 11    # explicit tag (empty still resolves)
    @test Rerun._union_variant(missing, buf.fields) == 1               # _null_markers

    # assembled-path conversion failure must throw cleanly (no crash / double-free
    # / leak from the partial buffers) — exercises the struct/union/list/atom cleanup.
    @test_throws Exception Rerun.log(rec, "bad", "rerun.components.TensorData",
        [(shape=UInt64[1], names=String[], buffer=(:F32 => Any["not a number"]))])

    # two variants sharing a Julia type -> ambiguous unless tagged
    af = [Rerun.ArrowField("_null_markers", Rerun.ArrowAtom(:null), true),
          Rerun.ArrowField("A", Rerun.ArrowAtom(:i64), false),
          Rerun.ArrowField("B", Rerun.ArrowAtom(:i64), false)]
    @test_throws ErrorException Rerun._union_variant(Int64(5), af)
    @test Rerun._union_variant(:B => Int64(5), af) == 3
end

@testset "log_tensor (Tensor archetype, row-major)" begin
    rec = RecordingStream("rerun_jl_tensor")
    out = tempname() * ".rrd"; Rerun.save(rec, out); Rerun.set_time(rec, "frame", 0)
    Rerun.log_tensor(rec, "heat", Float32[sin(i/8)*cos(j/8) for i in 1:32, j in 1:24])
    Rerun.log_tensor(rec, "vol", rand(UInt16, 8, 8, 4); names=["x","y","z"])
    Rerun.log_tensor(rec, "sig", Float64.(1:100))
    flush(rec)
    @test isfile(out) && filesize(out) > 0
    td = Rerun._tensordata(Float32[1 2 3; 4 5 6], nothing)
    @test td.shape == UInt64[2, 3]
    @test td.buffer == (:F32 => Float32[1, 2, 3, 4, 5, 6])           # tagged variant + row-major reorder
    # empty / zero-extent arrays resolve their union variant by eltype
    @test Rerun._tensordata(Float32[], nothing).buffer == (:F32 => Float32[])
    @test Rerun._tensordata(Array{UInt8}(undef, 0, 5), nothing).buffer == (:U8 => UInt8[])
end

@testset "assembled validity + zero-copy Blob" begin
    rec = RecordingStream("rerun_jl_amiss")
    out = tempname() * ".rrd"; Rerun.save(rec, out); Rerun.set_time(rec, "frame", 0)
    Rerun.log(rec, "labels", "rerun.components.Text", Union{String,Missing}["a", missing, "ccc"])
    Rerun.log(rec, "flags",  "rerun.components.ShowLabels", Union{Bool,Missing}[true, missing, false])
    Rerun.log(rec, "blob",   "rerun.components.Blob", Union{Vector{UInt8},Missing}[UInt8[1,2], missing])
    flush(rec)
    @test isfile(out) && filesize(out) > 0

    vp, nc = Rerun._owned_validity(Union{String,Missing}["a", missing])
    @test vp != C_NULL && nc == 1
    vp2, nc2 = Rerun._owned_validity(["a", "b"]); @test vp2 == C_NULL && nc2 == 0

    # zero-copy Blob: allocation is independent of payload size
    big = rand(UInt8, 1_000_000)
    Rerun.log(rec, "big", "rerun.components.Blob", [big]); flush(rec)
    @test (@allocated Rerun.log(rec, "big", "rerun.components.Blob", [big])) < 2048
end

@testset "typed carriers (Text/Blob) + blueprint enums" begin
    rec = RecordingStream("rerun_jl_carriers")
    out = tempname() * ".rrd"; Rerun.save(rec, out); Rerun.set_time(rec, "frame", 0)
    Rerun.log(rec, "labels", [Text("a"), Text("bb")])                     # carrier, component-vector path
    Rerun.log(rec, "opt", Union{Text,Missing}[Text("x"), missing])        # carrier + missing
    pts = [Position3D((Float32(i), 0f0, 0f0)) for i in 1:3]
    Rerun.log(rec, "pts", Points3D(pts; labels=[Text("a"), Text("b"), Text("c")]))  # carrier in archetype field
    Rerun.log(rec, "blob", [Blob(rand(UInt8, 10_000))])
    flush(rec)
    @test isfile(out) && filesize(out) > 0
    @test Text("hi").value == "hi" && fieldtype(Blob, :value) == Vector{UInt8}

    @test Rerun.Blueprint.BackgroundKind.SolidColor.value == 3            # blueprint enum namespace
    @test :Horizontal in propertynames(Rerun.Blueprint.ContainerKind)

    big = [Blob(rand(UInt8, 1_000_000))]; Rerun.log(rec, "big", big); flush(rec)
    @test (@allocated Rerun.log(rec, "big", big)) < 4096                  # typed Blob still zero-copy
end

@testset "GC-stress: async release drained" begin
    rec = RecordingStream("rerun_jl_stress")
    Rerun.save(rec, tempname() * ".rrd")
    for f in 1:200
        Rerun.set_time(rec, "frame", f)
        pts = [(Float32(f), Float32(i), 0f0) for i in 1:50]
        Rerun.log(rec, "world/points", "rerun.components.Position3D", pts)
        f % 20 == 0 && GC.gc()
    end
    flush(rec); GC.gc(); GC.gc(); flush(rec)
    n = lock(Rerun._REG_LOCK) do; count(!isnothing, Rerun._ROOTS) end
    @test n <= 1
end

@testset "set_sinks (tagged union)" begin
    rec = RecordingStream("rerun_jl_sinks")
    a = tempname() * ".rrd"; b = tempname() * ".rrd"
    Rerun.set_sinks(rec, FileSink(a), FileSink(b))     # multi-sink, exercises the union layout
    Rerun.set_time(rec, "frame", 0)
    Rerun.log(rec, "p", [Position3D((1f0, 2f0, 3f0))])
    flush(rec)
    @test isfile(a) && filesize(a) > 0
    @test isfile(b) && filesize(b) > 0
    @test_throws ArgumentError Rerun.set_sinks(rec)
end

@testset "global scope + file importers (#5/#6)" begin
    rec = RecordingStream("rerun_jl_api")
    @test Rerun.set_global!(rec) === rec
    @test Rerun.set_thread_local!(rec) === rec
    @test Rerun.disable_timeline(rec, "frame") === rec
    # round-trip a real .rrd through the importer (path + in-memory contents)
    src = tempname() * ".rrd"
    s = RecordingStream("src"); Rerun.save(s, src); Rerun.set_time(s, "frame", 0)
    Rerun.log(s, "p", [Position3D((1f0, 2f0, 3f0))]); flush(s); close(s)
    rec2 = RecordingStream("imp"); Rerun.save(rec2, tempname() * ".rrd")
    Rerun.log_file(rec2, src; entity_path_prefix="a")
    Rerun.log_file_contents(rec2, src, read(src); entity_path_prefix="b")
    flush(rec2)
    @test_throws RerunError Rerun.log_file(rec2, "/no/such/file.png")
end

@testset "serve_grpc / spawn / escape / video (small API)" begin
    @test Rerun.escape_entity_path_part("my object") == "my\\ object"
    @test Rerun.escape_entity_path_part("a/b") == "a\\/b"
    rec = RecordingStream("rerun_jl_serve")
    Rerun.serve_grpc(rec; port=9989)                       # binds an in-process gRPC server
    @test Rerun.is_enabled(rec)
    @test_throws RerunError Rerun.spawn(; executable_name="definitely_not_rerun_xyz")
    @test_throws RerunError Rerun.video_frame_timestamps_nanos(rand(UInt8, 64); media_type="video/mp4")
end

@testset "RerunError surfaces from the C layer" begin
    rec = RecordingStream("rerun_jl_err")
    # invalid gRPC URL is an argument-parse error -> synchronous RerunError
    err = try
        Rerun.connect_grpc(rec, "http://not-a-rerun-url")
        nothing
    catch e
        e
    end
    @test err isa RerunError
    @test err.code != 0
    @test occursin("RerunError", sprint(showerror, err))
end

@testset "validation errors (caught before the C call)" begin
    rec = RecordingStream("rerun_jl_val")
    @test_throws ErrorException Rerun.log(rec, "x", "rerun.components.DoesNotExist", Float32[1])
end

@testset "close is eager and idempotent" begin
    rec = RecordingStream("rerun_jl_close")
    Rerun.save(rec, tempname() * ".rrd")
    @test rec.handle != 0
    close(rec)
    @test rec.handle == 0
    close(rec)            # idempotent
    @test rec.handle == 0
end
