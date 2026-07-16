# Reading data out — load an .rrd as a DataFrame.
#
#   julia --project=. examples/dataframe.jl
#
# `load_recording` opens a recording for querying; `view`/`select` yield a
# Tables.jl source that DataFrames (or any Tables.jl consumer) ingests. Scalar
# and index columns alias the Arrow buffers zero-copy; timestamp indexes decode
# as ns-exact `TimePoint`s. DataFrames is not a Rerun dependency — add it to
# your environment to run this.

using Rerun
using Dates
import Rerun.Archetypes: Scalars
using DataFrames

# A small recording to query back: one scalar series indexed by an integer
# "step" timeline and a wall-clock "time" timeline (one sample per ms).
path = joinpath(@__DIR__, "dataframe.rrd")
rec = RecordingStream("rerun_example_dataframe")
Rerun.save(rec, path)
step = Timeline("step")
wall = Timeline("time", :timestamp)
steps = collect(0:99)
t0 = TimePoint(DateTime(2026, 7, 10))
Rerun.send_columns(rec, "metrics/sin",
    (step => steps, Rerun.TimeColumn(wall, t0 .+ Millisecond.(steps))),
    Rerun.columns(Scalars; scalars=sin.(steps .* 0.1)))
flush(rec)

# The recording is the authority on its timelines: look them up as concrete,
# typed `Timeline{T}`s.
recording = Rerun.load_recording(path)
println("timelines: ", Rerun.timelines(recording))

# Read it back as a DataFrame, indexed by "step" (a name string works too).
df = DataFrame(Rerun.select(Rerun.view(recording; index=step)))
println(first(df, 5))
println(nrow(df), " rows × ", ncol(df), " columns: ", names(df))

# Timestamp indexes decode losslessly as `TimePoint`; `filter_range` bounds
# convert exactly from `DateTime` (or `TimePoint` for sub-ms precision).
v = Rerun.view(recording; index=Rerun.timeline(recording, "time"))
Rerun.filter_range(v, DateTime(2026, 7, 10, 0, 0, 0, 25), DateTime(2026, 7, 10, 0, 0, 0, 75))
dft = DataFrame(Rerun.select(v))
println(nrow(dft), " rows between 25ms and 75ms; time column eltype: ", eltype(dft.time))
