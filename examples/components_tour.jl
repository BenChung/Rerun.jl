# A tour of component kinds: enums (per-type variant namespace), text/labels,
# and assembled components logged via the string API.
#
#   julia --project=. examples/components_tour.jl

using Rerun
using Rerun.Components

rec = RecordingStream("rerun_example_tour")
Rerun.save(rec, joinpath(@__DIR__, "tour.rrd"))
Rerun.set_time(rec, "frame", 0)

# Enum component: tab-completable per-type variants (Colormap.Inferno, ...).
Rerun.log(rec, "depth", [Colormap.Inferno])

# Text / labels (utf8, assembled exporter).
Rerun.log(rec, "labels", "rerun.components.Text", ["alpha", "beta", "gamma"])

# Blob (list<u8>).
Rerun.log(rec, "payload", "rerun.components.Blob", [collect(0x00:0xff)])

# Booleans (bit-packed).
Rerun.log(rec, "flags", "rerun.components.ShowLabels", [true, false, true])

flush(rec)
println("wrote ", joinpath(@__DIR__, "tour.rrd"))
