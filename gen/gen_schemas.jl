# Generates `src/generated_schemas.jl`: the resolved Arrow datatype for every
# Rerun component, plus archetype->field descriptor metadata.
#
# Pipeline (mirrors Rerun's own `re_types_builder`):
#   1. `flatc` (from flatbuffers_jll) compiles the vendored IDL entrypoint to a
#      binary reflection dump (.bfbs), then decodes it to JSON via reflection.fbs.
#   2. We port `type_registry.rs::arrow_datatype_from_object` + the handful of
#      `objects.rs` predicates it depends on to turn the reflection into the
#      closed `ArrowType` model defined in `src/arrow_types.jl`.
#
# Run with:  julia --project=gen gen/gen_schemas.jl
#
# This is the schema analogue of gen/generator.jl (which generates LibRerunC.jl).

using flatbuffers_jll, JSON3

const ROOT  = normpath(@__DIR__, "..")
const DEFS  = joinpath(@__DIR__, "idl", "definitions")
const REFL  = joinpath(@__DIR__, "idl", "reflection.fbs")
const ENTRY = joinpath(DEFS, "entry_point.fbs")
const OUT   = joinpath(ROOT, "src", "generated_schemas.jl")
const OUT_TYPES = joinpath(ROOT, "src", "generated_types.jl")
const RERUN_SDK_VERSION = "0.33.0"

# 1. flatc:  IDL -> .bfbs -> reflection JSON
function load_reflection()
    mktempdir() do tmp
        flatc() do exe
            run(`$exe -I $DEFS -o $tmp -b --bfbs-comments --schema $ENTRY`)
            bfbs = joinpath(tmp, "entry_point.bfbs")
            run(`$exe --json --strict-json --raw-binary -o $tmp $REFL -- $bfbs`)
        end
        JSON3.read(read(joinpath(tmp, "entry_point.json"), String))
    end
end

# 2. Resolver (port of re_types_builder type_registry.rs).
#    Emits runtime-constructor source strings directly (bottom-up).
const ATOMIC = Dict(
    "Bool"=>:bool, "Byte"=>:i8, "UByte"=>:u8, "Short"=>:i16, "UShort"=>:u16,
    "Int"=>:i32, "UInt"=>:u32, "Long"=>:i64, "ULong"=>:u64, "Float"=>:f32, "Double"=>:f64,
)

has_attr(o, key) = haskey(o, :attributes) && any(a -> String(a.key) == key, o.attributes)

# A table is Arrow-transparent — its wrapper layer is erased, leaving the inner
# field's type — if it carries `attr.arrow.transparent` OR the bare `transparent`
# attribute (declared in attributes/fbs.fbs; used by the TensorBuffer `*Buffer`
# datatypes, whose union arms must resolve to the bare `List<T>` rerun_c expects
# rather than a `Struct{data: List<T>}` wrapper, so TensorData/Tensor/BarChart log
# correctly).
_is_transparent(o) = has_attr(o, "attr.arrow.transparent") || has_attr(o, "transparent")

function kind_of(fqname::AbstractString)
    segs = split(fqname, '.')
    "archetypes" in segs && return :archetype
    "components" in segs && return :component
    "datatypes"  in segs && return :datatype
    "views"      in segs && return :view
    return :datatype
end

atomsrc(tag) = "ArrowAtom(:$tag)"

struct Ctx
    objects::JSON3.Array
    enums::JSON3.Array
    memo::Dict{Int,String}     # object index (1-based) -> type source
end

# --- field attribute helpers ---
function _field_attr(f, key)
    haskey(f, :attributes) || return nothing
    for a in f.attributes
        String(a.key) == key && return String(a.value)
    end
    return nothing
end
# flatc reports struct fields alphabetically; Rerun orders them by `order`
# (objects.rs: `fields.sort_by_key(|f| f.order)`), and Arrow struct child order
# is significant, so we must sort by it too.
_field_order(f) = (v = _field_attr(f, "order"); v === nothing ? typemax(Int) : parse(Int, v))
_override_type(f) = _field_attr(f, "attr.rerun.override_type")

# Is `t` a reference to the builtin unit type? Rerun maps such fields to
# Type::Unit -> Arrow Null (type_registry.rs / objects.rs:1340).
function _is_unit(ctx::Ctx, t)
    String(t.base_type) == "Obj" || return false
    return String(ctx.objects[Int(t.index) + 1].name) == "rerun.builtins.UnitType"
end

# arrow_datatype_from_element_type. `override` is the field's
# `attr.rerun.override_type` (e.g. "float16" reinterprets a ushort buffer).
function element_src(ctx::Ctx, t; override=nothing)
    el = String(t.element)
    el == "Obj"    && return resolve_object_idx(ctx, Int(t.index) + 1)
    el == "String" && return "ArrowUtf8()"
    el == "Binary" && return "ArrowBinary()"
    if haskey(ATOMIC, el)
        override == "float16" && el == "UShort" && return atomsrc(:f16)
        return atomsrc(ATOMIC[el])
    end
    error("unhandled element type $el")
end

# arrow_datatype_from_type
function type_src(ctx::Ctx, t; override=nothing)
    bt = String(t.base_type)
    if bt == "Obj"
        return resolve_object_idx(ctx, Int(t.index) + 1)   # UnitType handled in resolve_object_idx
    elseif bt == "Union"
        return enum_src(ctx, ctx.enums[Int(t.index) + 1])
    elseif bt == "Array"
        # FixedSizeList: item field is always non-nullable per the IDL.
        return "ArrowFixedList(ArrowField(\"item\", $(element_src(ctx, t; override=override)), false), $(Int(t.fixed_length)))"
    elseif bt == "Vector"
        return "ArrowList(ArrowField(\"item\", $(element_src(ctx, t; override=override)), false))"
    elseif bt == "String"
        return "ArrowUtf8()"
    elseif bt == "Binary"
        return "ArrowBinary()"
    elseif haskey(ATOMIC, bt)
        # integer base_type + enum index => enum-typed field
        if haskey(t, :index) && Int(t.index) >= 0
            return enum_src(ctx, ctx.enums[Int(t.index) + 1])
        end
        override == "float16" && bt == "UShort" && return atomsrc(:f16)
        return atomsrc(ATOMIC[bt])
    else
        error("unhandled base_type $bt")
    end
end

# enums table entry: plain enum -> atomic int; union -> ArrowUnion
function enum_src(ctx::Ctx, e)
    if get(e, :is_union, false)
        sparse = has_attr(e, "attr.arrow.sparse_union")
        parts = String["ArrowField(\"_null_markers\", ArrowAtom(:null), true)"]
        for v in e.values
            String(v.name) == "NONE" && continue
            ut = get(v, :union_type, nothing)
            if ut !== nothing && haskey(ut, :base_type) && String(ut.base_type) == "Obj" && !_is_unit(ctx, ut)
                push!(parts, "ArrowField($(repr(String(v.name))), $(resolve_object_idx(ctx, Int(ut.index)+1)), false)")
            else
                # builtin Unit (or a NONE-style variant) -> Null, nullable per type_registry.rs:130
                push!(parts, "ArrowField($(repr(String(v.name))), ArrowAtom(:null), true)")
            end
        end
        return "ArrowUnion(ArrowField[" * join(parts, ", ") * "], $sparse)"
    else
        return atomsrc(ATOMIC[String(e.underlying_type.base_type)])
    end
end

# type_registry::arrow_datatype_from_object  (transparent / struct)
function resolve_object_idx(ctx::Ctx, i::Int)
    get!(ctx.memo, i) do
        o = ctx.objects[i]
        fq = String(o.name)
        fq == "rerun.builtins.UnitType" && return "ArrowAtom(:null)"
        transparent = (kind_of(fq) == :component) || _is_transparent(o)
        if transparent
            length(o.fields) == 1 || error("$fq: transparent but $(length(o.fields)) fields")
            f = o.fields[1]
            return type_src(ctx, f.type; override=_override_type(f))
        elseif haskey(o, :fields)
            parts = String[]
            for f in sort(collect(o.fields); by=_field_order)
                String(f.type.base_type) == "UType" && continue   # union discriminant: collapsed into the Union field
                nullable = has_attr(f, "nullable") || _is_unit(ctx, f.type)
                push!(parts, "ArrowField($(repr(String(f.name))), $(type_src(ctx, f.type; override=_override_type(f))), $nullable)")
            end
            return "ArrowStruct(ArrowField[" * join(parts, ", ") * "])"
        else
            error("$fq: neither transparent nor struct")
        end
    end
end

# --- Julia "wire" type for the zero-copy struct layer ---
# Returns the Julia type string whose memory layout equals the component's Arrow
# values buffer (isbits, no padding), or `nothing` if the component is not
# zero-copy (bool / utf8 / list / struct / union).
const JL_PRIM = Dict(
    "Float"=>"Float32", "Double"=>"Float64", "Byte"=>"Int8", "UByte"=>"UInt8",
    "Short"=>"Int16", "UShort"=>"UInt16", "Int"=>"Int32", "UInt"=>"UInt32",
    "Long"=>"Int64", "ULong"=>"UInt64",
)

function julia_wire_obj(ctx::Ctx, o)
    fq = String(o.name)
    fq == "rerun.builtins.UnitType" && return nothing
    transparent = (kind_of(fq) == :component) || _is_transparent(o)
    transparent || return nothing                 # struct/multi-field -> not flat
    length(o.fields) == 1 || return nothing
    return julia_wire_type(ctx, o.fields[1].type; override=_override_type(o.fields[1]))
end

function julia_wire_elem(ctx::Ctx, t; override=nothing)
    el = String(t.element)
    el == "Obj" && return julia_wire_obj(ctx, ctx.objects[Int(t.index) + 1])
    override == "float16" && el == "UShort" && return "Float16"
    return get(JL_PRIM, el, nothing)
end

# Thread `override` so the wire/struct type matches the Arrow datatype.
function julia_wire_type(ctx::Ctx, t; override=nothing)
    bt = String(t.base_type)
    if bt == "Obj"
        return julia_wire_obj(ctx, ctx.objects[Int(t.index) + 1])
    elseif bt == "Array"
        el = julia_wire_elem(ctx, t; override=override)
        el === nothing && return nothing
        return "NTuple{$(Int(t.fixed_length)),$el}"
    elseif haskey(JL_PRIM, bt)
        if haskey(t, :index) && Int(t.index) >= 0     # enum-typed -> underlying int
            e = ctx.enums[Int(t.index) + 1]
            get(e, :is_union, false) && return nothing
            return JL_PRIM[String(e.underlying_type.base_type)]
        end
        override == "float16" && bt == "UShort" && return "Float16"
        return JL_PRIM[bt]
    else
        return nothing                                 # Bool/String/Vector/Binary/Union
    end
end

# Julia carrier field type for a non-flat "simple" component: utf8 -> String,
# list<flat-item> -> Vector{item}. `nothing` for struct/union/etc. components.
function carrier_field_type(ctx::Ctx, t)
    bt = String(t.base_type)
    if bt == "Obj"
        o = ctx.objects[Int(t.index) + 1]
        (haskey(o, :fields) && length(o.fields) == 1 &&
            (kind_of(String(o.name)) == :component || _is_transparent(o))) || return nothing
        return carrier_field_type(ctx, o.fields[1].type)
    elseif bt == "String"
        return "String"
    elseif bt == "Vector"
        el = julia_wire_elem(ctx, t)
        return el === nothing ? nothing : "Vector{$el}"
    end
    return nothing
end

# Source for an enum-backed component struct (per-type variant namespace via
# getproperty, e.g. `Colormap.Inferno`). Shared by core and blueprint enums.
function _enum_struct_src(short, fq, jt, values)
    getprops = IOBuffer(); pnames = String[]
    for v in values
        nm = repr(Symbol(String(v.name)))
        println(getprops, "        s === $nm && return $short($jt($(Int(v.value))))")
        push!(pnames, nm)
    end
    pn = join(pnames, ", ") * (length(pnames) == 1 ? "," : "")
    return """
    const _AT_$short = COMPONENT_TYPES[$(repr(fq))]
    const _HR_$short = Ref{LibRerunC.rr_component_type_handle}(LibRerunC.RR_COMPONENT_TYPE_HANDLE_INVALID)
    struct $short <: Component
        value::$jt
    end
    componenttype(::Type{$short}) = $(repr(fq))
    arrowtype(::Type{$short}) = _AT_$short
    handleref(::Type{$short}) = _HR_$short
    function Base.getproperty(::Type{$short}, s::Symbol)
$(String(take!(getprops)))        return getfield($short, s)
    end
    Base.propertynames(::Type{$short}) = ($pn)
    export $short
"""
end

# Resolve the component fqname an archetype field refers to: a single component
# (Obj) or batch (`[Component]` => Vector/Array of Obj), and likewise for
# enum-backed components (integer base_type / element + index into the enums table).
function _arch_component(ctx::Ctx, t)
    bt = String(t.base_type)
    if bt == "Obj"
        return String(ctx.objects[Int(t.index) + 1].name)
    elseif bt == "Vector" || bt == "Array"
        el = String(get(t, :element, ""))
        if el == "Obj"
            return String(ctx.objects[Int(t.index) + 1].name)
        elseif haskey(ATOMIC, el) && haskey(t, :index) && Int(t.index) >= 0
            return String(ctx.enums[Int(t.index) + 1].name)
        end
    elseif haskey(ATOMIC, bt) && haskey(t, :index) && Int(t.index) >= 0
        return String(ctx.enums[Int(t.index) + 1].name)
    end
    return nothing
end

# 3. Emit
function main()
    J = load_reflection()
    ctx = Ctx(J.objects, get(J, :enums, JSON3.Array[]), Dict{Int,String}())
    is_real(fq) = !occursin(".testing.", fq)

    # components: struct/transparent components live in `objects`; enum-backed
    # components (Colormap, VideoCodec, ...) live in the separate `enums` table.
    comp_lines = String[]; skipped = String[]
    for (i, o) in enumerate(ctx.objects)
        fq = String(o.name)
        (kind_of(fq) == :component && is_real(fq)) || continue
        try
            push!(comp_lines, "    $(repr(fq)) => $(resolve_object_idx(ctx, i)),")
        catch err
            push!(skipped, "$fq  ($err)")
        end
    end
    for e in ctx.enums
        fq = String(e.name)
        (kind_of(fq) == :component && is_real(fq)) || continue
        try
            push!(comp_lines, "    $(repr(fq)) => $(enum_src(ctx, e)),")
        catch err
            push!(skipped, "$fq  ($err)")
        end
    end
    sort!(comp_lines)

    # archetypes -> field descriptors
    arch_blocks = String[]
    for o in ctx.objects
        fq = String(o.name)
        (kind_of(fq) == :archetype && is_real(fq)) || continue
        short = String(split(fq, '.')[end])
        haskey(o, :fields) || continue
        fields = String[]
        for f in sort(collect(o.fields); by=_field_order)
            ctype = _arch_component(ctx, f.type)
            ctype === nothing && continue
            fld = String(f.name)
            nullable = has_attr(f, "nullable")
            push!(fields, "        ArchetypeField($(repr(fld)), $(repr("$short:$fld")), $(repr(ctype)), $nullable),")
        end
        isempty(fields) && continue
        push!(arch_blocks, "    $(repr(fq)) => ArchetypeField[\n" * join(fields, "\n") * "\n    ],")
    end
    sort!(arch_blocks)

    open(OUT, "w") do io
        println(io, "# AUTO-GENERATED by gen/gen_schemas.jl from the vendored Rerun IDL.")
        println(io, "# Rerun SDK version: $RERUN_SDK_VERSION.  Do NOT edit by hand.")
        println(io, "# Regenerate with: julia --project=gen gen/gen_schemas.jl")
        println(io)
        println(io, "const RERUN_SDK_VERSION = $(repr(RERUN_SDK_VERSION))")
        println(io)
        println(io, "const COMPONENT_TYPES = Dict{String,ArrowType}(")
        foreach(l -> println(io, l), comp_lines)
        println(io, ")")
        println(io)
        println(io, "const ARCHETYPES = Dict{String,Vector{ArchetypeField}}(")
        foreach(b -> println(io, b), arch_blocks)
        println(io, ")")
    end

    # Materialized structs (data carriers + dispatch tags), zero-copy set:
    # components under `rerun.components.*` with a flat wire layout, and
    # archetypes under `rerun.archetypes.*`.
    comp_structs = String[]; comp_names = String[]
    for o in ctx.objects
        fq = String(o.name)
        startswith(fq, "rerun.components.") || continue          # skip blueprint (avoids short-name clashes)
        (haskey(o, :fields) && length(o.fields) == 1) || continue # transparent component
        short = String(split(fq, '.')[end]); fld = String(o.fields[1].name)
        jt = julia_wire_type(ctx, o.fields[1].type; override=_override_type(o.fields[1]))
        if jt !== nothing                                         # flat: struct IS the wire layout
            push!(comp_names, short)
            push!(comp_structs, """
    const _AT_$short = COMPONENT_TYPES[$(repr(fq))]
    const _HR_$short = Ref{LibRerunC.rr_component_type_handle}(LibRerunC.RR_COMPONENT_TYPE_HANDLE_INVALID)
    struct $short <: Component
        $fld::$jt
    end
    componenttype(::Type{$short}) = $(repr(fq))
    arrowtype(::Type{$short}) = _AT_$short
    handleref(::Type{$short}) = _HR_$short
    export $short
""")
        else                                                      # carrier: utf8 -> String, list<flat> -> Vector
            cjt = carrier_field_type(ctx, o.fields[1].type)
            cjt === nothing && continue
            push!(comp_names, short)
            ctor = cjt == "String" ? "    $short(v::AbstractString) = $short(String(v))\n" : ""
            push!(comp_structs, """
    const _AT_$short = COMPONENT_TYPES[$(repr(fq))]
    const _HR_$short = Ref{LibRerunC.rr_component_type_handle}(LibRerunC.RR_COMPONENT_TYPE_HANDLE_INVALID)
    struct $short <: Component
        value::$cjt
    end
$(ctor)    componenttype(::Type{$short}) = $(repr(fq))
    arrowtype(::Type{$short}) = _AT_$short
    handleref(::Type{$short}) = _HR_$short
    _payload(::Type{$short}, v) = _unwrap(v, :value)
    export $short
""")
        end
    end

    # enum-backed components (in the `enums` table): wire type is the underlying int.
    for e in ctx.enums
        fq = String(e.name)
        startswith(fq, "rerun.components.") || continue
        get(e, :is_union, false) && continue
        short = String(split(fq, '.')[end])
        push!(comp_names, short)
        push!(comp_structs, _enum_struct_src(short, fq, JL_PRIM[String(e.underlying_type.base_type)], e.values))
    end

    # blueprint enum-backed components -> a separate `Blueprint` submodule
    # (viewer config; kept apart so short names never clash with data components).
    bp_structs = String[]
    for e in ctx.enums
        fq = String(e.name)
        startswith(fq, "rerun.blueprint.components.") || continue
        (get(e, :is_union, false) || !is_real(fq)) && continue
        short = String(split(fq, '.')[end])
        push!(bp_structs, _enum_struct_src(short, fq, JL_PRIM[String(e.underlying_type.base_type)], e.values))
    end

    arch_structs = String[]; arch_names = String[]
    for o in ctx.objects
        fq = String(o.name)
        startswith(fq, "rerun.archetypes.") || continue
        haskey(o, :fields) || continue
        short = String(split(fq, '.')[end])
        flds = Tuple{String,String,String,Bool}[]   # (field, "Short:field", ctype, required)
        for f in sort(collect(o.fields); by=_field_order)
            ctype = _arch_component(ctx, f.type); ctype === nothing && continue
            fld = String(f.name)
            push!(flds, (fld, "$short:$fld", ctype, !has_attr(f, "nullable")))
        end
        isempty(flds) && continue
        push!(arch_names, short)
        req = [f[1] for f in flds if f[4]]; opt = [f[1] for f in flds if !f[4]]
        # constructor: required fields positional, optional kwargs (default nothing);
        # store all into the NamedTuple so its type encodes presence.
        kw = join(["$o=nothing" for o in opt], ", ")
        sig = isempty(req) ? "$short(; $kw)" :
              (isempty(opt) ? "$short(" * join(req, ", ") * ")" : "$short(" * join(req, ", ") * "; $kw)")
        ntargs = join([f[1] for f in flds], ", ")
        # per-field handle cache + arrowtype const + the type-stable spec method
        meta = IOBuffer()
        for f in flds
            fld, comp, ctype, _ = f
            print(meta, """
    const _AHR_$(short)_$(fld) = Ref{LibRerunC.rr_component_type_handle}(LibRerunC.RR_COMPONENT_TYPE_HANDLE_INVALID)
    const _AAT_$(short)_$(fld) = COMPONENT_TYPES[$(repr(ctype))]
    _arch_field_spec(::Type{<:$short}, ::Val{$(repr(Symbol(fld)))}, data) =
        (_cached_arch_handle(_AHR_$(short)_$(fld), $(repr(fq)), $(repr(comp)), $(repr(ctype)), _AAT_$(short)_$(fld)), _AAT_$(short)_$(fld), data)
""")
        end
        push!(arch_structs, """
    struct $short{NT<:NamedTuple} <: Archetype
        fields::NT
    end
    $sig = $short((; $ntargs))
    archetypename(::Type{<:$short}) = $(repr(fq))
$(String(take!(meta)))    export $short
""")
    end

    open(OUT_TYPES, "w") do io
        println(io, "# AUTO-GENERATED by gen/gen_schemas.jl from the vendored Rerun IDL.")
        println(io, "# Rerun SDK version: $RERUN_SDK_VERSION.  Do NOT edit by hand.")
        println(io, "#")
        println(io, "# Components and Archetypes live in submodules (their short names can collide,")
        println(io, "# e.g. ViewCoordinates is both). Use `using Rerun.Components` / `Rerun.Archetypes`.")
        println(io)
        println(io, "module Components")
        println(io, "import ..Component, ..COMPONENT_TYPES, ..componenttype, ..arrowtype, ..handleref, ..LibRerunC, .._payload, .._unwrap")
        foreach(s -> println(io, s), comp_structs)
        println(io, "end # module Components")
        println(io)
        println(io, "module Blueprint   # viewer-configuration components (enum-backed)")
        println(io, "import ..Component, ..COMPONENT_TYPES, ..componenttype, ..arrowtype, ..handleref, ..LibRerunC")
        foreach(s -> println(io, s), bp_structs)
        println(io, "end # module Blueprint")
        println(io)
        println(io, "module Archetypes")
        println(io, "import ..Archetype, ..archetypename, .._arch_field_spec, .._cached_arch_handle, ..COMPONENT_TYPES, ..LibRerunC")
        foreach(s -> println(io, s), arch_structs)
        println(io, "end # module Archetypes")
    end

    println("wrote $OUT")
    println("  components: $(length(comp_lines))   archetypes: $(length(arch_blocks))")
    println("wrote $OUT_TYPES")
    println("  component structs: $(length(comp_structs))   blueprint: $(length(bp_structs))   archetype structs: $(length(arch_structs))")
    if !isempty(skipped)
        println("  skipped $(length(skipped)) components:")
        foreach(s -> println("    - $s"), skipped)
    end
end

main()
