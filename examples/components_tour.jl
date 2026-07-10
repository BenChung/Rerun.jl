# A tour of component kinds: enums (per-type variant namespace), typed data
# carriers (Text/Blob), and the string API for components without a typed
# struct.
#
#   julia --project=. examples/components_tour.jl

using Rerun
using Rerun.Components
import Rerun.Components: Text, Blob   # explicit: `Text` clashes with Base.Text

rec = RecordingStream("rerun_example_tour")
Rerun.save(rec, joinpath(@__DIR__, "tour.rrd"))
Rerun.set_time(rec, Timeline("frame"), 0)

# Enum component: tab-completable per-type variants (Colormap.Inferno, ...).
Rerun.log(rec, "depth", [Colormap.Inferno])

# Typed data carriers: `Text` wraps a String (utf8), `Blob` wraps bytes
# (list<u8>, logged zero-copy).
Rerun.log(rec, "labels", [Text("alpha"), Text("beta"), Text("gamma")])
Rerun.log(rec, "payload", [Blob(collect(0x00:0xff))])

# Components without a typed struct (bool, struct layouts) log via the string
# API, resolved from the generated catalog.
Rerun.log(rec, "flags", "rerun.components.ShowLabels", [true, false, true])

flush(rec)
println("wrote ", joinpath(@__DIR__, "tour.rrd"))
