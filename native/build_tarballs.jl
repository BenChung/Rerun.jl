# BinaryBuilder recipe for librerun_query — the Arrow-C-Stream query shim.
#
# This file is the source-of-truth copy of the recipe. The canonical release
# build lives in Yggdrasil (R/librerun_query/build_tarballs.jl); mirror this
# file there when cutting a public release. Yggdrasil requires GitSource (no
# DirectorySource / file://), which is why the source below is a GitSource.
#
# Local build (validates the recipe without pushing a tag): swap the GitSource
# for a DirectorySource of the working tree, e.g.
#   sources = [DirectorySource(joinpath(@__DIR__, "..");
#                              target = "Rerun.jl")]
# then run: julia --project build_tarballs.jl --deploy=local x86_64-linux-gnu
# (Day-to-day dev does NOT need this: the in-repo librerun_query_jll/ stand-in
#  resolves the lib from cargo output. Run a local BB build only to validate the
#  recipe or to self-host a release. See native/README.md.)

using BinaryBuilder, Pkg

name = "librerun_query"
version = v"0.1.0"

# Pin to the Rerun.jl commit/tag holding the matching `native/` crate.
sources = [
    GitSource("https://github.com/BenChung/Rerun.jl.git", "FILL-IN-COMMIT-SHA"),
]

# Build the `native/` subdir of the repo. The crate depends on the rerun crates
# (via the `rerun` crate's `dataframe` feature), which pull zstd-sys and other
# cc-rs crates — hence the env exports below, carried over from the librerun_c
# recipe. NOTE: rerun 0.33 requires rustc >= 1.92; confirm BinaryBuilder's Rust
# toolchain meets that MSRV (or pin a newer Rust) before building.
script = raw"""
cd $WORKSPACE/srcdir/Rerun*/native

export CC_$(echo $rust_host | sed "s/-/_/g")=$CC_BUILD
export ZSTD_SYS_USE_PKG_CONFIG=1
export PKG_CONFIG_ALLOW_CROSS=1
if [[ "${target}" == *musl* ]]; then
    export RUSTFLAGS="-C target-feature=-crt-static"
fi

cargo build --release --target ${rust_target}
# `*` absorbs the platform-dependent `lib` prefix (librerun_query.so / rerun_query.dll);
# ${libdir} is `bin` on Windows, `lib` elsewhere, so the destination is right everywhere.
install -Dvm 755 -t "${libdir}" target/${rust_target}/release/*rerun_query*.${dlext}
install_license $WORKSPACE/srcdir/Rerun*/LICENSE
"""

platforms = supported_platforms()
filter!(p -> !Sys.iswindows(p) || arch(p) != "i686", platforms)   # i686-windows rust toolchain unusable
filter!(p -> arch(p) != "riscv64", platforms)                     # no rust toolchain
filter!(p -> !(Sys.isfreebsd(p) && arch(p) == "aarch64"), platforms)

products = [
    # Rust names the cdylib `rerun_query.dll` on Windows, `librerun_query.{so,dylib}` elsewhere.
    LibraryProduct(["librerun_query", "rerun_query"], :librerun_query),
]

dependencies = Dependency[
    Dependency("CompilerSupportLibraries_jll"),
    Dependency("Zstd_jll"; compat="1.5.7"),   # link system zstd, matching the librerun_c build
]

build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies;
    julia_compat = "1.6", compilers = [:rust, :c],
    preferred_gcc_version = v"15.2.0", lock_microarchitecture = false)
