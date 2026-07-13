# Points3D — the typed component / archetype API.
#
#   julia --project=. examples/points3d.jl
#
# Writes an .rrd next to this file; open it with `rerun points3d.rrd`, or swap
# `save` for `Rerun.spawn(rec)` to launch the viewer live.

using Rerun
using Rerun.Components, Rerun.Archetypes

rec = RecordingStream("rerun_example_points3d")
Rerun.save(rec, joinpath(@__DIR__, "points3d.rrd"))

frame = Timeline("frame")   # declared once; carries the timeline's kind everywhere
n = 200
for f in 0:119
    Rerun.set_time(rec, frame, f)
    φ = f * 0.04
    pts  = [Position3D((cos(8π*i/n + φ) * Float32(i/n),
                        sin(8π*i/n + φ) * Float32(i/n),
                        Float32(i/n) * 2 - 1)) for i in 1:n]
    cols = [Color((UInt32(round(255*i/n)) << 24) | 0x00a0ffff) for i in 1:n]
    radii = [Radius(0.01f0 + 0.02f0 * Float32(i/n)) for i in 1:n]

    # Archetype form: kwargs live in the constructor, `log` stays uniform.
    Rerun.log(rec, "spiral", Points3D(pts; colors=cols, radii=radii))
end

# Equivalent lower-level forms (one row, multiple component batches):
Rerun.set_time(rec, frame, 120)
p = [Position3D((0f0,0f0,0f0)), Position3D((1f0,1f0,1f0))]
Rerun.log(rec, "pair", p, [Color(0xff0000ff), Color(0x00ff00ff)])  # varargs of typed batches

# Interop: a foreign 12-byte-isbits vector declared wire-compatible logs as
# Position3D, zero-copy.
struct XYZ; x::Float32; y::Float32; z::Float32; end
Rerun.wire_compatible(::Type{XYZ}, ::Type{Position3D}) = true
Rerun.log(rec, "foreign", Position3D, [XYZ(2f0, 0f0, 0f0), XYZ(2f0, 1f0, 0f0)])

flush(rec)
println("wrote ", joinpath(@__DIR__, "points3d.rrd"))
