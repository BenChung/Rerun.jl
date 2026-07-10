# Canonical time representations for Rerun timelines. The wire format is
# Int64 nanoseconds on every timeline kind; each kind gets a bijective Julia
# type, and convenience conversions (DateTime, Dates.Period) are exact or
# throw — precision loss is always explicit.
#
#   kind        wire Int64                     canonical type
#   :sequence   sequence number                Int64
#   :duration   elapsed nanoseconds            Dates.Nanosecond
#   :timestamp  nanoseconds since Unix epoch   TimePoint

using Dates

"""
    TimePoint(ns::Integer)
    TimePoint(dt::DateTime)

An instant with nanosecond precision: `ns` nanoseconds since the Unix epoch
(1970-01-01T00:00:00 UTC) — the exact wire value of Rerun timestamp timelines.
`TimePoint(dt)` is always exact (milliseconds ⊂ nanoseconds). `DateTime(ts)`
succeeds when `ts` is millisecond-aligned and throws `InexactError` otherwise;
`round(DateTime, ts)` (or `floor`/`ceil`) converts lossily on purpose.
Arithmetic with `Dates.FixedPeriod` is exact: `ts + Nanosecond(1)`,
`ts2 - ts1 :: Nanosecond`.
"""
struct TimePoint
    ns::Int64
end
TimePoint(dt::DateTime) = TimePoint(Base.checked_mul(Dates.value(dt) - Dates.UNIXEPOCH, 1_000_000))
TimePoint(ts::TimePoint) = ts

function Dates.DateTime(ts::TimePoint)
    ms, sub = fldmod(ts.ns, 1_000_000)
    sub == 0 || throw(InexactError(:DateTime, DateTime, ts))
    return DateTime(Dates.UTM(ms + Dates.UNIXEPOCH))
end
Base.round(::Type{DateTime}, ts::TimePoint, r::RoundingMode=RoundNearest) =
    DateTime(Dates.UTM(div(ts.ns, 1_000_000, r) + Dates.UNIXEPOCH))
Base.floor(::Type{DateTime}, ts::TimePoint) = round(DateTime, ts, RoundDown)
Base.ceil(::Type{DateTime}, ts::TimePoint)  = round(DateTime, ts, RoundUp)

Base.:+(ts::TimePoint, p::Dates.FixedPeriod) = TimePoint(Base.checked_add(ts.ns, Dates.value(Nanosecond(p))))
Base.:+(p::Dates.FixedPeriod, ts::TimePoint) = ts + p
Base.:-(ts::TimePoint, p::Dates.FixedPeriod) = TimePoint(Base.checked_sub(ts.ns, Dates.value(Nanosecond(p))))
Base.:-(a::TimePoint, b::TimePoint) = Nanosecond(Base.checked_sub(a.ns, b.ns))
Base.isless(a::TimePoint, b::TimePoint) = a.ns < b.ns
Base.Broadcast.broadcastable(ts::TimePoint) = (ts,)   # scalar in broadcasts (isbits tuple: no allocation)

function Base.show(io::IO, ts::TimePoint)
    dt = floor(DateTime, ts)
    sub = ts.ns - TimePoint(dt).ns
    print(io, "TimePoint(", dt)
    sub == 0 || print(io, " + ", sub, "ns")
    print(io, ")")
end

"""
    Timeline{T}(name)
    Timeline(name; kind=:sequence)
    Timeline(name, kind::Symbol)

A named index timeline whose time values have type `T` — the canonical
representation of its kind: `Int64` (`:sequence`), `Nanosecond` (`:duration`),
[`TimePoint`](@ref) (`:timestamp`). Accepted wherever a timeline name string
is; carrying the representation with the name lets `set_time` / `TimeColumn` /
`filter_range` convert and kind-check time values by dispatch, and queries
decode the timeline's column with `eltype == T`.
"""
struct Timeline{T<:Union{Int64,Nanosecond,TimePoint}}
    name::String
    Timeline{T}(name::AbstractString) where {T<:Union{Int64,Nanosecond,TimePoint}} =
        new{T}(String(name))
end

const _KIND_TYPES = (sequence = Int64, duration = Nanosecond, timestamp = TimePoint)

function Timeline(name::AbstractString; kind::Symbol=:sequence)
    haskey(_KIND_TYPES, kind) ||
        error("unknown time kind $kind; expected :sequence, :duration, or :timestamp")
    return Timeline{_KIND_TYPES[kind]}(name)
end
Timeline(name::AbstractString, kind::Symbol) = Timeline(name; kind)

Base.eltype(::Type{Timeline{T}}) where {T} = T
Base.:(==)(a::Timeline, b::Timeline) = typeof(a) === typeof(b) && a.name == b.name
Base.hash(t::Timeline{T}, h::UInt) where {T} = hash(t.name, hash(T, h))

"""The time kind of a [`Timeline`](@ref) or of a canonical time value type:
`:sequence`, `:duration`, or `:timestamp`."""
kind(::Type{Int64}) = :sequence
kind(::Type{Nanosecond}) = :duration
kind(::Type{TimePoint}) = :timestamp
kind(::Timeline{T}) where {T} = kind(T)

_timeline_name(t::Timeline) = t.name
_timeline_name(s::AbstractString) = s

"""
    _time_value(tl::Timeline, v) -> Int64

Wire value of `v` on `tl` — the write-side conversion + kind check. `Integer`
passes through raw on every kind (nanoseconds for duration/timestamp); typed
values convert exactly per the timeline's representation.
"""
_time_value(::Timeline, v::Integer) = Int64(v)
_time_value(::Timeline{Nanosecond}, p::Dates.FixedPeriod) = Dates.value(Nanosecond(p))
_time_value(::Timeline{TimePoint}, ts::TimePoint) = ts.ns
_time_value(::Timeline{TimePoint}, dt::DateTime) = TimePoint(dt).ns
_time_value(tl::Timeline{T}, v) where {T} =
    error("timeline $(repr(tl.name)) is $(kind(tl))-valued ($T); cannot take a $(typeof(v)) time value")
