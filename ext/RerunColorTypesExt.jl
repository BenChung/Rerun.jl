# RerunColorTypesExt — maps ColorTypes.jl colorants to Rerun's `Color` component.
#
# Follows the canonical extension convention (see RerunStaticArraysExt.jl):
#
#   1. NO TYPE PIRACY. Every method added here attaches either to the
#      `Rerun.Components.Color` constructor or to `Rerun.log` — both OWNED by
#      Rerun — and dispatches on `ColorTypes.Colorant`, a type OWNED by
#      ColorTypes. We never define a method whose function AND all argument
#      types are foreign.
#
#   2. ALWAYS COPIES. Rerun's `Color` is a single `UInt32` packed as
#      `0xRRGGBBAA` (red in the most-significant byte). A `Colorant` is laid out
#      per channel (and channel ORDER varies: RGBA vs ARGB vs BGRA vs ...), in a
#      variety of eltypes (`N0f8`, `Float32`, `Float64`, ...). There is no eltype
#      whose contiguous bit layout already equals `0xRRGGBBAA`, so we ALWAYS
#      build the `UInt32` explicitly via the `red()/green()/blue()/alpha()`
#      accessors. The `Vector{<:Colorant}` batch path therefore COPIES into a
#      fresh `Vector{Color}`. This is documented and intentional — silently
#      reinterpreting a colorant would scramble channels.
#
#   3. CHANNEL ORDER IS LOOKED UP, NOT ASSUMED. We use `ColorTypes.red/green/
#      blue/alpha` accessors so ARGB/BGRA/RGBA all pack correctly regardless of
#      in-memory field order. `Gray` maps to r=g=b=value; alpha-less colorants
#      (`RGB`, `Gray`, `BGR`, ...) get alpha = 0xff.
#
#   4. SCOPE = RGB-FAMILY + GRAY. `red/green/blue` are only defined on
#      `AbstractRGB`, and `gray` only on `AbstractGray`. We dispatch on exactly
#      those (and their transparent variants). Non-RGB color spaces (HSV, Lab,
#      ...) require a prior `convert(RGB, c)` via Colors.jl, because ColorTypes.jl
#      alone cannot convert them. Restricting dispatch to RGB-family and gray
#      raises a clear MethodError on an unconvertible color space.
module RerunColorTypesExt

using Rerun
using ColorTypes

# `Color` is OWNED by Rerun, so adding constructor methods to it is not piracy.
# `import` is the sanctioned form for extending a name: on Julia 1.12,
# extending the `Color` constructor when it is brought in by `using` warns and
# deprecates. `import Rerun.Components: Color` also resolves the name-collision
# with `ColorTypes.Color` (an abstract type we never reference directly).
import Rerun.Components: Color

# Fixed-point N0f8 channels are normalized 8-bit (a `UInt8`-backed value in
# [0,1]); `reinterpret(UInt8, c)` recovers the raw 0..255 byte with no rounding.
using ColorTypes.FixedPointNumbers: N0f8

# ---------------------------------------------------------------------------
# Layout invariant (checked at precompile time, not the hot path).
# ---------------------------------------------------------------------------
@assert isbitstype(Color)            "Color must be isbits"
@assert sizeof(Color) == sizeof(UInt32) "Color is a single packed UInt32 (0xRRGGBBAA)"

# ===========================================================================
# Per-channel -> UInt8 byte.
#
# A colorant channel is a real number in [0,1] (`AbstractFloat`) or a normalized
# fixed-point value (`N0f8`, ...). We need the 0..255 byte.
#   * `N0f8` is already an 8-bit byte: reinterpret to its raw `UInt8` — exact, no
#     rounding (1.0 -> 0xff, 0.0 -> 0x00).
#   * other fixed-point / float channels: scale by 255, round, clamp to [0,255].
# ===========================================================================
@inline _chan_byte(x::N0f8)::UInt8 = reinterpret(UInt8, x)
@inline function _chan_byte(x::Real)::UInt8
    return round(UInt8, clamp(Float64(x), 0.0, 1.0) * 255)
end

# ===========================================================================
# Scalar constructor:  Rerun.Components.Color(::Colorant)
#
# Method on a Rerun-owned constructor, dispatching on a ColorTypes-owned type.
# Channels are pulled by SEMANTIC accessor (red/green/blue/alpha), so the
# physical field order of the concrete colorant (RGBA, ARGB, BGRA, ...) does not
# matter. Packs 0xRRGGBBAA = r<<24 | g<<16 | b<<8 | a.
# ===========================================================================

# RGB-family with alpha (`RGBA`, `ARGB`, `BGRA`, `RGB24`+A, ...): channel ORDER
# in memory differs per type, but `red/green/blue/alpha` are semantic, so this
# packs correctly for all of them.
function Color(c::TransparentRGB)
    r = _chan_byte(red(c)); g = _chan_byte(green(c))
    b = _chan_byte(blue(c)); a = _chan_byte(alpha(c))
    return Color(_pack(r, g, b, a))
end

# Opaque RGB-family (`RGB`, `BGR`, `RGB24`, ...): no alpha -> 0xff.
function Color(c::AbstractRGB)
    r = _chan_byte(red(c)); g = _chan_byte(green(c)); b = _chan_byte(blue(c))
    return Color(_pack(r, g, b, 0xff))
end

# Transparent gray (`GrayA`, `AGray`, `AGray32`): r=g=b=value, real alpha.
# (Checked before the opaque `AbstractGray` method — more specific.)
function Color(c::TransparentGray)
    v = _chan_byte(gray(c)); a = _chan_byte(alpha(c))
    return Color(_pack(v, v, v, a))
end

# Opaque gray (`Gray`, `Gray24`): single channel -> r=g=b=value, alpha 0xff.
# `red/green/blue` are NOT defined on grays, only `gray`, so this needs its own
# method rather than reusing the RGB path.
function Color(c::AbstractGray)
    v = _chan_byte(gray(c))
    return Color(_pack(v, v, v, 0xff))
end

@inline _pack(r::UInt8, g::UInt8, b::UInt8, a::UInt8)::UInt32 =
    (UInt32(r) << 24) | (UInt32(g) << 16) | (UInt32(b) << 8) | UInt32(a)

# ===========================================================================
# Batch path:  Rerun.log(rec, path, data::AbstractVector{<:Colorant})
#
# Method on Rerun.log dispatching on a ColorTypes-owned eltype. Element-wise
# `Color(c)` -> fresh `Vector{Color}`, then routed through the existing
# materialized-batch `Rerun.log`. This COPIES (channel reorder + scaling); there
# is no zero-copy path for colorants. Keeps and forwards `inject_time`.
# ===========================================================================
function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   data::AbstractVector{<:Colorant}; inject_time::Bool=true)
    colors = Color[Color(c) for c in data]
    Rerun.log(r, entity_path, colors; inject_time=inject_time)
end

end # module RerunColorTypesExt
