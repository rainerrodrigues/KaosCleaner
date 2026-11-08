# Type inference for text columns CSV.jl leaves as strings, and imputation.

using Dates, Statistics

const TRUE_STRINGS = ("true", "t", "yes", "y", "1")
const FALSE_STRINGS = ("false", "f", "no", "n", "0")

"""
    infer_bool(col) -> Union{Nothing, Vector}

`col` as booleans if every value is a yes/no-style word ("Yes", "F", "y",
"0", ...), else `nothing`.
"""
function infer_bool(col::AbstractVector)
    out = Vector{Union{Missing, Bool}}(undef, length(col))
    seen = false
    for (i, x) in enumerate(col)
        if ismissing(x)
            out[i] = missing
            continue
        end
        ncodeunits(x) <= 5 || return nothing
        word = lowercase(x)
        if word in TRUE_STRINGS
            out[i] = true
        elseif word in FALSE_STRINGS
            out[i] = false
        else
            return nothing
        end
        seen = true
    end
    return seen ? out : nothing
end

# Formats CSV.jl does not detect by itself. Day-first and month-first formats
# both appear; when both fit a column (01/02/2024) it is left as text.
const DATETIME_FORMATS = [
    "yyyy-mm-dd HH:MM:SS", "yyyy-mm-dd HH:MM", "yyyy/mm/dd", "yyyy/mm/dd HH:MM:SS",
    "dd/mm/yyyy", "mm/dd/yyyy", "dd/mm/yyyy HH:MM:SS", "mm/dd/yyyy HH:MM:SS",
    "dd/mm/yyyy HH:MM", "mm/dd/yyyy HH:MM", "dd.mm.yyyy", "dd-mm-yyyy",
    "dd u yyyy", "u dd, yyyy", "dd U yyyy", "U dd, yyyy",
]

has_time(fmt::AbstractString) = occursin('H', fmt)

function try_datetime(s::AbstractString, df::DateFormat, with_time::Bool)
    with_time ? tryparse(DateTime, s, df) : tryparse(Date, s, df)
end

"""
    infer_datetime(col, user_formats) -> Union{Nothing, Tuple{Vector, String}}

`col` parsed as `Date`/`DateTime`, with the format used, if one format fits
every value, else `nothing`. `user_formats` are tried alone when given;
otherwise a format is only used if no other default format reads the values
differently.
"""
function infer_datetime(col::AbstractVector, user_formats::Vector{String})
    # The first 200 values decide the format; collect only those (copying the
    # whole column cost ~25 ms per million rows)
    sample = String[]
    for x in col
        ismissing(x) && continue
        push!(sample, String(x))
        length(sample) == 200 && break
    end
    isempty(sample) && return nothing
    formats = isempty(user_formats) ? DATETIME_FORMATS : user_formats
    fits = String[]
    parsed = Vector{Any}[]
    for fmt in formats
        df, t = DateFormat(fmt), has_time(fmt)
        p = [try_datetime(s, df, t) for s in sample]
        any(isnothing, p) && continue
        push!(fits, fmt)
        push!(parsed, p)
        isempty(user_formats) || break  # user formats: first fit wins
    end
    isempty(fits) && return nothing
    # Two default formats reading the sample differently: ambiguous (dd/mm vs mm/dd)
    all(p -> p == parsed[1], parsed) || return nothing
    df, t = DateFormat(fits[1]), has_time(fits[1])
    T = t ? DateTime : Date
    out = Vector{Union{Missing, T}}(undef, length(col))
    for (i, x) in enumerate(col)
        if ismissing(x)
            out[i] = missing
        else
            v = try_datetime(x, df, t)
            v === nothing && return nothing
            out[i] = v
        end
    end
    return out, fits[1]
end

const FORMATTED_NUMBER = r"^[-+]?[$€£¥]?[-+]?(\d{1,3}(,\d{3})+|\d+)(\.\d+)?$"
const NUMBER_DECORATION = r"[$€£¥,]"

"""
    infer_number(col) -> Union{Nothing, Vector}

`col` as numbers if every value is a number with a currency sign and/or
thousands separators ("\$1,250.00", "€12", "3,400"), else `nothing`.
"""
function infer_number(col::AbstractVector)
    decorated = false
    integral = true
    for x in col
        ismissing(x) && continue
        occursin(FORMATTED_NUMBER, x) || return nothing
        decorated |= occursin(NUMBER_DECORATION, x)
        integral &= !occursin('.', x)
    end
    decorated || return nothing  # plain numbers: CSV.jl would have parsed them
    T = integral ? Int64 : Float64
    out = Vector{Union{Missing, T}}(undef, length(col))
    for (i, x) in enumerate(col)
        if ismissing(x)
            out[i] = missing
        else  # tryparse: integers beyond Int64 leave the column as text
            v = tryparse(T, replace(x, NUMBER_DECORATION => ""))
            v === nothing && return nothing
            out[i] = v
        end
    end
    return out
end

# A conversion chosen by inference, so streaming can apply the same one to
# every later chunk (see streaming.jl).
abstract type Conversion end
struct ToBool <: Conversion end
struct ToNumber <: Conversion
    T::DataType
end
struct ToTimestamp <: Conversion end
"Numbers since 1970 in a unit of `scale` nanoseconds."
struct FromEpoch <: Conversion
    scale::Int
end
struct ToDate <: Conversion
    format::String
    dateformat::DateFormat
    T::DataType
end
ToDate(format::String) = ToDate(format, DateFormat(format), has_time(format) ? DateTime : Date)

output_type(::ToBool) = Bool
output_type(::Union{ToTimestamp, FromEpoch}) = Timestamp
output_type(c::Union{ToNumber, ToDate}) = c.T

"`col` converted and the conversion used, or `nothing` if no conversion fits."
function infer_column(col::AbstractVector, opts::CleanOptions)
    b = infer_bool(col)
    b === nothing || return b, ToBool()
    n = infer_number(col)
    n === nothing || return n, ToNumber(nonmissingtype(eltype(n)))
    if isempty(opts.datetime_formats)
        t = infer_timestamp(col)
        t === nothing || return t, ToTimestamp()
    end
    d = infer_datetime(col, opts.datetime_formats)
    d === nothing || return d[1], ToDate(d[2])
    return nothing
end

"""
    infer_timestamp(col) -> Union{Nothing, Vector}

`col` as nanosecond `Timestamp`s if every value is an ISO 8601 date and time
and at least one has a fraction of a second CSV.jl did not read
(`2024-01-31T10:30:00.123456`, `2024-01-31 10:30:00.25`), else `nothing`.
"""
function infer_timestamp(col::AbstractVector)
    out = Vector{Union{Missing, Timestamp}}(undef, length(col))
    fraction = false
    for (i, x) in enumerate(col)
        if ismissing(x)
            out[i] = missing
            continue
        end
        t = parse_timestamp(x)
        t === nothing && return nothing
        fraction |= t.ns % 1_000_000_000 != 0 || occursin('.', x) || occursin(',', x)
        out[i] = t
    end
    return fraction ? out : nothing
end

"""
    apply_epochs!(df, opts) -> Dict{String, Conversion}

Convert the columns named in `opts.epoch` (numbers since 1970) to `Timestamp`s.
"""
function apply_epochs!(df::DataFrame, opts::CleanOptions)
    conversions = Dict{String, Conversion}()
    for (name, unit) in opts.epoch
        name in names(df) || throw(ArgumentError("epoch: no column named $name; columns are: $(join(names(df), ", "))"))
        col = df[!, name]
        T = nonmissingtype(eltype(col))
        (T === Union{} || (T <: Real && !(T <: Bool))) ||
            throw(ArgumentError("epoch: `$name` must hold numbers, it is $T"))
        c = FromEpoch(EPOCH_UNITS[unit])
        out, failures = apply_conversion(c, col)
        failures > 0 && @warn "$failures value$(failures == 1 ? "" : "s") in `$name` were out of range for a timestamp and became missing"
        df[!, name] = out
        conversions[name] = c
        @info "Converted column `$name` from $unit since 1970 to timestamps"
    end
    return conversions
end

"""
    infer_types!(df, opts) -> Dict{String, Conversion}

Convert text columns that hold booleans, dates or formatted numbers; returns
the conversion applied to each converted column.
"""
function infer_types!(df::DataFrame, opts::CleanOptions)
    conversions = Dict{String, Conversion}()
    for name in names(df)
        col = df[!, name]
        T = nonmissingtype(eltype(col))
        (T <: AbstractString && T !== Union{}) || continue
        result = infer_column(col, opts)
        result === nothing && continue
        df[!, name], conversions[name] = result
        @info "Converted column `$name` from text to $(nameof(output_type(result[2])))"
    end
    return conversions
end

# Applying a known conversion to new data: values that do not fit become
# missing (and are counted) instead of abandoning the conversion.
convert_value(::ToBool, x) = (w = lowercase(x); w in TRUE_STRINGS ? true : w in FALSE_STRINGS ? false : nothing)
convert_value(c::ToNumber, x) =
    occursin(FORMATTED_NUMBER, x) ? tryparse(c.T, replace(x, NUMBER_DECORATION => "")) : nothing
convert_value(c::ToDate, x) = try_datetime(x, c.dateformat, c.T === DateTime)
convert_value(::ToTimestamp, x) = parse_timestamp(x)
convert_value(c::FromEpoch, x) = epoch_timestamp(x, c.scale)

"""
    apply_conversion(c, col) -> (Vector, failures)

`col` converted with `c`; values that do not fit become missing.
"""
function apply_conversion(c::Conversion, col::AbstractVector)
    T = output_type(c)
    out = Vector{Union{Missing, T}}(undef, length(col))
    failures = 0
    for (i, x) in enumerate(col)
        v = ismissing(x) ? missing : convert_value(c, x)
        v === nothing && (failures += 1; v = missing)
        out[i] = v
    end
    return out, failures
end

# ---------------------------------------------------------------------------
# Imputation

"""
    impute!(df, opts)

Fill missing values per `opts.impute`. A single strategy applies to every
column it suits (mean/median/zero to numeric columns only); a per-column
strategy that does not suit its column is an error.
"""
function impute!(df::DataFrame, opts::CleanOptions)
    opts.impute === nothing && return df
    explicit = opts.impute isa Dict
    plan = explicit ? opts.impute : Dict(n => opts.impute for n in names(df))
    if explicit
        missing_cols = setdiff(keys(plan), names(df))
        isempty(missing_cols) || throw(ArgumentError("impute: no column named $(join(sort(collect(missing_cols)), ", "))"))
    end
    for (name, strategy) in plan
        col = df[!, name]
        any(ismissing, col) || continue
        numeric = nonmissingtype(eltype(col)) <: Real && !(nonmissingtype(eltype(col)) <: Bool)
        if strategy in ("mean", "median", "zero", "interpolate") && !numeric
            explicit && throw(ArgumentError("impute: `$strategy` needs a numeric column, `$name` is $(nonmissingtype(eltype(col)))"))
            continue
        end
        n = count(ismissing, col)
        df[!, name] = impute(col, strategy)
        filled = n - count(ismissing, df[!, name])
        filled > 0 && @info "Imputed $filled missing value$(filled == 1 ? "" : "s") in `$name` ($strategy)"
    end
    return df
end

function impute(col::AbstractVector, strategy::String)
    present = collect(skipmissing(col))
    isempty(present) && return col  # nothing to fill from
    if strategy in ("ffill", "bfill")
        return fill_direction(col, strategy == "ffill")
    end
    strategy == "zero" && return fill_zero(col)
    strategy == "interpolate" && return interpolate_linear(col)
    value = strategy == "mean" ? mean(present) :
            strategy == "median" ? median(present) :
            mode_value(present)
    T = promote_type(nonmissingtype(eltype(col)), typeof(value))
    return T[ismissing(x) ? value : x for x in col]
end

function mode_value(values::AbstractVector)
    counts = Dict{eltype(values), Int}()
    best, best_n = first(values), 0
    for v in values  # ties go to the value that reached the top count first
        n = counts[v] = get(counts, v, 0) + 1
        n > best_n && ((best, best_n) = (v, n))
    end
    return best
end

"""
    interpolate_linear(col) -> Vector{Union{Missing, Float64}}

Missing values between two present ones filled on the straight line between
them, by row position (rows are assumed evenly spaced, as for a sensor sampled
at a fixed rate). Missing values before the first or after the last present
value stay missing.
"""
function interpolate_linear(col::AbstractVector)
    out = Vector{Union{Missing, Float64}}(undef, length(col))
    prev = 0  # index of the last present value
    for i in eachindex(col)
        x = col[i]
        if ismissing(x)
            out[i] = missing
            continue
        end
        out[i] = Float64(x)
        if prev > 0 && i - prev > 1
            a, b = out[prev], out[i]
            for k in prev+1:i-1
                out[k] = a + (b - a) * (k - prev) / (i - prev)
            end
        end
        prev = i
    end
    return out
end

"Missing values of a numeric column replaced by zero."
fill_zero(col::AbstractVector) =
    (T = nonmissingtype(eltype(col)); T[ismissing(x) ? zero(T) : x for x in col])

"""
    fill_forward(col, start=missing) -> (filled, last)

Missing values replaced by the previous value (`start` before the first one),
and the last value, which streaming carries into the next batch.
"""
function fill_forward(col::AbstractVector, start=missing)
    out = Vector{eltype(col)}(col)
    last = start
    for i in eachindex(out)
        ismissing(out[i]) ? (out[i] = last) : (last = out[i])
    end
    return out, last
end

fill_direction(col::AbstractVector, forward::Bool) =
    forward ? first(fill_forward(col)) : reverse(first(fill_forward(reverse(col))))
