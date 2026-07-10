# RerunImageCoreExt — maps ImageCore.jl / ColorTypes.jl 2D image arrays to
# Rerun's image archetypes (`Image`, `DepthImage`, `SegmentationImage`).
#
# Follows the canonical extension convention (see RerunStaticArraysExt.jl and
# RerunColorTypesExt.jl):
#
#   1. NO TYPE PIRACY. Every method added here attaches to `Rerun.log` — a
#      function OWNED by Rerun — and dispatches on a `Matrix` whose eltype is a
#      type OWNED by ColorTypes (`Colorant`/`Gray`) or `Base` (`AbstractFloat`,
#      `Integer`). We never define a method whose function AND all argument types
#      are foreign. (The `Matrix{<:AbstractFloat}` / `Matrix{<:Integer}` methods
#      dispatch on Base-owned eltypes, but the function `Rerun.log` is Rerun's, so
#      these are still legal — the method is anchored to a Rerun-owned function.)
#
#   2. NOT ZERO-COPY (layout transform). Julia arrays are COLUMN-major and a
#      `Matrix{<:Colorant}` is an array of pixel structs; Rerun images are
#      ROW-major, interleaved-pixel HWC byte buffers (see image.fbs:
#      "row-major, interleaved-pixel image format"). Reaching that layout from a
#      Julia matrix requires (a) splitting pixels into channels and (b)
#      reordering column-major (h,w) into row-major (h then w). Both copy. We
#      build the HWC byte buffer explicitly; reinterpreting a Julia matrix
#      straight into an image blob would be both transposed and, for
#      multi-channel colorants whose physical field order is not RGBA,
#      channel-scrambled.
#
#   3. CHANNEL ORDER IS LOOKED UP, NOT ASSUMED. `ImageCore.channelview` always
#      yields components in canonical R,G,B(,A) semantic order regardless of the
#      colorant's physical storage (BGR, ARGB, BGRA, ... all come out R,G,B,A).
#      So we declare ColorModel = RGB / RGBA purely from the channel count and let
#      `channelview` normalize the order — no per-model reordering, no scramble.
#
#   4. ORIENTATION IS PINNED. A Julia `img[i,j]` has i = row (height) and
#      j = column (width). Rerun wants width varying fastest within a row, then
#      the next row, with channels interleaved innermost. We produce that with
#      `permutedims(channelview, (channel, width, height))` + `vec`. The test
#      pins a non-square 2x3 image so a transpose bug is caught.
module RerunImageCoreExt

using Rerun
using ImageCore
using ColorTypes
using ColorTypes.FixedPointNumbers: Normed

using Rerun.Components: ImageBuffer
using Rerun.Archetypes: Image, DepthImage, SegmentationImage

# ---------------------------------------------------------------------------
# Rerun enum codes (from gen/idl/.../datatypes/{color_model,channel_datatype}.fbs).
# ImageFormat is a struct component logged as a NamedTuple
# (width::u32, height::u32, pixel_format::u8?, color_model::u8?, channel_datatype::u8?).
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Map the per-channel numeric/eltype of a `channelview` to a Rerun ChannelDatatype.
#
# `Normed{T,f}` (e.g. N0f8 = Normed{UInt8,8}, N0f16 = Normed{UInt16,16}) is a
# normalized fixed-point value whose RAW bytes are exactly its backing `T`. Rerun
# reads the raw bytes per the declared ChannelDatatype, so a `Normed{UInt8}` maps
# to U8 (0..255) and `Normed{UInt16}` to U16 — no rescaling, the raw bytes are
# already what the viewer expects.
# ---------------------------------------------------------------------------
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

# The byte width of the backing storage element (for blob sizing / asserts).
_storage_type(::Type{<:Normed{T}}) where {T} = T
_storage_type(::Type{T}) where {T<:Union{Integer,AbstractFloat}} = T

# ---------------------------------------------------------------------------
# Build an ImageFormat NamedTuple. Single-channel (depth/segmentation) images
# pass `color_model = missing` (the field is nullable); color images set RGB/RGBA.
# `pixel_format` is always null here (we never emit chroma-subsampled formats).
# ---------------------------------------------------------------------------
@inline function _image_format(width::Integer, height::Integer, color_model,
                               channel_datatype::UInt8)
    return (width            = UInt32(width),
            height           = UInt32(height),
            pixel_format     = missing,
            color_model      = color_model,        # `missing` or a ColorModel code
            channel_datatype = channel_datatype)
end

# ---------------------------------------------------------------------------
# Pack a contiguous typed buffer to the ImageBuffer's raw `Vector{UInt8}`.
# `buf` is already in HWC row-major element order; `reinterpret` to bytes is the
# wire layout Rerun expects (little-endian native, matching rerun_c on the host).
# `collect` materializes the permuted view into a dense contiguous Vector so the
# reinterpret is over real shared storage; then `Vector{UInt8}` copies into the
# blob the ImageBuffer owns.
# ---------------------------------------------------------------------------
@inline _to_blob_bytes(buf::AbstractVector) = Vector{UInt8}(reinterpret(UInt8, collect(buf)))

# ---------------------------------------------------------------------------
# Orientation core: a `channelview` slab + a Julia (height, width) shape into the
# HWC row-major element vector Rerun wants.
#
#   Julia img[i,j]: i = row (height), j = col (width).
#   channelview(img) for multi-channel -> (C, H, W); for 1-channel Gray -> (H, W).
#   Rerun HWC row-major byte index = (h*W + w)*C + c  (c fastest, then w, then h).
#
#   permutedims to (C, W, H) then column-major `vec` yields exactly that order:
#   c varies fastest, then w, then h. NO transpose of the image content.
# ---------------------------------------------------------------------------
# Multi-channel: cv is (C, H, W).
@inline _hwc_vec(cv::AbstractArray{<:Any,3}) = vec(permutedims(cv, (1, 3, 2)))
# Single-channel: cv is (H, W); reorder to row-major (w fastest then h) = (W, H).
@inline _hwc_vec(cv::AbstractMatrix)          = vec(permutedims(cv, (2, 1)))

# ===========================================================================
# Color image:  Rerun.log(rec, path, img::Matrix{<:Colorant}) -> Image
#
# Method on Rerun.log dispatching on a ColorTypes-owned eltype. Splits the pixel
# struct into channels (channelview, canonical R,G,B,A order), reorders to HWC
# row-major, and logs an `Image`. COPIES (channel split + transpose). We restrict
# to the RGB family (`AbstractRGB` and its transparent forms): those give 3 or 4
# channels in R,G,B[,A] order. `Gray` is handled by the DepthImage method below.
# ===========================================================================
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

# ===========================================================================
# Depth image:  Rerun.log(rec, path, img::Matrix{<:Gray|<:AbstractFloat}) -> DepthImage
# Segmentation: Rerun.log(rec, path, img::Matrix{<:Integer})            -> SegmentationImage
#
# Single-channel. `_log_single` reorders the (H,W) slab to HWC row-major (C=1) and
# emits a single-channel ImageFormat (color_model = null). COPIES (transpose).
# ===========================================================================
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
    # `channelview` of a Gray matrix drops the singleton channel dim -> (H,W);
    # a plain numeric matrix is already (H,W). Either way `_hwc_vec` handles the 2D case.
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
