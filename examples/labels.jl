# Typed Text / Blob carrier components.
#
#   julia --project=. examples/labels.jl
#   RERUN_URL=rerun+http://192.168.0.25:9876/proxy julia --project=. examples/labels.jl

using Rerun
# `Text` collides with `Base.Text`, so import the component names explicitly
# (or qualify them as `Rerun.Components.Text`).
import Rerun.Components: Position3D, Color, Text, Blob
import Rerun.Archetypes: Points3D

rec = RecordingStream("rerun_example_labels")
url = get(ENV, "RERUN_URL", nothing)
url === nothing ? Rerun.save(rec, joinpath(@__DIR__, "labels.rrd")) : Rerun.connect_grpc(rec, url)
Rerun.set_time(rec, Timeline("frame"), 0)

# A ring of points, each with a text label. `Text` wraps a String; the archetype
# unwraps it to the utf8 component automatically.
n = 8
pts    = [Position3D((Float32(cos(2π*i/n)), Float32(sin(2π*i/n)), 0f0)) for i in 1:n]
labels = [Text("p$i") for i in 1:n]
cols   = [Color(0x44aaffff) for _ in 1:n]
Rerun.log(rec, "ring", Points3D(pts; labels = labels, colors = cols))

# `Blob` wraps raw bytes; logged zero-copy (only offsets/bookkeeping allocate).
Rerun.log(rec, "payload", [Blob(rand(UInt8, 4096))])

flush(rec)
println("done")
