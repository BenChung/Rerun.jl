# RerunImageCoreExt — maps ImageCore.jl / ColorTypes.jl 2D image arrays to
# Rerun's image archetypes (`Image`, `DepthImage`, `SegmentationImage`).
# Extension convention: see RerunStaticArraysExt.jl.
#
# Julia images are column-major arrays of pixel structs; Rerun images are
# row-major interleaved-pixel HWC byte buffers (image.fbs), so every image
# splits into channels, reorders, and copies. `channelview` yields channels in
# canonical R,G,B(,A) order regardless of the colorant's storage order, and the
# (channel, width, height) permutedims + vec below produce exactly Rerun's
# element order (the test pins a non-square image so a transpose bug is caught).
module RerunImageCoreExt

using Rerun
using ImageCore
using ColorTypes
using ColorTypes.FixedPointNumbers: Normed

using Rerun.Components: ImageBuffer
using Rerun.Archetypes: Image, DepthImage, SegmentationImage

# Rerun enum codes (gen/idl/.../datatypes/{color_model,channel_datatype}.fbs).
# ImageFormat is a struct component logged as a NamedTuple.
# ColorModel
const COLOR_MODEL_L    = UInt8(1)
const COLOR_MODEL_RGB  = UInt8(2)
const COLOR_MODEL_RGBA = UInt8(3)

# ChannelDatatype
const CHANNEL_U8  = UInt8(6)
const CHANNEL_I8  = UInt8(7)
const CHANNEL_U16 = UInt8(8)
const CHANNEL_I16 = UInt8(9)
const CHANNEL_U32 = UInt8(10)
const CHANNEL_I32 = UInt8(11)
const CHANNEL_U64 = UInt8(12)
const CHANNEL_I64 = UInt8(13)
const CHANNEL_F16 = UInt8(33)
const CHANNEL_F32 = UInt8(34)
const CHANNEL_F64 = UInt8(35)

# Per-channel eltype -> Rerun ChannelDatatype. `Normed{T}` raw bytes are exactly
# the backing `T`, so N0f8 maps to U8 and N0f16 to U16 with no rescaling.
_channel_datatype(::Type{<:Normed{T}}) where {T} = _channel_datatype(T)
_channel_datatype(::Type{UInt8})   = CHANNEL_U8
_channel_datatype(::Type{Int8})    = CHANNEL_I8
_channel_datatype(::Type{UInt16})  = CHANNEL_U16
_channel_datatype(::Type{Int16})   = CHANNEL_I16
_channel_datatype(::Type{UInt32})  = CHANNEL_U32
_channel_datatype(::Type{Int32})   = CHANNEL_I32
_channel_datatype(::Type{UInt64})  = CHANNEL_U64
_channel_datatype(::Type{Int64})   = CHANNEL_I64
_channel_datatype(::Type{Float16}) = CHANNEL_F16
_channel_datatype(::Type{Float32}) = CHANNEL_F32
_channel_datatype(::Type{Float64}) = CHANNEL_F64
_channel_datatype(::Type{T}) where {T} =
    error("RerunImageCoreExt: no Rerun ChannelDatatype for element type $T")

# Backing storage element (for blob sizing).
_storage_type(::Type{<:Normed{T}}) where {T} = T
_storage_type(::Type{T}) where {T<:Union{Integer,AbstractFloat}} = T

# Single-channel (depth/segmentation) formats pass color_model = missing;
# pixel_format stays null (chroma-subsampled formats are never emitted).
@inline function _image_format(width::Integer, height::Integer, color_model,
                               channel_datatype::UInt8)
    return (width            = UInt32(width),
            height           = UInt32(height),
            pixel_format     = missing,
            color_model      = color_model,        # `missing` or a ColorModel code
            channel_datatype = channel_datatype)
end

# `collect` densifies the permuted view so the byte reinterpret sees contiguous
# storage; `Vector{UInt8}` then copies into the blob the ImageBuffer owns.
@inline _to_blob_bytes(buf::AbstractVector) = Vector{UInt8}(reinterpret(UInt8, collect(buf)))

# Rerun's HWC row-major order is channel fastest, then width, then height —
# exactly column-major `vec` of a (C, W, H) permutedims. Multi-channel
# channelview is (C, H, W); single-channel is (H, W).
@inline _hwc_vec(cv::AbstractArray{<:Any,3}) = vec(permutedims(cv, (1, 3, 2)))
@inline _hwc_vec(cv::AbstractMatrix)          = vec(permutedims(cv, (2, 1)))

# Color image -> Image (RGB family; gray matrices route to DepthImage).
function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   img::AbstractMatrix{C}; inject_time::Bool=true) where {C<:Colorant}
    C <: AbstractGray &&
        return _log_single(r, entity_path, img, DepthImage; inject_time=inject_time)

    height, width = size(img)
    cv = channelview(img)                      # (nchannels, H, W), canonical RGBA order
    nch = size(cv, 1)
    color_model = nch == 4 ? COLOR_MODEL_RGBA :
                  nch == 3 ? COLOR_MODEL_RGB  :
                  error("RerunImageCoreExt: unsupported channel count $nch for Image (expected 3 or 4)")
    cdt = _channel_datatype(eltype(cv))
    blob = _to_blob_bytes(_hwc_vec(cv))
    fmt  = _image_format(width, height, color_model, cdt)
    Rerun.log(r, entity_path, Image([ImageBuffer(blob)], [fmt]); inject_time=inject_time)
    return r
end

# Single-channel matrices: floats -> DepthImage, integers -> SegmentationImage.
function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   img::AbstractMatrix{<:AbstractFloat}; inject_time::Bool=true)
    return _log_single(r, entity_path, img, DepthImage; inject_time=inject_time)
end

function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   img::AbstractMatrix{<:Integer}; inject_time::Bool=true)
    return _log_single(r, entity_path, img, SegmentationImage; inject_time=inject_time)
end

# Shared single-channel path for DepthImage / SegmentationImage and Gray images.
function _log_single(r::Rerun.RecordingStream, entity_path::AbstractString,
                     img::AbstractMatrix, ::Type{A}; inject_time::Bool=true) where {A}
    height, width = size(img)
    # `channelview` of a Gray matrix is (H,W), same as a plain numeric matrix.
    cv  = channelview(img)
    cdt = _channel_datatype(eltype(cv))
    blob = _to_blob_bytes(_hwc_vec(cv))
    fmt  = _image_format(width, height, missing, cdt)   # single-channel: no color model
    buffer = [ImageBuffer(blob)]
    format = [fmt]
    Rerun.log(r, entity_path, A(buffer, format); inject_time=inject_time)
    return r
end

end # module RerunImageCoreExt
