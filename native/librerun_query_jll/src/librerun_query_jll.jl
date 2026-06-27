# Local dev stand-in for the BinaryBuilder-generated `librerun_query_jll`.
#
# It resolves the library straight from cargo's build output, so the dev loop is
# just `cargo build` — no BinaryBuilder round-trip, no global depot override. The
# UUID (in Project.toml) is the canonical BB/Yggdrasil UUID for the real JLL, and
# the `librerun_query` ccall symbol matches, so publishing the real JLL is a
# one-line change: drop the `[sources]` entry in Rerun.jl that points here.
module librerun_query_jll

import Libdl

export librerun_query

# native/target/release/librerun_query.<dlext>, relative to this file
# (src/ -> librerun_query_jll/ -> native/).
const librerun_query_path = abspath(joinpath(
    @__DIR__, "..", "..", "target", "release", "librerun_query." * Libdl.dlext))

# Call site is identical to the real JLL: `ccall((:sym, librerun_query), ...)`.
const librerun_query = librerun_query_path

is_available() = true

function __init__()
    isfile(librerun_query_path) || error("""
        librerun_query_jll (local dev stand-in): library not built.
        Run `cargo build --release` in native/ (expected: $librerun_query_path).""")
    Libdl.dlopen(librerun_query_path)
    return
end

end # module
