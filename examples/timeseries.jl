# Scalar time series via the columnar bulk API (`send_columns`).
#
#   julia --project=. examples/timeseries.jl
#
# `send_columns` submits a whole column at once (one logical row per index),
# rather than row-at-a-time `log`. Flat component columns are zero-copy.
# A `Timeline` is declared once with its kind; every call site then agrees on
# the timeline's type, and typed time values convert exactly.

using Rerun
using Dates
import Rerun.Components: Scalar

rec = RecordingStream("rerun_example_timeseries")
Rerun.save(rec, joinpath(@__DIR__, "timeseries.rrd"))

N = 1000
t = collect(0:N-1)

# Two scalar series on a shared integer "step" timeline, each sent in one call.
step = Timeline("step")
Rerun.send_columns(rec, "metrics/sin",
    (step => t,),
    (Scalar => sin.(t .* 0.05),))

Rerun.send_columns(rec, "metrics/cos",
    (step => t,),
    (Scalar => cos.(t .* 0.05) .* 0.5,))

# A wall-clock timeline: values are `TimePoint`s (nanoseconds since epoch).
# `DateTime` converts exactly, and Period arithmetic stays ns-exact.
wall = Timeline("time", :timestamp)
t0 = TimePoint(DateTime(2026, 7, 10, 12))
Rerun.send_columns(rec, "metrics/noise",
    (Rerun.TimeColumn(wall, t0 .+ Millisecond.(t)),),
    (Scalar => randn(N),))

flush(rec)
println("wrote ", joinpath(@__DIR__, "timeseries.rrd"))
