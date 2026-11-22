# Nanosecond timestamps. Julia's DateTime stops at milliseconds, while sensor
# and robot logs record micro- or nanoseconds (ROS stamps, IMU samples), so
# such values get their own type, exported as Arrow timestamp[ns].

"""
    Timestamp(ns::Int64)

A UTC instant with nanosecond precision: nanoseconds since 1970-01-01T00:00:00,
without a time zone. Covers the years 1677 to 2262.
"""
struct Timestamp
    ns::Int64
end

Timestamp(d::DateTime) = Timestamp(Base.checked_mul(Dates.value(d - DateTime(1970)), 1_000_000))
Timestamp(d::Date) = Timestamp(DateTime(d))
Dates.DateTime(t::Timestamp) = DateTime(1970) + Millisecond(fld(t.ns, 1_000_000))
Base.isless(a::Timestamp, b::Timestamp) = isless(a.ns, b.ns)
Base.tryparse(::Type{Timestamp}, s::AbstractString) = parse_timestamp(s)
Base.show(io::IO, t::Timestamp) =
    print(io, Dates.format(DateTime(t), "yyyy-mm-ddTHH:MM:SS"), ".", lpad(mod(t.ns, 1_000_000_000), 9, '0'))

# ISO 8601 with up to nine fraction digits; 'T' or a space, optional 'Z'
const ISO_TIMESTAMP = r"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:[.,](\d{1,9}))?Z?$"

"""
    parse_timestamp(s) -> Union{Timestamp, Nothing}

`s` as a `Timestamp` if it is an ISO 8601 date and time, with up to nine
fraction digits (`2024-01-31T10:30:00.123456789`, `2024-01-31 10:30:00.5Z`).
"""
function parse_timestamp(s::AbstractString)
    m = match(ISO_TIMESTAMP, s)
    m === nothing && return nothing
    y, mo, d, h, mi, sec = (parse(Int, m.captures[i]) for i in 1:6)
    (1 <= mo <= 12 && 1 <= d <= daysinmonth(y, mo) && h < 24 && mi < 60 && sec < 60) || return nothing
    frac = m.captures[7] === nothing ? 0 : parse(Int, rpad(m.captures[7], 9, '0'))
    whole = Dates.value(DateTime(y, mo, d, h, mi, sec) - DateTime(1970)) ÷ 1000  # seconds
    ns = Base.Checked.checked_add(Base.Checked.checked_mul(whole, 1_000_000_000), frac)
    return Timestamp(ns)
end

"Whether `s` has more than three fraction digits, i.e. needs more than DateTime's milliseconds."
sub_millisecond(s::AbstractString) = (m = match(ISO_TIMESTAMP, s); m !== nothing && m.captures[7] !== nothing && length(m.captures[7]) > 3)

const EPOCH_UNITS = Dict("s" => 1_000_000_000, "ms" => 1_000_000, "us" => 1_000, "ns" => 1)

"""
    epoch_timestamp(x, scale) -> Union{Timestamp, Nothing}

A number of seconds, milliseconds, ... since 1970 (`scale` nanoseconds per
unit) as a `Timestamp`; `nothing` if it does not fit. Integers convert
exactly. A Float64 holds about 16 significant digits, so present-day epoch
seconds with a fraction resolve to about 0.25 µs; store nanoseconds as
integers when every digit matters.
"""
function epoch_timestamp(x::Real, scale::Int)
    x isa Bool && return nothing
    if x isa Integer
        ns = Int128(x) * scale  # x fits Int64/UInt64 and scale <= 1e9: no Int128 overflow
        return typemin(Int64) <= ns <= typemax(Int64) ? Timestamp(Int64(ns)) : nothing
    end
    isfinite(x) || return nothing
    # Whole units and the fraction separately: 1.7e9 s * 1e9 as one Float64
    # product would be off by up to 128 ns
    whole = floor(Float64(x))
    abs(whole) < 9.2e18 / scale || return nothing
    ns = Int128(whole) * scale + round(Int128, (Float64(x) - whole) * scale)
    return typemin(Int64) <= ns <= typemax(Int64) ? Timestamp(Int64(ns)) : nothing
end
function epoch_timestamp(x::AbstractString, scale::Int)
    i = tryparse(Int64, x)  # integers exactly; anything else through Float64
    i === nothing || return epoch_timestamp(i, scale)
    v = tryparse(Float64, x)
    return v === nothing ? nothing : epoch_timestamp(v, scale)
end
epoch_timestamp(x, ::Int) = nothing
