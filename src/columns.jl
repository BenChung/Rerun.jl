# Columnar / temporal bulk logging: rr_recording_stream_send_columns.
#
# Sends R logical rows at once. Each time column is an i64 array of length R;
# each component column is a `List<component>` of length R (row i = that row's
# batch of component instances). Like `log`, rerun takes ownership of the arrays
# and releases them asynchronously.
#
# A component column is just a List over the component's Arrow type, so it reuses
# the exporter. For flat components it stays ZERO-COPY: the offsets are a rooted
# Julia `Vector{Int32}` (pointed into, not malloc'd) and the values point into
# the (flattened) data — both kept alive by one registry slot, freed by the
# normal zero-copy release/drain. Non-flat components fall back to an assembled
# (owned, copied) List.

"""
    TimeColumn(name, values; kind=:sequence)

A column of time points for `name`. `kind ∈ (:sequence, :duration, :timestamp)`;
for `:duration`/`:timestamp`, `values` are nanoseconds. Length must match the
component columns in the same `send_columns` call.
"""
struct TimeColumn
    name::String
    kind::Symbol
    values::Vector{Int64}
end
TimeColumn(name::AbstractString, values; kind::Symbol=:sequence) =
    TimeColumn(String(name), kind, Vector{Int64}(values))

_astimecolumn(tc::TimeColumn) = tc
_astimecolumn(p::Pair) = TimeColumn(first(p), last(p))     # "frame" => values  (sequence)

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

function _component_column(c::Pair)
    handle, t = _resolve_component(first(c))
    data = last(c)
    if eltype(data) <: AbstractVector            # multi: each element is a row's batch
        R = length(data)
        offsets = Vector{Int32}(undef, R + 1); offsets[1] = 0
        @inbounds for i in 1:R; offsets[i+1] = offsets[i] + Int32(length(data[i])); end
        if _is_flat(t)
            return _zerocopy_list_column(handle, t, collect(Iterators.flatten(data)), offsets)
        else
            return LibRerunC.rr_component_column(handle, _assembled(ArrowList(ArrowField("item", t, false)), data))
        end
    else                                          # mono: one instance per row
        R = length(data)
        if _is_flat(t)
            return _zerocopy_list_column(handle, t, data, Int32.(0:R))
        else
            return LibRerunC.rr_component_column(handle, _assembled(ArrowList(ArrowField("item", t, false)), [data[i:i] for i in 1:R]))
        end
    end
end

"""
    send_columns(rec, entity_path, timelines, columns)

Send `columns` as columnar data indexed by `timelines` (one logical row per
index; all column lengths must match). Example:

    send_columns(rec, "world/points",
        ["frame" => 0:99],                        # or TimeColumn(...; kind=:timestamp)
        [Position3D => batches])                   # batches::Vector{Vector{Position3D}}, or a flat Vector for 1/row
"""
function send_columns(r::RecordingStream, entity_path::AbstractString, timelines, columns)
    _drain_exports()
    tcs   = TimeColumn[_astimecolumn(t) for t in timelines]   # keeps the name Strings alive
    tcols = LibRerunC.rr_time_column[_time_column(tc) for tc in tcs]
    ccols = LibRerunC.rr_component_column[_component_column(c) for c in columns]
    GC.@preserve tcs tcols ccols begin
        checked(err -> LibRerunC.rr_recording_stream_send_columns(
            r.handle, entity_path,
            pointer(tcols), UInt32(length(tcols)),
            pointer(ccols), UInt32(length(ccols)), err))
    end
    return r
end
