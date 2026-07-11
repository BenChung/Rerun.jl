# ArrowType <-> Arrow C Data Interface schema structs (LibRerunC.ArrowSchema).
#
# One home for both directions of schema interop, so the export and import
# paths speak the same arrow_types.jl algebra:
#   * build (export): catalog ArrowType -> malloc'd ArrowSchema, owned by
#     _OwnedSchema until component-type registration (stream.jl) hands it to
#     rerun; the release callback frees the malloc'd C memory only (it
#     references no Julia data).
#   * parse (import): ArrowSchema lent by librerun_query -> ArrowType, driving
#     the dataframe batch decode (query.jl).

const _AS = LibRerunC.ArrowSchema
const _AA = LibRerunC.ArrowArray

const ARROW_FLAG_NULLABLE = Int64(2)

"""
    _OwnedSchema(t::ArrowType, name, nullable)

A malloc'd Arrow C Data Interface schema tree with a Julia-side owner. The
constructor builds the tree — GC-invisible memory, because rerun's `release`
call is the only doneness signal and may come from any thread — and `_take!`
transfers ownership to rerun. Every node embeds `_release_schema` as its
release callback, so the tree is freed by rerun after `_take!`, or by the
finalizer for a tree never handed off.
"""
mutable struct _OwnedSchema
    schema::LibRerunC.ArrowSchema
    consumed::Bool
    function _OwnedSchema(t::ArrowType, name::AbstractString, nullable::Bool)
        function build(t::ArrowType, name::AbstractString, nullable::Bool)
            children = arrow_children(t)
            nc = length(children)
            childptr = Ptr{Ptr{LibRerunC.ArrowSchema}}(C_NULL)
            if nc > 0
                childptr = Ptr{Ptr{LibRerunC.ArrowSchema}}(Libc.malloc(sizeof(Ptr) * nc))
                for (i, f) in enumerate(children)
                    cp = Ptr{LibRerunC.ArrowSchema}(Libc.malloc(sizeof(LibRerunC.ArrowSchema)))
                    unsafe_store!(cp, build(f.type, f.name, f.nullable))
                    unsafe_store!(childptr, cp, i)
                end
            end
            flags = nullable ? ARROW_FLAG_NULLABLE : Int64(0)
            return LibRerunC.ArrowSchema(_cstr(arrow_format(t)), _cstr(name), Ptr{Cchar}(C_NULL),
                flags, Int64(nc), childptr, Ptr{LibRerunC.ArrowSchema}(C_NULL), _SCHEMA_RELEASE[], C_NULL)
        end
        os = new(build(t, name, nullable), false)
        finalizer(os) do x
            x.consumed || _release_unconsumed(x.schema)
        end
        return os
    end
end

"""Transfer ownership of the C schema to the caller, for handing to rerun —
which releases it on both successful and failed registration."""
function _take!(os::_OwnedSchema)
    os.consumed = true
    return os.schema
end

# The release callback embedded in every node of an _OwnedSchema tree: frees
# the node's malloc'd format/name/children (recursing through children rerun
# has not already released) and marks the node released. Pure C — rerun may
# invoke it from any thread.
const _SCHEMA_RELEASE = Ref{Ptr{Cvoid}}(C_NULL)   # @cfunction ptr, set in _init_schema_release

function _release_schema(p::Ptr{LibRerunC.ArrowSchema})::Cvoid
    s = unsafe_load(p)
    s.release == C_NULL && return
    for i in 1:s.n_children
        cp = unsafe_load(s.children, i)
        c = unsafe_load(cp)
        c.release != C_NULL && ccall(c.release, Cvoid, (Ptr{LibRerunC.ArrowSchema},), cp)
        Libc.free(cp)
    end
    s.n_children > 0 && Libc.free(s.children)
    Libc.free(s.format)
    s.name != C_NULL && Libc.free(s.name)
    unsafe_store!(p, _with_schema_released(s))
    return
end

_with_schema_released(s::LibRerunC.ArrowSchema) = LibRerunC.ArrowSchema(
    s.format, s.name, s.metadata, s.flags, s.n_children, s.children, s.dictionary, C_NULL, s.private_data)

# Finalizer path: invoke the tree's own release callback for a schema rerun
# never took ownership of (after hand-off this would double-free).
function _release_unconsumed(s::LibRerunC.ArrowSchema)
    s.release == C_NULL && return
    ref = Ref(s)
    GC.@preserve ref ccall(s.release, Cvoid, (Ptr{LibRerunC.ArrowSchema},),
                           Base.unsafe_convert(Ptr{LibRerunC.ArrowSchema}, ref))
    return
end

# Compile + install the release callback before any foreign thread could
# invoke it (mirrors _init_callbacks in cdata.jl; called from __init__).
function _init_schema_release()
    precompile(_release_schema, (Ptr{LibRerunC.ArrowSchema},))
    _SCHEMA_RELEASE[] = @cfunction(_release_schema, Cvoid, (Ptr{LibRerunC.ArrowSchema},))
    return
end

# Import-side inverse of `arrow_format`; unsupported column layouts error with the column name before the first batch is pulled.

_sname(p::Ptr{_AS}) = (s = unsafe_load(p); s.name == C_NULL ? "" : unsafe_string(s.name))

"""Nanosecond-resolution temporal column layout (rerun's index timelines):
`kind ∈ (:timestamp, :duration)`, i64 storage on the wire, decoded losslessly
as [`TimePoint`](@ref) / `Nanosecond`."""
struct ArrowTemporal <: ArrowType
    kind::Symbol
end
_summ(t::ArrowTemporal) = String(t.kind)

# Nanosecond timeline formats parse to ArrowTemporal (typed, lossless decode);
# other temporal units decode as their raw integer storage.
function _temporal_atom(fmt::AbstractString)
    startswith(fmt, "tsn") && return ArrowTemporal(:timestamp) # timestamp[ns] (any timezone)
    fmt == "tDn" && return ArrowTemporal(:duration)            # duration[ns]
    startswith(fmt, "ts") && return ArrowAtom(:i64)            # timestamp s/ms/us
    startswith(fmt, "tD") && return ArrowAtom(:i64)            # duration s/ms/us
    fmt == "tdD" && return ArrowAtom(:i32)                     # date32 (days)
    fmt == "tdm" && return ArrowAtom(:i64)                     # date64 (ms)
    (fmt == "tts" || fmt == "ttm") && return ArrowAtom(:i32)   # time32
    (fmt == "ttu" || fmt == "ttn") && return ArrowAtom(:i64)   # time64
    return nothing
end

function _parse_column(cs::Ptr{_AS})
    s = unsafe_load(cs)
    s.dictionary == C_NULL ||
        error("rerun query: dictionary-encoded column $(repr(_sname(cs))) not supported")
    fmt = unsafe_string(s.format)
    tag = get(_FORMAT_ATOM, fmt, nothing)
    tag === nothing || tag === :null || return ArrowAtom(tag)
    t = _temporal_atom(fmt)
    t === nothing || return t
    fmt == "u" && return ArrowUtf8()
    fmt == "+l" && return ArrowList(_parse_item(cs, s))
    startswith(fmt, "+w:") && return ArrowFixedList(_parse_item(cs, s), parse(Int, fmt[4:end]))
    error("rerun query: unsupported Arrow column type $(repr(fmt)) (column $(repr(_sname(cs))))")
end

function _parse_item(cs::Ptr{_AS}, s::_AS)
    s.n_children == 1 ||
        error("rerun query: list column $(repr(_sname(cs))) has $(s.n_children) children")
    cp = unsafe_load(s.children, 1)
    nullable = (unsafe_load(cp).flags & ARROW_FLAG_NULLABLE) != 0
    return ArrowField(_sname(cp), _parse_column(cp), nullable)
end

# Column names + parsed column types of a struct-of-columns schema's children.
function _parse_schema(schema_ptr::Ptr{_AS})
    s = unsafe_load(schema_ptr)
    names = Vector{Symbol}(undef, s.n_children)
    types = Vector{ArrowType}(undef, s.n_children)
    for i in 1:s.n_children
        cs = unsafe_load(s.children, i)
        names[i] = Symbol(_sname(cs))
        types[i] = _parse_column(cs)
    end
    return names, types
end
