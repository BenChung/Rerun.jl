# Arrow C Data Interface export.
#
# Schema comes from the generated catalog (authoritative); array buffers point
# directly into caller-owned Julia memory (ZERO COPY) for the primitive and
# fixed-size-list-of-primitive component layouts. Only small C bookkeeping
# (the buffers/children pointer arrays and child structs) is malloc'd.
#
# Ownership / lifetime (validated empirically):
#   * `rr_register_component_type` releases the schema synchronously on the
#     calling thread -> the schema release callback just frees its malloc'd C
#     memory (it references no Julia data).
#   * `rr_recording_stream_log` releases the array ASYNCHRONOUSLY on a rerun
#     background thread. The array release callback must therefore be pure C
#     (no Julia runtime): it frees the malloc'd bookkeeping and flips a flag in
#     `private_data`. A Julia-side drain (`_drain_exports`, called on every
#     stream API entry) then drops the GC root keeping the data alive. A late
#     un-root is harmless because rerun is already done with the buffers.

const ARROW_FLAG_NULLABLE = Int64(2)

const _ATOM_SIZE = Dict(
    :bool=>1, :i8=>1, :u8=>1, :i16=>2, :u16=>2, :f16=>2,
    :i32=>4, :u32=>4, :f32=>4, :i64=>8, :u64=>8, :f64=>8,
)

# Bytes occupied by one top-level element of `t` in the contiguous wire buffer.
_wire_elsize(t::ArrowAtom)      = _ATOM_SIZE[t.tag]
_wire_elsize(t::ArrowFixedList) = t.n * _wire_elsize(t.item.type)
_wire_elsize(t::ArrowType)      = error("$(typeof(t)) has no flat wire layout (assembled bucket)")

# ---------------------------------------------------------------------------
# release callbacks (set in __init__)
# ---------------------------------------------------------------------------
const _ARRAY_RELEASE  = Ref{Ptr{Cvoid}}(C_NULL)
const _SCHEMA_RELEASE = Ref{Ptr{Cvoid}}(C_NULL)

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

function _release_array(p::Ptr{LibRerunC.ArrowArray})::Cvoid
    a = unsafe_load(p)
    a.release == C_NULL && return
    for i in 1:a.n_children
        cp = unsafe_load(a.children, i)
        c = unsafe_load(cp)
        c.release != C_NULL && ccall(c.release, Cvoid, (Ptr{LibRerunC.ArrowArray},), cp)
        Libc.free(cp)
    end
    a.n_buffers  > 0 && Libc.free(a.buffers)     # frees the pointer array, NOT zero-copy data
    a.n_children > 0 && Libc.free(a.children)
    if a.private_data != C_NULL
        # private_data is this export's stable released-flag (one Int). Release-
        # ordered store so the drain's acquire-load observes the Libc.free's above.
        # Pure atomic instruction — no Julia runtime/allocation, safe on the
        # foreign (rerun) thread.
        Core.Intrinsics.atomic_pointerset(Ptr{Int}(a.private_data), 1, :release)
    end
    unsafe_store!(p, _with_array_released(a))
    return
end

# Release for ASSEMBLED nodes: every buffer is malloc'd-and-owned (offsets,
# packed bits, copied bytes/values), so free the buffer DATA too. Fully C-owned
# — no Julia root, no registry/drain. Pure C; safe on the foreign thread.
const _ARRAY_RELEASE_OWNED = Ref{Ptr{Cvoid}}(C_NULL)
function _release_array_owned(p::Ptr{LibRerunC.ArrowArray})::Cvoid
    a = unsafe_load(p)
    a.release == C_NULL && return
    for i in 1:a.n_children
        cp = unsafe_load(a.children, i)
        c = unsafe_load(cp)
        c.release != C_NULL && ccall(c.release, Cvoid, (Ptr{LibRerunC.ArrowArray},), cp)
        Libc.free(cp)
    end
    for i in 1:a.n_buffers
        Libc.free(unsafe_load(a.buffers, i))     # free the owned data buffer (free(NULL) is a no-op)
    end
    a.n_buffers  > 0 && Libc.free(a.buffers)
    a.n_children > 0 && Libc.free(a.children)
    unsafe_store!(p, _with_array_released(a))
    return
end

# immutable-struct field updates
_with_schema_released(s::LibRerunC.ArrowSchema) = LibRerunC.ArrowSchema(
    s.format, s.name, s.metadata, s.flags, s.n_children, s.children, s.dictionary, C_NULL, s.private_data)
_with_array_released(a::LibRerunC.ArrowArray) = LibRerunC.ArrowArray(
    a.length, a.null_count, a.offset, a.n_buffers, a.n_children, a.buffers, a.children, a.dictionary, C_NULL, a.private_data)
_with_array_private(a::LibRerunC.ArrowArray, priv::Ptr{Cvoid}) = LibRerunC.ArrowArray(
    a.length, a.null_count, a.offset, a.n_buffers, a.n_children, a.buffers, a.children, a.dictionary, a.release, priv)

# ---------------------------------------------------------------------------
# schema builder (from catalog ArrowType) -> ArrowSchema value
# ---------------------------------------------------------------------------
function _build_schema(t::ArrowType, name::AbstractString, nullable::Bool)
    children = arrow_children(t)
    nc = length(children)
    childptr = Ptr{Ptr{LibRerunC.ArrowSchema}}(C_NULL)
    if nc > 0
        childptr = Ptr{Ptr{LibRerunC.ArrowSchema}}(Libc.malloc(sizeof(Ptr) * nc))
        for (i, f) in enumerate(children)
            cp = Ptr{LibRerunC.ArrowSchema}(Libc.malloc(sizeof(LibRerunC.ArrowSchema)))
            unsafe_store!(cp, _build_schema(f.type, f.name, f.nullable))
            unsafe_store!(childptr, cp, i)
        end
    end
    flags = nullable ? ARROW_FLAG_NULLABLE : Int64(0)
    return LibRerunC.ArrowSchema(_cstr(arrow_format(t)), _cstr(name), Ptr{Cchar}(C_NULL),
        flags, Int64(nc), childptr, Ptr{LibRerunC.ArrowSchema}(C_NULL), _SCHEMA_RELEASE[], C_NULL)
end

# ---------------------------------------------------------------------------
# zero-copy array builder
# ---------------------------------------------------------------------------
function _build_array_node(t::ArrowAtom, n::Int, dataptr::Ptr{Cvoid},
                           validity::Ptr{Cvoid}=Ptr{Cvoid}(C_NULL), null_count::Integer=0)
    t.tag === :bool && error("bool components are bit-packed (assembled bucket), not zero-copy")
    bufs = Ptr{Ptr{Cvoid}}(Libc.malloc(2 * sizeof(Ptr)))
    unsafe_store!(bufs, validity, 1)             # validity bitmap (NULL when no missing)
    unsafe_store!(bufs, dataptr, 2)              # values (zero-copy)
    return LibRerunC.ArrowArray(n, null_count, 0, 2, 0, bufs,
        Ptr{Ptr{LibRerunC.ArrowArray}}(C_NULL), Ptr{LibRerunC.ArrowArray}(C_NULL), _ARRAY_RELEASE[], C_NULL)
end

function _build_array_node(t::ArrowFixedList, n::Int, dataptr::Ptr{Cvoid},
                           validity::Ptr{Cvoid}=Ptr{Cvoid}(C_NULL), null_count::Integer=0)
    # validity lives on the list level; the child's elements are never individually null
    cp = Ptr{LibRerunC.ArrowArray}(Libc.malloc(sizeof(LibRerunC.ArrowArray)))
    unsafe_store!(cp, _build_array_node(t.item.type, n * t.n, dataptr))
    kids = Ptr{Ptr{LibRerunC.ArrowArray}}(Libc.malloc(sizeof(Ptr)))
    unsafe_store!(kids, cp, 1)
    bufs = Ptr{Ptr{Cvoid}}(Libc.malloc(sizeof(Ptr)))
    unsafe_store!(bufs, validity, 1)
    return LibRerunC.ArrowArray(n, null_count, 0, 1, 1, bufs, kids, Ptr{LibRerunC.ArrowArray}(C_NULL), _ARRAY_RELEASE[], C_NULL)
end

_build_array_node(t::ArrowType, n, dataptr) =
    error("zero-copy export not implemented for $(typeof(t)) (assembled bucket)")

# ---------------------------------------------------------------------------
# GC-root registry for zero-copy data, drained off the async release flag.
#
# A pooled slot design: each in-flight export occupies a "slot" that keeps its
# data rooted (`_ROOTS[slot]`) and owns a stable released-flag (`_FLAGS[slot]`,
# one malloc'd Int, embedded as the array's private_data). Slots are recycled
# via a free-list, and flag blocks are never freed (their addresses must stay
# valid for in-flight async releases), so a steady-state log allocates nothing
# here once the pool reaches its high-water mark.
# ---------------------------------------------------------------------------
const _ROOTS = Any[]                 # _ROOTS[slot] = rooted data, or `nothing` if free
const _FLAGS = Ptr{Int}[]            # _FLAGS[slot] = stable malloc'd released-flag
const _FREE  = Int[]                 # stack of free slot indices
const _REG_LOCK = ReentrantLock()

"""Root `data` and return its stable released-flag pointer (the array's `private_data`)."""
function _register_root!(data)
    lock(_REG_LOCK)
    try
        if isempty(_FREE)
            push!(_ROOTS, data)
            p = Ptr{Int}(Libc.malloc(sizeof(Int)))
            push!(_FLAGS, p)
        else
            slot = pop!(_FREE)
            @inbounds _ROOTS[slot] = data
            @inbounds p = _FLAGS[slot]
        end
        unsafe_store!(p, 0)          # released = 0 (single-threaded: set before the array is published)
        return p
    finally
        unlock(_REG_LOCK)
    end
end

"""Drop GC roots for any exports rerun has released. Safe to call frequently; 0-alloc."""
function _drain_exports()
    isempty(_ROOTS) && return
    lock(_REG_LOCK)
    try
        @inbounds for slot in 1:length(_ROOTS)
            _ROOTS[slot] === nothing && continue
            if Core.Intrinsics.atomic_pointerref(_FLAGS[slot], :acquire) != 0
                _ROOTS[slot] = nothing       # recycle only after observing release -> no late writes
                push!(_FREE, slot)
            end
        end
    finally
        unlock(_REG_LOCK)
    end
    return
end

# A flat (zero-copy-eligible) layout: primitive or fixed-size-list thereof.
_is_flat(t::ArrowAtom)      = t.tag !== :bool && t.tag !== :null
_is_flat(t::ArrowFixedList) = _is_flat(t.item.type)
_is_flat(::ArrowType)       = false

"""
    _build_component_array(t, data) -> ArrowArray

For a flat layout whose element type matches, build a ZERO-COPY array pointing
into `data` (kept alive via the registry until rerun releases it). Otherwise
build an ASSEMBLED array: buffers malloc'd-and-copied, freed by the owned
release on rerun's thread — no Julia root, nothing points into `data`.
"""
# Build an Arrow validity bitmap (1 bit/elem, 1=valid) for a possibly-`missing`
# vector, or `(nothing, 0)` when the element type can't be `missing`. The
# `Missing <: eltype` test is resolved at compile time, so non-missing data pays
# nothing and the bitmap is the only allocation (n/8 bytes) when missings exist.
function _validity_bitmap(data::AbstractVector)
    Missing <: eltype(data) || return (nothing, 0)
    n = length(data)
    bm = fill(0xff, cld(n, 8))
    nc = 0
    @inbounds for i in 1:n
        if data[i] === missing
            nc += 1
            bm[((i - 1) >> 3) + 1] &= ~(UInt8(1) << ((i - 1) & 7))
        end
    end
    return (bm, nc)
end

function _build_component_array(t::ArrowType, data::AbstractVector)
    if _is_flat(t)
        # Flat layout: require an exactly-matching isbits element (ignoring an
        # optional `Missing`) so we can hand rerun a pointer into `data`
        # (zero-copy). A wrong-width element is a caller error, not an invitation
        # to silently convert. Validation precedes _register_root!, so a rejected
        # call leaves no dangling entry; rerun then owns/releases the array.
        T = Base.nonmissingtype(eltype(data))
        isbitstype(T) || error("component data eltype $(eltype(data)) must be isbits")
        sizeof(T) == _wire_elsize(t) || error("element-size mismatch: $T is $(sizeof(T)) bytes, " *
                                              "component layout expects $(_wire_elsize(t)) bytes/element")
        bm, nc = _validity_bitmap(data)                         # values stay zero-copy; only the bitmap allocates
        vptr = bm === nothing ? Ptr{Cvoid}(C_NULL) : Ptr{Cvoid}(pointer(bm))
        top = _build_array_node(t, length(data), Ptr{Cvoid}(pointer(data)), vptr, nc)
        root = bm === nothing ? data : (data, bm)              # keep the bitmap alive too
        return _with_array_private(top, Ptr{Cvoid}(_register_root!(root)))
    end
    return _assembled(t, data)   # non-flat: utf8 / binary / list / struct / bool
end

# ---------------------------------------------------------------------------
# assembled (non-zero-copy) builders: malloc + copy into Arrow buffers; the
# owned release frees them. Covers utf8/binary, list, struct, bool, and (for
# list/struct children) copied primitives.
# ---------------------------------------------------------------------------
const _ATOM_JULIA = Dict(:i8=>Int8, :u8=>UInt8, :i16=>Int16, :u16=>UInt16, :i32=>Int32,
    :u32=>UInt32, :i64=>Int64, :u64=>UInt64, :f16=>Float16, :f32=>Float32, :f64=>Float64)

_mbuf(n) = Ptr{Cvoid}(Libc.malloc(max(n, 1)))
function _buffers(ptrs::Ptr{Cvoid}...)            # malloc a buffer-pointer array
    arr = Ptr{Ptr{Cvoid}}(Libc.malloc(sizeof(Ptr) * length(ptrs)))
    for (i, p) in enumerate(ptrs); unsafe_store!(arr, p, i); end
    return arr
end
_owned_array(len, nbuf, bufs, nchild, kids) = LibRerunC.ArrowArray(
    len, 0, 0, nbuf, nchild, bufs, kids, Ptr{LibRerunC.ArrowArray}(C_NULL), _ARRAY_RELEASE_OWNED[], C_NULL)
function _child_ptr(node::LibRerunC.ArrowArray)   # malloc a child ArrowArray struct
    cp = Ptr{LibRerunC.ArrowArray}(Libc.malloc(sizeof(LibRerunC.ArrowArray)))
    unsafe_store!(cp, node)
    return cp
end

_nbytes(s::AbstractString) = ncodeunits(s)
_nbytes(v::AbstractVector{UInt8}) = length(v)

_assembled(t::ArrowType, data) = error("assembled export not implemented for $(typeof(t)) — " *
                                       "component layout $(_summ(t)) is not yet supported")

function _assembled(t::ArrowAtom, data::AbstractVector)
    # Null array (used by a union's `_null_markers` variant): no buffers, all-null.
    t.tag === :null && return LibRerunC.ArrowArray(length(data), length(data), 0, 0, 0,
        Ptr{Ptr{Cvoid}}(C_NULL), Ptr{Ptr{LibRerunC.ArrowArray}}(C_NULL), Ptr{LibRerunC.ArrowArray}(C_NULL),
        _ARRAY_RELEASE_OWNED[], C_NULL)
    t.tag === :bool && return _assembled_bool(data)
    T = _ATOM_JULIA[t.tag]
    n = length(data)
    vp = Ptr{T}(Libc.malloc(max(n * sizeof(T), 1)))
    @inbounds for i in 1:n; unsafe_store!(vp, convert(T, data[i]), i); end
    return _owned_array(n, 2, _buffers(C_NULL, Ptr{Cvoid}(vp)), 0, Ptr{Ptr{LibRerunC.ArrowArray}}(C_NULL))
end

function _assembled_bool(data::AbstractVector)
    n = length(data)
    bp = Ptr{UInt8}(Libc.calloc(max(cld(n, 8), 1), 1))
    @inbounds for i in 1:n
        if data[i]
            off = (i - 1) >> 3
            unsafe_store!(bp + off, unsafe_load(bp + off) | (UInt8(1) << ((i - 1) & 7)))
        end
    end
    return _owned_array(n, 2, _buffers(C_NULL, Ptr{Cvoid}(bp)), 0, Ptr{Ptr{LibRerunC.ArrowArray}}(C_NULL))
end

# utf8/binary: [validity, offsets(Int32, n+1), bytes]
function _assembled(::Union{ArrowUtf8,ArrowBinary}, data::AbstractVector)
    n = length(data)
    total = 0; for x in data; total += _nbytes(x); end
    offp = Ptr{Int32}(Libc.malloc((n + 1) * sizeof(Int32)))
    bufp = Ptr{UInt8}(_mbuf(total))
    unsafe_store!(offp, Int32(0), 1); acc = 0
    @inbounds for (i, x) in enumerate(data)
        nb = _nbytes(x)
        nb > 0 && GC.@preserve x unsafe_copyto!(bufp + acc, _byteptr(x), nb)
        acc += nb; unsafe_store!(offp, Int32(acc), i + 1)
    end
    return _owned_array(n, 3, _buffers(C_NULL, Ptr{Cvoid}(offp), Ptr{Cvoid}(bufp)), 0,
        Ptr{Ptr{LibRerunC.ArrowArray}}(C_NULL))
end
_byteptr(s::String) = pointer(s)
_byteptr(v::Vector{UInt8}) = pointer(v)
_byteptr(x) = pointer(Vector{UInt8}(codeunits(String(x))))   # fallback for other string/byte types

# list: [validity, offsets(Int32, n+1)] + 1 child (flattened items)
function _assembled(t::ArrowList, data::AbstractVector)
    n = length(data)
    offp = Ptr{Int32}(Libc.malloc((n + 1) * sizeof(Int32)))
    unsafe_store!(offp, Int32(0), 1); acc = 0
    @inbounds for (i, x) in enumerate(data); acc += length(x); unsafe_store!(offp, Int32(acc), i + 1); end
    flat = collect(Iterators.flatten(data))
    kids = Ptr{Ptr{LibRerunC.ArrowArray}}(Libc.malloc(sizeof(Ptr)))
    unsafe_store!(kids, _child_ptr(_assembled(t.item.type, flat)), 1)
    return _owned_array(n, 2, _buffers(C_NULL, Ptr{Cvoid}(offp)), 1, kids)
end

# struct: [validity] + one columnar child per field
function _assembled(t::ArrowStruct, data::AbstractVector)
    n = length(data); nc = length(t.fields)
    kids = Ptr{Ptr{LibRerunC.ArrowArray}}(Libc.malloc(sizeof(Ptr) * nc))
    for (j, f) in enumerate(t.fields)
        sym = Symbol(f.name)
        col = [getfield(x, sym) for x in data]
        unsafe_store!(kids, _child_ptr(_assembled(f.type, col)), j)
    end
    return _owned_array(n, 1, _buffers(C_NULL), nc, kids)
end

function _init_callbacks()
    # Force full compilation of both callbacks before any foreign (rerun
    # background) thread can invoke them, so no codegen/allocation happens on a
    # thread the Julia runtime didn't create. (@cfunction already compiles the
    # target; precompile is belt-and-suspenders for the single method signature.)
    precompile(_release_array,       (Ptr{LibRerunC.ArrowArray},))
    precompile(_release_array_owned, (Ptr{LibRerunC.ArrowArray},))
    precompile(_release_schema,      (Ptr{LibRerunC.ArrowSchema},))
    _ARRAY_RELEASE[]       = @cfunction(_release_array,       Cvoid, (Ptr{LibRerunC.ArrowArray},))
    _ARRAY_RELEASE_OWNED[] = @cfunction(_release_array_owned, Cvoid, (Ptr{LibRerunC.ArrowArray},))
    _SCHEMA_RELEASE[]      = @cfunction(_release_schema,      Cvoid, (Ptr{LibRerunC.ArrowSchema},))
    return
end

