using Documenter
using Rerun

# Example pages are generated from the scripts in `examples/` so the docs stay
# in sync with the runnable examples. Each script's leading `#` comment block
# becomes the page intro; the rest becomes a Julia code block.
const EX_DIR = normpath(@__DIR__, "..", "examples")
const EX_OUT = joinpath(@__DIR__, "src", "examples")

const FEATURED = [
    ("points3d",        "Points & archetypes"),
    ("components_tour", "A tour of components"),
    ("timeseries",      "Scalar time series"),
    ("tensor",          "Tensors & heatmaps"),
    ("dataframe",       "Reading data out as a DataFrame"),
]

function generate_example(name, title)
    lines = split(read(joinpath(EX_DIR, "$name.jl"), String), '\n')
    k = 1
    while k <= length(lines) && (isempty(strip(lines[k])) || startswith(strip(lines[k]), "#"))
        k += 1
    end
    header = lines[1:k-1]
    code   = strip(join(lines[k:end], '\n'))

    prose = String[]; cmds = String[]
    for l in header
        s = strip(l)
        if s == "#" || isempty(s)
            (!isempty(prose) && prose[end] != "") && push!(prose, "")   # paragraph break
            continue
        end
        body = strip(lstrip(s, '#'))
        if startswith(body, "julia ") || startswith(body, "RERUN_URL")
            push!(cmds, body)
        elseif !isempty(body)
            push!(prose, body)
        end
    end

    io = IOBuffer()
    println(io, "# ", title, "\n")
    foreach(p -> println(io, p), prose)
    println(io)
    if !isempty(cmds)
        println(io, "Run it:\n\n```sh")
        foreach(c -> println(io, c), cmds)
        println(io, "```\n")
    end
    println(io, "```julia")
    println(io, code)
    println(io, "```")

    mkpath(EX_OUT)
    write(joinpath(EX_OUT, "$name.md"), String(take!(io)))
end

for (name, title) in FEATURED
    generate_example(name, title)
end

makedocs(;
    sitename = "Rerun.jl",
    authors  = "Benjamin Chung",
    modules  = [Rerun],
    repo     = Documenter.Remotes.GitHub("BenChung", "Rerun.jl"),
    format   = Documenter.HTML(; prettyurls = get(ENV, "CI", "false") == "true"),
    # Internal helpers (marshal/cdata/util) carry docstrings outside the public API
    # page; downgrade their missing-docs and cross-reference errors to warnings.
    warnonly = [:missing_docs, :cross_references],
    pages = [
        "Home" => "index.md",
        "Examples" => ["examples/$name.md" for (name, _) in FEATURED],
        "API Reference" => "api.md",
    ],
)

# Deploys to GitHub Pages when run under CI with a token; a no-op locally.
deploydocs(; repo = "github.com/BenChung/Rerun.jl.git")
