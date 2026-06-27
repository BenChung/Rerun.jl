# Dataframe query: read recordings out as zero-copy Tables.jl sources.
#
# Calls the librerun_query C ABI (load -> view -> select -> streaming reader),
# decodes each Arrow C Data Interface batch into Julia columns (primitive columns
# alias the Rust buffers zero-copy; variable-length columns decode), and presents
# the result as a Tables.jl column source. See native/DESIGN.md.

using librerun_query_jll
import Tables

const _LIB = librerun_query_jll.librerun_query
const _AS = LibRerunC.ArrowSchema
const _AA = LibRerunC.ArrowArray

# ---------------------------------------------------------------------------
# C ABI: error type + ccall helpers
# ---------------------------------------------------------------------------
struct _RrqError
    code::UInt32
    description::NTuple{512,UInt8}
end
_RrqError() = _RrqError(0, ntuple(_ -> UInt8(0), 512))

function _check(err::Ref{_RrqError}, what::AbstractString)
    err[].code == 0 && return
    bytes = UInt8[]
    for b in err[].description
        b == 0 && break
        push!(bytes, b)
    end
    throw(RerunError("$what: $(String(bytes))"))
end

_empty_aa() = _AA(0, 0, 0, 0, 0, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL)

# ---------------------------------------------------------------------------
# handles
# ---------------------------------------------------------------------------
"A loaded Rerun recording, queryable with [`view`](@ref) and [`select`](@ref)."
mutable struct Recording
    ptr::Ptr{Cvoid}
    path::String
    function Recording(ptr::Ptr{Cvoid}, path::AbstractString)
        rec = new(ptr, String(path))
        finalizer(rec) do r
            r.ptr == C_NULL || ccall((:rrq_engine_free, _LIB), Cvoid, (Ptr{Cvoid},), r.ptr)
            r.ptr = C_NULL
        end
        rec
    end
end

function Base.show(io::IO, ::MIME"text/plain", r::Recording)
    if r.ptr == C_NULL
        print(io, "Rerun.Recording(<freed>)")
        return
    end
    summary = unsafe_string(ccall((:rrq_recording_summary, _LIB), Cstring, (Ptr{Cvoid},), r.ptr))
    print(io, "Rerun.Recording: ", summary, " (", r.path, ")")
end
Base.show(io::IO, r::Recording) = print(io, "Rerun.Recording(", repr(r.path), ")")

mutable struct RecordingView
    rec::Recording        # keeps the engine alive
    ptr::Ptr{Cvoid}
    function RecordingView(rec::Recording, ptr::Ptr{Cvoid})
        v = new(rec, ptr)
        finalizer(v) do x
            x.ptr == C_NULL || ccall((:rrq_query_free, _LIB), Cvoid, (Ptr{Cvoid},), x.ptr)
            x.ptr = C_NULL
        end
        v
    end
end

"""
    load_recording(path) -> Recording

Open an `.rrd` file and return a handle to its single recording's query engine.
"""
function load_recording(path::AbstractString)
    err = Ref(_RrqError())
    p = ccall((:rrq_load_recording, _LIB), Ptr{Cvoid}, (Cstring, Ptr{_RrqError}), path, err)
    p == C_NULL && _check(err, "load_recording")
    Recording(p, path)
end

"""
    view(rec; index, contents=nothing) -> RecordingView

Build a query over `rec`. `index` is the timeline driving rows; `contents` is
`nothing` (all entities) or a collection of entity-path strings.
"""
function view(rec::Recording; index::AbstractString, contents=nothing)
    q = ccall((:rrq_query_new, _LIB), Ptr{Cvoid}, ())
    v = RecordingView(rec, q)
    ccall((:rrq_query_set_index, _LIB), Cvoid, (Ptr{Cvoid}, Cstring), q, index)
    contents === nothing || set_contents!(v, contents)
    v
end

function set_contents!(v::RecordingView, paths)
    cstrs = Base.cconvert.(Cstring, String.(collect(paths)))
    GC.@preserve cstrs begin
        ptrs = [Base.unsafe_convert(Cstring, c) for c in cstrs]
        ccall((:rrq_query_set_contents, _LIB), Cvoid,
            (Ptr{Cvoid}, Ptr{Cstring}, Csize_t), v.ptr, ptrs, length(ptrs))
    end
    v
end

"Restrict rows to the inclusive index range `[lo, hi]`."
filter_range(v::RecordingView, lo::Integer, hi::Integer) =
    (ccall((:rrq_query_filter_range, _LIB), Cvoid, (Ptr{Cvoid}, Int64, Int64), v.ptr, lo, hi); v)

"Forward-fill each column with its latest value at every index row."
fill_latest_at(v::RecordingView) =
    (ccall((:rrq_query_fill_latest_at, _LIB), Cvoid, (Ptr{Cvoid},), v.ptr); v)

# ---------------------------------------------------------------------------
# batch lifetime: one owned ArrowArray per batch, released on finalize
# ---------------------------------------------------------------------------
mutable struct _Batch
    ref::Ref{_AA}
    released::Bool
    function _Batch(ref::Ref{_AA})
        b = new(ref, false)
        finalizer(_release!, b)
        b
    end
end
function _release!(b::_Batch)
    b.released && return
    b.released = true
    a = b.ref[]
    a.release == C_NULL || ccall(a.release, Cvoid, (Ptr{_AA},), b.ref)
    return
end

# Zero-copy column: aliases a Rust-owned buffer, holds its batch alive.
struct ArrowColumn{T} <: AbstractVector{T}
    data::Vector{T}
    owner::_Batch
end
Base.size(c::ArrowColumn) = size(c.data)
Base.IndexStyle(::Type{<:ArrowColumn}) = Base.IndexLinear()
Base.@propagate_inbounds Base.getindex(c::ArrowColumn, i::Int) = c.data[i]

# ---------------------------------------------------------------------------
# Arrow C Data Interface decode
# ---------------------------------------------------------------------------
const _PRIM = Dict{String,DataType}(
    "c" => Int8, "C" => UInt8, "s" => Int16, "S" => UInt16,
    "i" => Int32, "I" => UInt32, "l" => Int64, "L" => UInt64,
    "e" => Float16, "f" => Float32, "g" => Float64,
)

_sname(p::Ptr{_AS}) = (s = unsafe_load(p); s.name == C_NULL ? "" : unsafe_string(s.name))

_bit(p::Ptr{UInt8}, k::Int) = p == C_NULL || ((unsafe_load(p, (k >> 3) + 1) >> (k & 7)) & 0x01) == 0x01

# Validity bitmap pointer, or NULL if the array has no nulls (all-valid).
_validity(a::_AA) = a.null_count == 0 ? Ptr{UInt8}(C_NULL) : Ptr{UInt8}(unsafe_load(a.buffers, 1))

# Arrow temporal types are stored as integers; expose the raw storage value
# (e.g. timestamp/duration nanoseconds). Returns the storage element type, or
# `nothing` if `fmt` is not a temporal code.
function _temporal_storage(fmt::AbstractString)
    startswith(fmt, "ts") && return Int64           # timestamp
    startswith(fmt, "tD") && return Int64           # duration
    fmt == "tdD" && return Int32                    # date32 (days)
    fmt == "tdm" && return Int64                    # date64 (ms)
    (fmt == "tts" || fmt == "ttm") && return Int32  # time32
    (fmt == "ttu" || fmt == "ttn") && return Int64  # time64
    return nothing
end

function _decode(cs::Ptr{_AS}, ca::Ptr{_AA}, batch::_Batch)
    s = unsafe_load(cs)
    a = unsafe_load(ca)
    s.dictionary == C_NULL ||
        error("rerun query: dictionary-encoded column $(repr(_sname(cs))) not supported")
    fmt = unsafe_string(s.format)
    if haskey(_PRIM, fmt)
        return _decode_primitive(_PRIM[fmt], a, batch)
    elseif fmt == "b"
        return _decode_bool(a)
    elseif fmt == "u"
        return _decode_utf8(a)
    elseif fmt == "+l"
        return _decode_list(s, a, batch)
    elseif startswith(fmt, "+w:")
        return _decode_fixedlist(s, a, batch, parse(Int, fmt[4:end]))
    end
    st = _temporal_storage(fmt)
    st === nothing || return _decode_primitive(st, a, batch)
    error("rerun query: unsupported Arrow column type $(repr(fmt)) (column $(repr(_sname(cs))))")
end

function _decode_primitive(::Type{T}, a::_AA, batch::_Batch) where {T}
    n = Int(a.length)
    off = Int(a.offset)
    vals = Ptr{T}(unsafe_load(a.buffers, 2)) + off * sizeof(T)
    data = unsafe_wrap(Array, vals, n; own=false)
    a.null_count == 0 && return ArrowColumn{T}(data, batch)
    valid = Ptr{UInt8}(unsafe_load(a.buffers, 1))
    out = Vector{Union{Missing,T}}(undef, n)
    @inbounds for i in 1:n
        out[i] = _bit(valid, off + i - 1) ? data[i] : missing
    end
    out
end

function _decode_bool(a::_AA)
    n = Int(a.length)
    off = Int(a.offset)
    bp = Ptr{UInt8}(unsafe_load(a.buffers, 2))
    valid = _validity(a)
    out = valid == C_NULL ? Vector{Bool}(undef, n) : Vector{Union{Missing,Bool}}(undef, n)
    @inbounds for i in 1:n
        out[i] = (valid != C_NULL && !_bit(valid, off + i - 1)) ? missing : _bit(bp, off + i - 1)
    end
    out
end

function _decode_utf8(a::_AA)
    n = Int(a.length)
    off = Int(a.offset)
    offs = unsafe_wrap(Array, Ptr{Int32}(unsafe_load(a.buffers, 2)), n + off + 1; own=false)
    bytes = Ptr{UInt8}(unsafe_load(a.buffers, 3))
    valid = _validity(a)
    out = valid == C_NULL ? Vector{String}(undef, n) : Vector{Union{Missing,String}}(undef, n)
    @inbounds for i in 1:n
        if valid != C_NULL && !_bit(valid, off + i - 1)
            out[i] = missing
        else
            lo = Int(offs[off + i])
            hi = Int(offs[off + i + 1])
            out[i] = unsafe_string(bytes + lo, hi - lo)
        end
    end
    out
end

function _decode_list(s::_AS, a::_AA, batch::_Batch)
    n = Int(a.length)
    off = Int(a.offset)
    offs = unsafe_wrap(Array, Ptr{Int32}(unsafe_load(a.buffers, 2)), n + off + 1; own=false)
    inner = _decode(unsafe_load(s.children, 1), unsafe_load(a.children, 1), batch)
    valid = _validity(a)
    ET = Vector{eltype(inner)}
    out = valid == C_NULL ? Vector{ET}(undef, n) : Vector{Union{Missing,ET}}(undef, n)
    @inbounds for i in 1:n
        if valid != C_NULL && !_bit(valid, off + i - 1)
            out[i] = missing
        else
            out[i] = inner[(Int(offs[off + i]) + 1):Int(offs[off + i + 1])]
        end
    end
    out
end

function _decode_fixedlist(s::_AS, a::_AA, batch::_Batch, k::Int)
    n = Int(a.length)
    off = Int(a.offset)
    inner = _decode(unsafe_load(s.children, 1), unsafe_load(a.children, 1), batch)
    valid = _validity(a)
    ET = Vector{eltype(inner)}
    out = valid == C_NULL ? Vector{ET}(undef, n) : Vector{Union{Missing,ET}}(undef, n)
    @inbounds for i in 1:n
        if valid != C_NULL && !_bit(valid, off + i - 1)
            out[i] = missing
        else
            base = (off + i - 1) * k
            out[i] = inner[(base + 1):(base + k)]
        end
    end
    out
end

# Empty typed column matching a schema child's format (for zero-row results).
function _empty_col(cs::Ptr{_AS})
    s = unsafe_load(cs)
    s.dictionary == C_NULL ||
        error("rerun query: dictionary-encoded column $(repr(_sname(cs))) not supported")
    fmt = unsafe_string(s.format)
    haskey(_PRIM, fmt) && return (_PRIM[fmt])[]
    fmt == "b" && return Bool[]
    fmt == "u" && return String[]
    if fmt == "+l" || startswith(fmt, "+w:")
        return Vector{eltype(_empty_col(unsafe_load(s.children, 1)))}[]
    end
    st = _temporal_storage(fmt)
    st === nothing || return st[]
    error("rerun query: unsupported Arrow column type $(repr(fmt)) (column $(repr(_sname(cs))))")
end

function _empty_batch(schema_ptr::Ptr{_AS})
    s = unsafe_load(schema_ptr)
    names = Vector{Symbol}(undef, s.n_children)
    cols = Vector{AbstractVector}(undef, s.n_children)
    for i in 1:s.n_children
        cs = unsafe_load(s.children, i)
        names[i] = Symbol(_sname(cs))
        cols[i] = _empty_col(cs)
    end
    ColumnBatch(names, cols)
end

# ---------------------------------------------------------------------------
# Tables.jl source
# ---------------------------------------------------------------------------
struct ColumnBatch
    names::Vector{Symbol}
    cols::Vector{AbstractVector}
end
Tables.istable(::Type{ColumnBatch}) = true
Tables.columnaccess(::Type{ColumnBatch}) = true
Tables.columns(t::ColumnBatch) = t
Tables.columnnames(t::ColumnBatch) = t.names
Tables.getcolumn(t::ColumnBatch, i::Int) = t.cols[i]
function Tables.getcolumn(t::ColumnBatch, nm::Symbol)
    i = findfirst(==(nm), t.names)
    i === nothing && throw(KeyError(nm))
    t.cols[i]
end
Tables.schema(t::ColumnBatch) = Tables.Schema(t.names, map(eltype, t.cols))

"Result of [`select`](@ref): a Tables.jl column source, one partition per batch."
mutable struct QueryResult
    partitions::Vector{ColumnBatch}
    materialized::Union{Nothing,ColumnBatch}
    QueryResult(partitions::Vector{ColumnBatch}) = new(partitions, nothing)
end
Tables.istable(::Type{QueryResult}) = true
Tables.columnaccess(::Type{QueryResult}) = true
Tables.partitions(qr::QueryResult) = qr.partitions
Tables.columns(qr::QueryResult) = _materialize(qr)
Tables.columnnames(qr::QueryResult) =
    isempty(qr.partitions) ? Symbol[] : copy(qr.partitions[1].names)
Tables.getcolumn(qr::QueryResult, x) = Tables.getcolumn(_materialize(qr), x)
function Tables.schema(qr::QueryResult)
    isempty(qr.partitions) && return nothing
    names = qr.partitions[1].names
    # Reflect the materialized eltypes: nullability can vary across batches.
    types = Type[mapreduce(p -> eltype(p.cols[j]), promote_type, qr.partitions)
                 for j in eachindex(names)]
    Tables.Schema(names, types)
end

function _materialize(qr::QueryResult)
    qr.materialized === nothing || return qr.materialized
    qr.materialized = if length(qr.partitions) <= 1
        isempty(qr.partitions) ? ColumnBatch(Symbol[], AbstractVector[]) : qr.partitions[1]
    else
        names = qr.partitions[1].names
        cols = AbstractVector[reduce(vcat, (p.cols[j] for p in qr.partitions)) for j in eachindex(names)]
        ColumnBatch(names, cols)
    end
end

function _decode_batch(schema_ptr::Ptr{_AS}, batch::_Batch)
    s = unsafe_load(schema_ptr)
    a = batch.ref[]
    names = Vector{Symbol}(undef, s.n_children)
    cols = Vector{AbstractVector}(undef, s.n_children)
    for i in 1:s.n_children
        cs = unsafe_load(s.children, i)
        names[i] = Symbol(_sname(cs))
        cols[i] = _decode(cs, unsafe_load(a.children, i), batch)
    end
    ColumnBatch(names, cols)
end

"""
    select(view) -> QueryResult

Run the query and eagerly collect all result batches into a Tables.jl source.
Scalar/primitive columns (the index and other non-list columns) alias the
underlying buffers zero-copy; list-valued component columns are decoded by copy.

Zero-copy aliasing is preserved only for a single-batch result: a result split
into several batches is concatenated into fresh columns by `Tables.columns` (and
thus `DataFrame`), regardless of `copycols`. For guaranteed per-batch zero-copy
over a large result, iterate `Tables.partitions` instead.
"""
function select(v::RecordingView)
    err = Ref(_RrqError())
    reader = ccall((:rrq_engine_select, _LIB), Ptr{Cvoid},
        (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{_RrqError}), v.rec.ptr, v.ptr, err)
    reader == C_NULL && _check(err, "select")
    try
        schema_ptr = ccall((:rrq_reader_schema, _LIB), Ptr{_AS}, (Ptr{Cvoid},), reader)
        parts = ColumnBatch[]
        while true
            ref = Ref(_empty_aa())
            rc = ccall((:rrq_reader_next, _LIB), Cint,
                (Ptr{Cvoid}, Ptr{_AA}, Ptr{_RrqError}), reader, ref, err)
            rc < 0 && _check(err, "reader_next")
            rc == 1 && break
            batch = _Batch(ref)   # attach the release finalizer before any other work
            push!(parts, _decode_batch(schema_ptr, batch))
        end
        # Preserve the known schema even when no rows matched.
        isempty(parts) && push!(parts, _empty_batch(schema_ptr))
        QueryResult(parts)
    finally
        ccall((:rrq_reader_free, _LIB), Cvoid, (Ptr{Cvoid},), reader)
    end
end
