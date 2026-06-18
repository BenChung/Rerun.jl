# Drive a live Rerun viewer over gRPC via the sink API.
#
#   julia --project=. examples/live_viewer.jl                       # spawn a local viewer
#   RERUN_URL=rerun+http://192.168.0.25:9876/proxy julia --project=. examples/live_viewer.jl
#
# Three ways to go live:
#   Rerun.spawn(rec)                          launch a viewer process + connect (needs `rerun` on PATH)
#   Rerun.connect_grpc(rec, url)              connect to an already-running viewer
#   Rerun.set_sinks(rec, GrpcSink(url=url))   attach a gRPC sink (this file)

using Rerun
using Rerun.Components, Rerun.Archetypes

rec = RecordingStream("rerun_jl_live"; recording_id="live-demo")

url = get(ENV, "RERUN_URL", nothing)
if url === nothing
    Rerun.spawn(rec)                              # opens a local viewer
else
    Rerun.set_sinks(rec, GrpcSink(; url=url))     # stream to a running viewer over gRPC
end

# Animate a colored spiral; the viewer updates live as we log each frame.
n = 300
for frame in 0:399
    Rerun.set_time(rec, "frame", frame)
    φ = frame * 0.04
    pts  = [Position3D((cos(10π*i/n + φ) * Float32(i/n),
                        sin(10π*i/n + φ) * Float32(i/n),
                        Float32(i/n) * 2 - 1)) for i in 1:n]
    cols = [Color((UInt32(round(255*i/n)) << 24) | 0x30c0ffff) for i in 1:n]
    Rerun.log(rec, "live/spiral", Points3D(pts; colors=cols, radii=fill(Radius(0.015f0), n)))
    sleep(1/60)                                   # ~60 fps so the motion is visible
end

flush(rec)
println("done streaming")
