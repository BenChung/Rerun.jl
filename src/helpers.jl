# High-level convenience built on the typed/union machinery.

_tensor_names(::Nothing, _) = String[]
_tensor_names(names, _) = collect(String, names)

# Julia element type -> TensorBuffer union variant tag.
const _TENSOR_VARIANT = Dict{DataType,Symbol}(
    UInt8=>:U8, UInt16=>:U16, UInt32=>:U32, UInt64=>:U64,
    Int8=>:I8, Int16=>:I16, Int32=>:I32, Int64=>:I64,
    Float16=>:F16, Float32=>:F32, Float64=>:F64,
)

# Build a TensorData value from a Julia array: shape = size; the buffer variant is
# chosen from `eltype` (NOT the data values — so empty/zero-extent arrays still
# resolve deterministically instead of matching every numeric arm), tagged as
# `:Variant => data`. Julia is column-major and Rerun tensors are row-major, so the
# data is reordered via permutedims (the buffer is copied by the assembled exporter).
function _tensordata(arr::AbstractArray, names)
    v = get(_TENSOR_VARIANT, eltype(arr)) do
        error("log_tensor: unsupported element type $(eltype(arr)); expected a numeric type (UInt8…Int64, Float16/Float32/Float64)")
    end
    nd = ndims(arr)
    data = nd <= 1 ? collect(vec(arr)) : vec(permutedims(arr, reverse(ntuple(identity, nd))))
    return (shape = UInt64[size(arr)...], names = _tensor_names(names, nd), buffer = (v => data))
end

"""
    log_tensor(rec, entity_path, array::AbstractArray; names=nothing)

Log an N-dimensional Julia array as a Rerun `Tensor`. `shape` comes from
`size(array)` and the `TensorBuffer` union variant from `eltype(array)`
(`Float32`→F32, `UInt8`→U8, …). Data is reordered to Rerun's row-major layout.

```julia
log_tensor(rec, "heatmap", rand(Float32, 64, 64))
log_tensor(rec, "volume",  rand(UInt16, 32, 32, 16); names=["x","y","z"])
```
"""
function log_tensor(rec::RecordingStream, entity_path::AbstractString, array::AbstractArray; names=nothing)
    log(rec, entity_path, Archetypes.Tensor([_tensordata(array, names)]))
    return rec
end
