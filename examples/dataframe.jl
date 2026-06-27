# Reading data out — load an .rrd as a DataFrame.
#
#   julia --project=. examples/dataframe.jl
#
# `load_recording` opens a recording for querying; `view`/`select` yield a
# Tables.jl source that DataFrames (or any Tables.jl consumer) ingests. Scalar and
# index columns alias the Arrow buffers zero-copy. DataFrames is not a Rerun
# dependency — add it to your environment to run this.

using Rerun
using DataFrames

# A small recording to query back: one scalar series on a "step" timeline.
path = joinpath(@__DIR__, "dataframe.rrd")
rec = RecordingStream("rerun_example_dataframe")
Rerun.save(rec, path)
step = collect(0:99)
Rerun.send_columns(rec, "metrics/sin",
    ["step" => step],
    ["rerun.components.Scalar" => sin.(step .* 0.1)])
flush(rec)

# Read it back as a DataFrame, indexed by the "step" timeline.
recording = Rerun.load_recording(path)
df = DataFrame(Rerun.select(Rerun.view(recording; index="step")))

println(first(df, 5))
println(nrow(df), " rows × ", ncol(df), " columns: ", names(df))
