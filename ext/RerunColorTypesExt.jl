# RerunColorTypesExt — maps ColorTypes.jl colorants to Rerun's `Color`
# component (a UInt32 packed 0xRRGGBBAA). Extension convention: see
# RerunStaticArraysExt.jl.
#
# Channels are read through the semantic accessors (red/green/blue/alpha), so
# any in-memory channel order (RGBA, ARGB, BGRA, ...) packs correctly — and no
# colorant layout matches the packed UInt32, so every conversion copies.
# Scope is the RGB family plus gray: `red/green/blue` exist only on
# `AbstractRGB` and `gray` on `AbstractGray`; other color spaces (HSV, Lab, ...)
# need a prior `convert(RGB, c)` via Colors.jl and otherwise get a MethodError.
module RerunColorTypesExt

using Rerun
using ColorTypes

# `import` so extending the constructor is unambiguous (extending a `using`-ed
# binding deprecates on Julia 1.12); also dodges the `ColorTypes.Color` name clash.
import Rerun.Components: Color

# N0f8 is a normalized 8-bit value; `reinterpret(UInt8, c)` is the exact 0..255 byte.
using ColorTypes.FixedPointNumbers: N0f8

# Wire-layout tripwire: a schema regen that changes Color fails precompile here.
@assert isbitstype(Color)            "Color must be isbits"
@assert sizeof(Color) == sizeof(UInt32) "Color is a single packed UInt32 (0xRRGGBBAA)"

# Channel value in [0,1] -> 0..255 byte: N0f8 reinterprets exactly; floats
# scale, round, clamp.
@inline _chan_byte(x::N0f8)::UInt8 = reinterpret(UInt8, x)
@inline function _chan_byte(x::Real)::UInt8
    return round(UInt8, clamp(Float64(x), 0.0, 1.0) * 255)
end

# RGB family with alpha (RGBA, ARGB, BGRA, ...).
function Color(c::TransparentRGB)
    r = _chan_byte(red(c)); g = _chan_byte(green(c))
    b = _chan_byte(blue(c)); a = _chan_byte(alpha(c))
    return Color(_pack(r, g, b, a))
end

# Opaque RGB family: alpha = 0xff.
function Color(c::AbstractRGB)
    r = _chan_byte(red(c)); g = _chan_byte(green(c)); b = _chan_byte(blue(c))
    return Color(_pack(r, g, b, 0xff))
end

# Transparent gray: r=g=b=value, real alpha.
function Color(c::TransparentGray)
    v = _chan_byte(gray(c)); a = _chan_byte(alpha(c))
    return Color(_pack(v, v, v, a))
end

# Opaque gray: r=g=b=value, alpha 0xff.
function Color(c::AbstractGray)
    v = _chan_byte(gray(c))
    return Color(_pack(v, v, v, 0xff))
end

@inline _pack(r::UInt8, g::UInt8, b::UInt8, a::UInt8)::UInt32 =
    (UInt32(r) << 24) | (UInt32(g) << 16) | (UInt32(b) << 8) | UInt32(a)

# A colorant batch copies into a fresh Vector{Color}.
function Rerun.log(r::Rerun.RecordingStream, entity_path::AbstractString,
                   data::AbstractVector{<:Colorant}; inject_time::Bool=true)
    colors = Color[Color(c) for c in data]
    Rerun.log(r, entity_path, colors; inject_time=inject_time)
end

end # module RerunColorTypesExt
