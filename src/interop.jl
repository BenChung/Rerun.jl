# BYO-type interop: traits and materialization that map foreign element types
# onto components. Every resolution step is an explicit declaration; memory
# layout is never inspected:
#
#   1. `eltype <: C`          pass through (already materialized)
#   2. `wire_compatible(T,C)` validated zero-copy pass-through
#   3. constructor `C(::T)`   converting copy
#
# The docs page "Interop" documents the user-facing contract.

"""
    InteropError <: Exception

Raised when a vector cannot be materialized as a component batch: a missing
[`Rerun.component`](@ref) mapping, a missing or failing constructor, or an
invalid [`Rerun.wire_compatible`](@ref) declaration. The message names the
declaration that fixes it.
"""
struct InteropError <: Exception
    message::String
end
Base.showerror(io::IO, e::InteropError) = print(io, "InteropError: ", e.message)

"""
    Rerun.component(::Type{T}) -> Type{<:Component} or nothing

Trait: the component that `Vector{T}` logs as. Declaring it enables the bare
vector form `Rerun.log(rec, path, data)`. Pair it with the value mapping: a
constructor method `C(::T)`, or a [`Rerun.wire_compatible`](@ref) declaration
when the layouts already match:

    Rerun.component(::Type{Waypoint}) = Position3D
    Rerun.Components.Position3D(w::Waypoint) = Position3D((w.lon, w.lat, w.alt))

Defaults to `nothing`: no mapping.
"""
component(::Type) = nothing

# The component's storage type (all generated components wrap one field).
_wiretype(::Type{C}) where {C<:Component} = fieldcount(C) == 1 ? fieldtype(C, 1) : Union{}

"""
    Rerun.wire_compatible(::Type{T}, ::Type{C}) -> Bool

Trait: declares that `T`'s memory layout is exactly the wire layout of the
flat component `C`, so a `Vector{T}` logs as a `C` batch zero-copy:

    Rerun.wire_compatible(::Type{XYZ}, ::Type{Position3D}) = true

Every use validates the declaration: `T` must be isbits and exactly as wide
as `C`. The checks are compile-time facts about the two types, so they compile
away in type-stable code. Defaults to `true` for `C`'s own storage type (e.g.
`NTuple{3,Float32}` for `Position3D`) and `false` for everything else.
"""
wire_compatible(::Type{T}, ::Type{C}) where {T,C<:Component} = T === _wiretype(C)

"""
    _materialize(C, data) -> AbstractVector

Resolve `data` into a batch of the component `C`:

- `C` elements (and `missing`) pass through.
- A [`wire_compatible`](@ref Rerun.wire_compatible) element type passes
  through zero-copy, after validating the declaration.
- Any other element type converts through the `C(::T)` constructor, a copy.

A failing conversion throws [`InteropError`](@ref) naming the declaration to add.
"""
_materialize(::Type{C}, data::AbstractVector{<:Union{C,Missing}}) where {C<:Component} = data

# A batch of a different component errors: converting between components would
# mask a mixed-up argument.
_materialize(::Type{C}, data::AbstractVector{<:Union{Component,Missing}}) where {C<:Component} =
    throw(InteropError(
        "expected a $C batch, but $(Base.nonmissingtype(eltype(data))) is a different component"))

function _materialize(::Type{C}, data::AbstractVector) where {C<:Component}
    T = Base.nonmissingtype(eltype(data))
    wire_compatible(T, C) || return _construct_batch(C, data)
    _validate_wire(T, C)
    return data
end

# A wire_compatible declaration is a claim; check it before aliasing memory.
# The checks are pure functions of the two types, so the compiler removes them
# from type-stable paths. `C`'s own storage type is identical by construction
# and skips them.
function _validate_wire(::Type{T}, ::Type{C}) where {T,C<:Component}
    T === _wiretype(C) && return
    isbitstype(C) || throw(InteropError(
        "wire_compatible declarations apply to flat components; $C is not one"))
    isbitstype(T) || throw(InteropError(
        "$T is declared wire-compatible with $C, but is not isbits"))
    sizeof(T) == sizeof(C) || throw(InteropError(
        "$T is declared wire-compatible with $C, but sizeof($T) = $(sizeof(T)) bytes " *
        "and $C's wire element is $(sizeof(C)) bytes"))
    return
end

# Converting copy through the `C(::T)` constructor, preserving `missing`.
_construct_batch(::Type{C}, data::AbstractVector{T}) where {C<:Component,T>:Missing} =
    _rescue_construct(C, data) do
        Union{C,Missing}[x === missing ? missing : C(x)::C for x in data]
    end
_construct_batch(::Type{C}, data::AbstractVector) where {C<:Component} =
    _rescue_construct(C, data) do
        C[C(x)::C for x in data]
    end

# The fast path is the plain comprehension; on failure, rescan to name the
# offending element and chain the original exception underneath.
function _rescue_construct(f, ::Type{C}, data::AbstractVector) where {C<:Component}
    try
        return f()
    catch
        for (i, x) in pairs(data)
            x === missing && continue
            try
                C(x)::C
            catch
                throw(InteropError(
                    "converting element $i (::$(typeof(x))) to $C failed; " *
                    "define Rerun.Components.$(nameof(C))(x::$(typeof(x))) = ... to map it, " *
                    "or Rerun.wire_compatible(::Type{$(typeof(x))}, ::Type{$(nameof(C))}) = true " *
                    "if its memory layout is exactly $C's wire layout"))
            end
        end
        rethrow()
    end
end

"""
    log(rec, entity_path, data::AbstractVector)

Trait-driven form: log a vector of any type with a declared
[`Rerun.component`](@ref) mapping, e.g. `log(rec, "route", waypoints)`.
A [`Rerun.wire_compatible`](@ref) declaration logs the batch zero-copy; the
component's constructor converts every other element type (a copy).
"""
function log(r::RecordingStream, entity_path::AbstractString, data::AbstractVector;
             inject_time::Bool=true)
    T = Base.nonmissingtype(eltype(data))
    C = component(T)
    C === nothing && throw(InteropError(
        "no component mapping for $T.\n" *
        "To log Vector{$T}, declare its component and how to build it:\n" *
        "  Rerun.component(::Type{$T}) = <Component>\n" *
        "  Rerun.Components.<Component>(x::$T) = ...\n" *
        "Or name the component at the call site: Rerun.log(rec, path, Component, data)."))
    return log(r, entity_path, C, data; inject_time=inject_time)
end

# --- materialization by registered handle -----------------------------------
#
# The archetype, catalog-name, and column paths carry only a component handle
# and Arrow type, so materialization there resolves the component struct from
# the handle. `_handle` records handle -> component-type string at
# registration; the string maps to the generated struct by reflection over
# `Components`.

const _CTYPE_STRUCTS = Ref{Union{Nothing,Dict{String,Any}}}(nothing)

function _struct_for_ctype(ct::AbstractString)
    m = _CTYPE_STRUCTS[]
    if m === nothing
        m = Dict{String,Any}()
        for n in names(Components)
            v = getproperty(Components, n)
            (v isa DataType && v <: Component && isconcretetype(v)) || continue
            m[componenttype(v)] = v
        end
        _CTYPE_STRUCTS[] = m
    end
    return get(m, ct, nothing)
end

function _struct_for_handle(h)
    ct = lock(_HANDLES_LOCK) do
        get(_HANDLE_CTYPES, h, nothing)
    end
    ct === nothing && return nothing
    return _struct_for_ctype(ct)
end

# Component batches pass straight through; foreign eltypes resolve the struct
# and materialize. Components with no generated struct (bool and struct
# layouts) pass through to the assembled builder.
_materialize_handle(h, data::AbstractVector{<:Union{Component,Missing}}) = data

function _materialize_handle(h, data::AbstractVector)
    C = _struct_for_handle(h)
    C === nothing && return data
    return _materialize(C, data)
end
