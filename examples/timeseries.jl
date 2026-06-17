# Scalar time series via the columnar bulk API (`send_columns`).
#
#   julia --project=. examples/timeseries.jl
#
# `send_columns` submits a whole column at once (one logical row per index),
# rather than row-at-a-time `log`. Flat component columns are zero-copy.

using Rerun

rec = RecordingStream("rerun_example_timeseries")
Rerun.save(rec, joinpath(@__DIR__, "timeseries.rrd"))

N = 1000
t = collect(0:N-1)

# Two scalar series on a shared "step" timeline, each sent in one call.
Rerun.send_columns(rec, "metrics/sin",
    ["step" => t],
    ["rerun.components.Scalar" => sin.(t .* 0.05)])

Rerun.send_columns(rec, "metrics/cos",
    ["step" => t],
    ["rerun.components.Scalar" => cos.(t .* 0.05) .* 0.5])

# A wall-clock timeline uses nanosecond timestamps.
t0 = 1_700_000_000_000_000_000          # ns since epoch
Rerun.send_columns(rec, "metrics/noise",
    [Rerun.TimeColumn("time", t0 .+ t .* 1_000_000; kind=:timestamp)],
    ["rerun.components.Scalar" => randn(N)])

flush(rec)
println("wrote ", joinpath(@__DIR__, "timeseries.rrd"))
