# Resolved Arrow datatype model for Rerun components.
#
# This is a closed mirror of the `DataType` enum in Rerun's `re_types_builder`
# (crates/build/re_types_builder/src/data_type.rs). Instances are produced at
# codegen time by `gen/gen_schemas.jl` (which runs `flatc` over the vendored
# Rerun IDL and ports the `type_registry.rs` resolver) and emitted into
# `src/generated_schemas.jl`. Nothing here is hand-maintained per component.

abstract type ArrowType end

"""A named field of a struct/union, or the `item` of a list."""
struct ArrowField
    name::String
    type::ArrowType
    nullable::Bool
end

"""A primitive Arrow type. `tag` is one of
`:null :bool :i8 :u8 :i16 :u16 :i32 :u32 :i64 :u64 :f16 :f32 :f64`."""
struct ArrowAtom <: ArrowType
    tag::Symbol
end

"Variable-length UTF-8 strings."
struct ArrowUtf8   <: ArrowType end
"Variable-length byte strings."
struct ArrowBinary <: ArrowType end

"A list of exactly `n` `item`s per element."
struct ArrowFixedList <: ArrowType
    item::ArrowField
    n::Int
end

"A variable-length list of `item`s."
struct ArrowList <: ArrowType
    item::ArrowField
end

"A struct of named `fields`."
struct ArrowStruct <: ArrowType
    fields::Vector{ArrowField}
end

"A union over `fields`, dense or sparse."
struct ArrowUnion <: ArrowType
    fields::Vector{ArrowField}
    sparse::Bool
end

# C Data Interface format strings, defined by the Arrow spec
const _ATOM_FORMAT = Dict(
    :null=>"n", :bool=>"b",
    :i8=>"c", :u8=>"C", :i16=>"s", :u16=>"S", :i32=>"i", :u32=>"I",
    :i64=>"l", :u64=>"L", :f16=>"e", :f32=>"f", :f64=>"g",
)
const _FORMAT_ATOM = Dict(v => k for (k, v) in _ATOM_FORMAT)

# Julia storage eltype per atom tag (:bool is bit-packed and :null storageless,
# so neither has a flat Julia element type).
const _ATOM_JULIA = Dict(:i8=>Int8, :u8=>UInt8, :i16=>Int16, :u16=>UInt16, :i32=>Int32,
    :u32=>UInt32, :i64=>Int64, :u64=>UInt64, :f16=>Float16, :f32=>Float32, :f64=>Float64)

"""
    arrow_format(t::ArrowType) -> String

The Arrow C Data Interface format string for `t` (just this node; children are
described by their own schemas).
"""
arrow_format(t::ArrowAtom)      = _ATOM_FORMAT[t.tag]
arrow_format(::ArrowUtf8)       = "u"
arrow_format(::ArrowBinary)     = "z"
arrow_format(t::ArrowFixedList) = "+w:$(t.n)"
arrow_format(::ArrowList)       = "+l"
arrow_format(::ArrowStruct)     = "+s"
arrow_format(t::ArrowUnion)     = (t.sparse ? "+us:" : "+ud:") *
                                  join(0:length(t.fields)-1, ",")

"""Direct child fields of `t` (empty for leaves), in Arrow buffer order."""
arrow_children(t::ArrowFixedList) = (t.item,)
arrow_children(t::ArrowList)      = (t.item,)
arrow_children(t::ArrowStruct)    = Tuple(t.fields)
arrow_children(t::ArrowUnion)     = Tuple(t.fields)
arrow_children(::ArrowType)       = ()

# Human-readable one-liner (handy for tests / REPL).
_summ(f::ArrowField) = "$(f.name)$(f.nullable ? "?" : "")::$(_summ(f.type))"
_summ(t::ArrowAtom)  = String(t.tag)
_summ(::ArrowUtf8)   = "utf8"
_summ(::ArrowBinary) = "binary"
_summ(t::ArrowFixedList) = "FixedSizeList<$(t.n)>{$(_summ(t.item.type))}"
_summ(t::ArrowList)      = "List{$(_summ(t.item.type))}"
_summ(t::ArrowStruct)    = "Struct{" * join(map(_summ, t.fields), ", ") * "}"
_summ(t::ArrowUnion)     = "Union" * (t.sparse ? "[sparse]" : "[dense]") *
                           "{" * join(map(_summ, t.fields), ", ") * "}"

"""Metadata for one field of an archetype (drives the `rr_component_descriptor`)."""
struct ArchetypeField
    field::String           # e.g. "positions"
    component::String        # descriptor `component`, e.g. "Points3D:positions"
    component_type::String   # descriptor `component_type`, e.g. "rerun.components.Position3D"
    nullable::Bool
end
