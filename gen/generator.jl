using Clang.Generators
using librerun_c_jll

cd(@__DIR__)

include_dir = normpath(librerun_c_jll.artifact_dir, "include")
rerun_c_dir = joinpath(include_dir, "rerun/c")

options = load_options(joinpath(@__DIR__, "generator.toml"))

args = get_default_args()  # supplies the required base clang flags
push!(args, "-I$include_dir")

headers = [joinpath(rerun_c_dir, header) for header in readdir(rerun_c_dir) if endswith(header, ".h")]

ctx = create_context(headers, args, options)

build!(ctx)