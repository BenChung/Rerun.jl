# Blueprint enum components (viewer configuration) live in `Rerun.Blueprint`,
# kept apart from data components so their short names never clash.
#
#   julia --project=. examples/blueprint_enums.jl

using Rerun
const BP = Rerun.Blueprint

# Each blueprint enum is a Component type with a tab-completable variant
# namespace (the same pattern as data enums like Colormap):
@show BP.BackgroundKind.SolidColor
@show BP.ContainerKind.Horizontal
@show BP.PanelState.Collapsed
@show propertynames(BP.ViewFit)

# They serialize like any component. (Configuring an actual view also needs the
# blueprint archetypes/stream; here we just show the component + its wire value.)
rec = RecordingStream("rerun_example_blueprint")
Rerun.save(rec, joinpath(@__DIR__, "blueprint.rrd"))
Rerun.log(rec, "config/background", [BP.BackgroundKind.GradientDark])
flush(rec)
println("BackgroundKind.GradientDark wire value = ", BP.BackgroundKind.GradientDark.value)
