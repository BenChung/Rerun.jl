# Tensors / heatmaps via `log_tensor` (built on the dense-union TensorData encoder).
#
#   julia --project=. examples/tensor.jl
#   RERUN_URL=rerun+http://192.168.0.25:9876/proxy julia --project=. examples/tensor.jl

using Rerun

rec = RecordingStream("rerun_example_tensor")
url = get(ENV, "RERUN_URL", nothing)
url === nothing ? Rerun.spawn(rec) : Rerun.connect_grpc(rec, url)

# An animated 2D heatmap — shown as a colored grid in the viewer's tensor view.
for frame in 0:90
    Rerun.set_time(rec, "frame", frame)
    φ = frame * 0.12
    heat = Float32[sin(i/7 + φ) * cos(j/9) for i in 1:96, j in 1:128]
    Rerun.log_tensor(rec, "heatmap", heat)
end

# A static 3D volume (UInt8 → the U8 union variant) with named dimensions.
Rerun.log_tensor(rec, "volume", rand(UInt8, 32, 32, 16); names = ["x", "y", "z"])

flush(rec)
println("done")
