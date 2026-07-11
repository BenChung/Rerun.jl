# Materialized Rerun types: concrete structs that double as data carriers and
# dispatch tags. The generated structs in `generated_types.jl` subtype these and
# provide the metadata methods below; the typed `log` methods then resolve the
# component identity from the *type* (const-folded), with no string lookup on
# the hot path.

abstract type Component end
abstract type Archetype end

# --- generated per concrete type ---
function componenttype end   # ::Type{<:Component} -> String   (e.g. "rerun.components.Position3D")
function arrowtype end        # ::Type{<:Component} -> ArrowType (a compile-time `const`)
function handleref end         # ::Type{<:Component} -> Ref{handle} (per-type registration cache)

# Register-once, then read the per-type handle cache (no Dict/lock on the hot path).
@inline function _component_handle(::Type{C}) where {C<:Component}
    ref = handleref(C)
    h = ref[]
    h == LibRerunC.RR_COMPONENT_TYPE_HANDLE_INVALID || return h
    ct = componenttype(C)
    h = _handle("", ct, ct, arrowtype(C))     # idempotent global registration
    ref[] = h
    return h
end

"""
    log(rec, entity_path, Component, data::AbstractVector)

Interop form: log any layout-compatible vector as the given component type, e.g.
`log(rec, "p", Position3D, pts::Vector{Point3f})`. Zero-copy when `data`'s
element layout matches the component's Arrow datatype.
"""
function log(r::RecordingStream, entity_path::AbstractString, ::Type{C},
             data::AbstractVector; inject_time::Bool=true) where {C<:Component}
    h = _component_handle(C)
    _log_tuple(r, entity_path, ((h, arrowtype(C), data),); inject_time=inject_time)
end

# Wire payload of a component batch (applied in `_build_component_array`). Flat
# components are already wire-shaped, so this is the identity (keeps the
# zero-copy path); carriers (e.g. Text/Blob) override it to unwrap their field
# (preserving `missing`).
_payload(::Type{<:Component}, v) = v
_unwrap(v, field::Symbol) = [x === missing ? missing : getfield(x, field) for x in v]

# Accept Vector{C} and Vector{Union{C,Missing}} alike; the component identity is
# the non-missing element type (resolved at compile time).
@inline function _component_spec(v::AbstractVector{<:Union{Component,Missing}})
    C = Base.nonmissingtype(eltype(v))
    return (_component_handle(C), arrowtype(C), v)
end

@generated function _component_specs(bs::Tuple)
    Expr(:tuple, [:(_component_spec(bs[$i])) for i in 1:length(bs.parameters)]...)
end

"""
    log(rec, entity_path, batch::AbstractVector{<:Component}...)

Log one or more materialized component batches as a single row, e.g.
`log(rec, "p", points)` or `log(rec, "p", points, colors)`. Identity comes from
each batch's element type, making the call type-specialized and zero-copy.
"""
log

# Fixed-arity overloads for 1..8 batches. A heterogeneous varargs tuple is
# materialized on the heap when it escapes into the spec build; fixed-arity
# methods keep the batch tuple on the stack, so these are 0-alloc. Larger counts
# fall back to the (rarely hot) varargs method below.
for _N in 1:8
    bs   = [Symbol(:b, i) for i in 1:_N]
    sigs = [:($(b)::AbstractVector{<:Union{Component,Missing}}) for b in bs]
    spcs = [:(_component_spec($(b))) for b in bs]
    @eval function log(r::RecordingStream, entity_path::AbstractString, $(sigs...); inject_time::Bool=true)
        _log_tuple(r, entity_path, ($(spcs...),); inject_time=inject_time)
    end
end

function log(r::RecordingStream, entity_path::AbstractString,
             batches::AbstractVector{<:Union{Component,Missing}}...; inject_time::Bool=true)
    isempty(batches) && throw(ArgumentError("log: provide at least one component batch"))
    _log_tuple(r, entity_path, _component_specs(batches); inject_time=inject_time)
end

# --- archetypes ---
#
# A materialized archetype is `Arch{NT<:NamedTuple} <: Archetype` holding the
# supplied fields in `fields::NT`. The NamedTuple's type encodes *presence*
# (absent optional fields are stored as `nothing`, i.e. typed `Nothing`) and the
# concrete data-carrier type per field. The component identity is fixed by the
# catalog, so it lives in generated per-field methods, not the type parameter.
function archetypename end       # ::Type{<:Archetype} -> String
function _arch_field_spec end     # (::Type{<:Archetype}, ::Val{field}, data) -> (handle, arrowtype, data)

# Register-once / read the per-(archetype,field) handle cache.
@inline function _cached_arch_handle(ref::Base.RefValue, arch, comp, ctype, t)
    h = ref[]
    h == LibRerunC.RR_COMPONENT_TYPE_HANDLE_INVALID || return h
    h = _handle(arch, comp, ctype, t)
    ref[] = h
    return h
end

# Emit a fixed tuple of specs for exactly the present (non-`Nothing`) fields.
# Generated from the NamedTuple type, so it unrolls to straight-line calls with
# literal field indices — fully type-stable and 0-alloc (no runtime symbol
# dispatch, no recursion).
@generated function _arch_specs(::Type{A}, nt::NamedTuple{names,T}) where {A<:Archetype,names,T}
    calls = Any[]
    for (i, nm) in enumerate(names)
        T.parameters[i] === Nothing && continue          # field not supplied -> drop at compile time
        push!(calls, :(_arch_field_spec(A, $(Val(nm)), nt[$i])))
    end
    return Expr(:tuple, calls...)
end

"""
    log(rec, entity_path, archetype::Archetype)

Log a materialized archetype as one row, e.g. `log(rec, "p", Points3D(pts; colors))`.
Each set field is logged under its archetype-qualified descriptor; the build is
type-stable and 0-alloc (the only cost is constructing the archetype itself).
"""
function log(r::RecordingStream, entity_path::AbstractString, a::A; inject_time::Bool=true) where {A<:Archetype}
    specs = _arch_specs(A, a.fields)
    isempty(specs) && error("$(archetypename(A)): no fields set")
    _log_tuple(r, entity_path, specs; inject_time=inject_time)
end
