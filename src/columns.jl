# Columnar / temporal bulk logging: rr_recording_stream_send_columns.
#
# Sends R logical rows at once. Each time column is an i64 array of length R;
# each component column is a `List<component>` of length R (row i = that row's
# batch of component instances). Like `log`, rerun takes ownership of the arrays
# and releases them asynchronously.
#
# A component column is just a List over the component's Arrow type, so it reuses
# the exporter. For flat components it stays zero-copy: the offsets are a rooted
# Julia `Vector{Int32}` (pointed into, not malloc'd) and the values point into
# the (flattened) data — both kept alive by one registry slot, freed by the
# normal zero-copy release/drain. Non-flat components fall back to an assembled
# (owned, copied) List.

"""
    TimeColumn(name, values; kind=:sequence)
    TimeColumn(timeline::Timeline, values)

A column of time points for `name`. `kind` is one of `:sequence`, `:duration`,
or `:timestamp`; a [`Timeline`](@ref) supplies its own kind and converts typed
`values` exactly:

- `:timestamp` timelines: [`TimePoint`](@ref) or `DateTime`
- `:duration` timelines: `Dates.FixedPeriod`

Raw `Integer` values are nanoseconds on `:duration` and `:timestamp` timelines.
Length must match the component columns in the same `send_columns` call.

Values already in wire layout are **aliased, not copied**: `Vector{Int64}` on
any kind, and `Vector{TimePoint}` / `Vector{Nanosecond}` matching the
timeline's kind. rerun reads the aliased memory in place and releases it
asynchronously after batching — do not mutate or resize such a vector until
the recording has flushed. Every other input (ranges, `DateTime`s, generic
iterables) converts into a fresh vector.
"""
struct TimeColumn{V<:AbstractVector{Int64}}
    name::String
    kind::Symbol
    values::V
end
TimeColumn(name::AbstractString, values; kind::Symbol=:sequence) =
    TimeColumn(String(name), kind, _wire_values(values))
TimeColumn(tl::Timeline, values) = TimeColumn(tl.name, kind(tl), _wire_values(tl, values))

# Wire-layout (Int64) time values: alias vectors already in wire layout,
# convert everything else into a fresh Vector{Int64}.
_wire_values(v::Vector{Int64}) = v
_wire_values(v::AbstractVector) = Vector{Int64}(v)
_wire_values(::Timeline, v::Vector{Int64}) = v
_wire_values(::Timeline{TimePoint}, v::Vector{TimePoint}) = reinterpret(Int64, v)
_wire_values(::Timeline{Nanosecond}, v::Vector{Nanosecond}) = reinterpret(Int64, v)
_wire_values(tl::Timeline, values) = Int64[_time_value(tl, v) for v in values]

_astimecolumn(tc::TimeColumn) = tc
_astimecolumn(p::Pair) = TimeColumn(first(p), last(p))     # "frame"/Timeline => values

function _time_column(tc::TimeColumn)
    tt = get(_TIME_TYPES, tc.kind) do
        error("unknown time kind $(tc.kind); expected :sequence, :duration, or :timestamp")
    end
    R = length(tc.values)
    bufs = _buffers(Ptr{Cvoid}(C_NULL), Ptr{Cvoid}(pointer(tc.values)))   # [validity, i64 values] zero-copy
    arr = LibRerunC.ArrowArray(R, 0, 0, 2, 0, bufs,
        Ptr{Ptr{LibRerunC.ArrowArray}}(C_NULL), Ptr{LibRerunC.ArrowArray}(C_NULL), _ARRAY_RELEASE[], C_NULL)
    arr = _with_array_private(arr, Ptr{Cvoid}(_register_root!(tc.values)))
    tl = LibRerunC.rr_timeline(_rrstr(tc.name), tt)                       # name kept alive by the TimeColumn
    return LibRerunC.rr_time_column(tl, arr, LibRerunC.RR_SORTING_STATUS_UNKNOWN)
end

_resolve_component(::Type{C}) where {C<:Component} = (_component_handle(C), arrowtype(C))
_resolve_component(ct::AbstractString) = (t = _lookup_component(ct); (_handle("", ct, ct, t), t))

# zero-copy List<component>: rooted offsets + flat values
function _zerocopy_list_column(handle, t::ArrowType, flat::AbstractVector, offsets::Vector{Int32})
    isbitstype(eltype(flat)) && sizeof(eltype(flat)) == _wire_elsize(t) ||
        error("send_columns: element layout of $(eltype(flat)) doesn't match $(_summ(t))")
    R = length(offsets) - 1
    child = _build_array_node(t, length(flat), Ptr{Cvoid}(pointer(flat)))
    kids = Ptr{Ptr{LibRerunC.ArrowArray}}(Libc.malloc(sizeof(Ptr)))
    unsafe_store!(kids, _child_ptr(child), 1)
    bufs = _buffers(Ptr{Cvoid}(C_NULL), Ptr{Cvoid}(pointer(offsets)))
    list = LibRerunC.ArrowArray(R, 0, 0, 2, 1, bufs, kids, Ptr{LibRerunC.ArrowArray}(C_NULL), _ARRAY_RELEASE[], C_NULL)
    list = _with_array_private(list, Ptr{Cvoid}(_register_root!((offsets, flat))))
    return LibRerunC.rr_component_column(handle, list)
end

# Unwrap a carrier component vector (Text/Blob/…) to its wire payload, mirroring
# _build_component_array; the identity for flat components.
_carrier_payload(data::AbstractVector) = _payload(Base.nonmissingtype(eltype(data)), data)

# List<component> with one instance per row (offsets 0,1,…,R).
function _mono_column(handle, t::ArrowType, data::AbstractVector)
    R = length(data)
    _is_flat(t) && return _zerocopy_list_column(handle, t, data, Int32.(0:R))
    return LibRerunC.rr_component_column(handle,
        _assembled(ArrowList(ArrowField("item", t, false)), [data[i:i] for i in 1:R]))
end

# List<component> where each row is a batch of instances.
function _multi_column(handle, t::ArrowType, data::AbstractVector)
    R = length(data)
    offsets = Vector{Int32}(undef, R + 1); offsets[1] = 0
    @inbounds for i in 1:R; offsets[i+1] = offsets[i] + Int32(length(data[i])); end
    _is_flat(t) && return _zerocopy_list_column(handle, t, collect(Iterators.flatten(data)), offsets)
    return LibRerunC.rr_component_column(handle,
        _assembled(ArrowList(ArrowField("item", t, false)), data))
end

# Mono-vs-multi dispatches on the original element type; carriers then unwrap to
# their wire payload — a component struct is one instance/row even when its
# payload is itself a vector (Blob -> Vector{UInt8}), matching `log`.
_column(handle, t, data::AbstractVector{<:Union{Component,Missing}}) =           # typed, one/row
    _mono_column(handle, t, _carrier_payload(data))
_column(handle, t, data::AbstractVector{<:AbstractVector{<:Union{Component,Missing}}}) =  # typed, batch/row
    _multi_column(handle, t, [_carrier_payload(row) for row in data])
_column(handle, t, data::AbstractVector{<:AbstractVector}) =                       # foreign eltype, batch/row
    _multi_column(handle, t, _is_flat(t) ? [_materialize_handle(handle, row) for row in data] : data)
_column(handle, t, data::AbstractVector) =                                         # foreign eltype, one/row
    _mono_column(handle, t, _is_flat(t) ? _materialize_handle(handle, data) : data)

function _component_column(c::Pair)
    handle, t = _resolve_component(first(c))
    return _column(handle, t, last(c))
end

"""
    send_columns(rec, entity_path, timelines::Tuple, columns::Tuple)
    send_columns(rec, entity_path, timelines, columns)

Send `columns` as columnar data indexed by `timelines` (one logical row per
index; all column lengths must match). Example:

    send_columns(rec, "world/points",
        (Timeline("frame") => 0:99,),              # or "frame" => 0:99, or TimeColumn(...)
        (Position3D => batches,))                  # batches::Vector{Vector{Position3D}}, or a flat Vector for 1/row

The tuple form keeps every pair's type concrete: component handles, Arrow
types, and time-value conversions resolve statically, and the per-call C
argument arrays are stack tuples. Vectors (or any iterables) also work, at the
cost of dynamic dispatch per column.

Zero-copy contract: flat component columns and wire-layout time columns (see
[`TimeColumn`](@ref)) alias the caller's vectors — rerun reads them in place
and releases them asynchronously, so keep them unmutated until the recording
has flushed.
"""
function send_columns(r::RecordingStream, entity_path::AbstractString, timelines::Tuple, columns::Tuple)
    _drain_exports()
    tcs   = map(_astimecolumn, timelines)         # NTuple; keeps the name Strings alive
    tcols = map(_time_column, tcs)
    local ccols
    try
        ccols = map(_component_column, columns)
        tref = Ref(tcols); cref = Ref(ccols)
        GC.@preserve tcs tref cref begin
            pt = isempty(tcols) ? Ptr{LibRerunC.rr_time_column}(C_NULL) :
                 Ptr{LibRerunC.rr_time_column}(Base.unsafe_convert(Ptr{typeof(tcols)}, tref))
            pc = isempty(ccols) ? Ptr{LibRerunC.rr_component_column}(C_NULL) :
                 Ptr{LibRerunC.rr_component_column}(Base.unsafe_convert(Ptr{typeof(ccols)}, cref))
            checked(err -> LibRerunC.rr_recording_stream_send_columns(
                r.handle, entity_path,
                pt, UInt32(length(tcols)),
                pc, UInt32(length(ccols)), err))
        end
    catch
        # Build/send failed -> rerun never took ownership, so release the built
        # column arrays ourselves (free C bookkeeping, unpin zero-copy roots).
        for tc in tcols; _release_unpublished(tc.array); end
        @isdefined(ccols) && for cc in ccols; _release_unpublished(cc.array); end
        rethrow()
    end
    return r
end

function send_columns(r::RecordingStream, entity_path::AbstractString, timelines, columns)
    _drain_exports()
    tcs   = TimeColumn[_astimecolumn(t) for t in timelines]   # keeps the name Strings alive
    tcols = LibRerunC.rr_time_column[_time_column(tc) for tc in tcs]
    local ccols
    try
        ccols = LibRerunC.rr_component_column[_component_column(c) for c in columns]
        GC.@preserve tcs tcols ccols begin
            checked(err -> LibRerunC.rr_recording_stream_send_columns(
                r.handle, entity_path,
                pointer(tcols), UInt32(length(tcols)),
                pointer(ccols), UInt32(length(ccols)), err))
        end
    catch
        # Build/send failed -> rerun never took ownership, so release the built
        # column arrays ourselves (free C bookkeeping, unpin zero-copy roots).
        for tc in tcols; _release_unpublished(tc.array); end
        @isdefined(ccols) && for cc in ccols; _release_unpublished(cc.array); end
        rethrow()
    end
    return r
end
