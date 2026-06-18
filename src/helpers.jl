# High-level convenience built on the typed/union machinery.

_tensor_names(::Nothing, _) = String[]
_tensor_names(names, _) = collect(String, names)

# Build a TensorData value from a Julia array: shape = size, buffer variant from
# eltype. Julia is column-major and Rerun tensors are row-major, so reorder via
# permutedims (the buffer is copied by the assembled exporter anyway).
function _tensordata(arr::AbstractArray, names)
    nd = ndims(arr)
    data = nd <= 1 ? collect(vec(arr)) : vec(permutedims(arr, reverse(ntuple(identity, nd))))
    return (shape = UInt64[size(arr)...], names = _tensor_names(names, nd), buffer = (data = data,))
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
