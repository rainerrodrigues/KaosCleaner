# Cleaning steps for sensor and robot data: outlier removal, time-aware
# interpolation and resampling onto a fixed time grid.

const PERIOD = r"^(\d+)(ns|us|ms|s|min|h)$"
const PERIOD_UNITS = Dict("ns" => 1, "us" => 1_000, "ms" => 1_000_000, "s" => 1_000_000_000,
                          "min" => 60_000_000_000, "h" => 3_600_000_000_000)
"Resampling refuses to make more rows than this (a period far too small for the data)."
const MAX_RESAMPLED_ROWS = 50_000_000

"""
    period_ns(s) -> Int64

A period such as `"10ms"`, `"250us"`, `"1s"` or `"5min"` in nanoseconds.
"""
function period_ns(s::AbstractString)
    m = match(PERIOD, s)
    m === nothing && throw(ArgumentError("invalid period $(repr(s)); use a whole number and a unit: ns, us, ms, s, min, h (e.g. \"10ms\")"))
    n = Base.checked_mul(parse(Int64, m.captures[1]), PERIOD_UNITS[m.captures[2]])
    n > 0 || throw(ArgumentError("the period must be longer than zero"))
    return n
end

is_numeric_column(col) = (T = nonmissingtype(eltype(col)); T !== Union{} && T <: Real && !(T <: Bool))

to_ns(::Missing) = missing
to_ns(t::Timestamp) = t.ns
to_ns(d::DateTime) = Dates.value(d - DateTime(1970)) * 1_000_000
to_ns(d::Date) = to_ns(DateTime(d))

"""
    time_ns_column(df, opts) -> Union{Nothing, Vector{Union{Missing, Int64}}}

The values of `opts.time_column` in nanoseconds since 1970, or `nothing`
without a time column.
"""
function time_ns_column(df::DataFrame, opts::CleanOptions)
    name = opts.time_column
    name === nothing && return nothing
    name in names(df) || throw(ArgumentError("time_column: no column named $name; columns are: $(join(names(df), ", "))"))
    col = df[!, name]
    T = nonmissingtype(eltype(col))
    T <: Union{Timestamp, DateTime, Date} && T !== Union{} || throw(ArgumentError(
        "time_column `$name` must hold dates or timestamps, it is $T; for numbers since 1970 add epoch={\"$name\": unit}"))
    return Union{Missing, Int64}[to_ns(x) for x in col]
end

# ---------------------------------------------------------------------------
# Outliers

const OUTLIER_DEFAULTS = Dict("zscore" => 3.0, "iqr" => 1.5, "mad" => 3.5, "hampel" => 3.0)

"""
    remove_outliers!(df, opts)

Turn outliers into missing values per `opts.outliers`: one method for every
numeric column (except the time column), or a method per column.
"""
function remove_outliers!(df::DataFrame, opts::CleanOptions)
    opts.outliers === nothing && return df
    explicit = opts.outliers isa Dict
    plan = explicit ? opts.outliers : Dict(n => opts.outliers for n in names(df) if n != opts.time_column)
    if explicit
        unknown = setdiff(keys(plan), names(df))
        isempty(unknown) || throw(ArgumentError("outliers: no column named $(join(sort(collect(unknown)), ", "))"))
    end
    times = time_ns_column(df, opts)
    for (name, method) in plan
        col = df[!, name]
        if !is_numeric_column(col)
            explicit && throw(ArgumentError("outliers: `$name` must be numeric, it is $(nonmissingtype(eltype(col)))"))
            continue
        end
        k = something(opts.outlier_threshold, OUTLIER_DEFAULTS[method])
        mask = outlier_mask(col, method, k, opts.outlier_window, times)
        n = count(mask)
        n == 0 && continue
        out = Vector{Union{Missing, nonmissingtype(eltype(col))}}(col)
        out[mask] .= missing
        df[!, name] = out
        @info "Removed $n outlier$(n == 1 ? "" : "s") from `$name` ($method)"
    end
    return df
end

"""
    outlier_mask(col, method, k, window=7, times=nothing) -> BitVector

Which values of a numeric column are outliers:
- `zscore`: more than `k` standard deviations from the mean
- `iqr`: more than `k` interquartile ranges below the first or above the third quartile
- `mad`: modified z-score `0.6745 |x - median| / MAD` above `k` (robust to the outliers themselves)
- `hampel`: more than `k` scaled MADs from the median of the `window` values
  around it (in time order when `times` is given); follows a drifting signal
"""
function outlier_mask(col::AbstractVector, method::String, k::Real, window::Int=7, times=nothing)
    mask = falses(length(col))
    present = findall(!ismissing, col)
    length(present) < 3 && return mask
    if method == "hampel"
        if times !== nothing  # neighbours in time, not in row order
            present = filter(i -> !ismissing(times[i]), present)
            sort!(present; by=i -> times[i])
        end
        values = Float64[col[i] for i in present]
        flags = hampel_flags(values, window, k)
        mask[present[flags]] .= true
        return mask
    end
    values = Float64[col[i] for i in present]
    flags = if method == "zscore"
        μ, σ = mean(values), std(values)
        σ > 0 ? abs.(values .- μ) ./ σ .> k : falses(length(values))
    elseif method == "iqr"
        q1, q3 = quantile(values, 0.25), quantile(values, 0.75)
        r = q3 - q1
        (values .< q1 - k * r) .| (values .> q3 + k * r)
    else  # mad
        m = median(values)
        mad = median(abs.(values .- m))
        mad > 0 ? 0.6745 .* abs.(values .- m) ./ mad .> k : falses(length(values))
    end
    mask[present[flags]] .= true
    return mask
end

"Hampel filter flags: `x[i]` deviates from its window's median by more than `k` scaled MADs."
function hampel_flags(x::Vector{Float64}, window::Int, k::Real)
    h = window ÷ 2
    n = length(x)
    flags = falses(n)
    buf = Float64[]
    for i in 1:n
        empty!(buf)
        append!(buf, @view x[max(1, i - h):min(n, i + h)])
        m = median!(buf)
        buf .= abs.(buf .- m)
        s = 1.4826 * median!(buf)
        flags[i] = s > 0 && abs(x[i] - m) > k * s
    end
    return flags
end

# ---------------------------------------------------------------------------
# Time-aware interpolation

"""
    interpolate_by_time(col, times) -> Vector{Union{Missing, Float64}}

Like `interpolate_linear`, but gaps are filled in time order and weighted by
the time between samples, so unevenly spaced readings interpolate correctly.
Rows without a time keep their value (or stay missing).
"""
function interpolate_by_time(col::AbstractVector, times::AbstractVector)
    out = Vector{Union{Missing, Float64}}(undef, length(col))
    for i in eachindex(col)
        out[i] = ismissing(col[i]) ? missing : Float64(col[i])
    end
    order = sort!(filter(i -> !ismissing(times[i]), collect(eachindex(col))); by=i -> times[i])
    prev = 0  # position in `order` of the last present value
    for (p, i) in enumerate(order)
        ismissing(col[i]) && continue
        if prev > 0 && p - prev > 1
            j = order[prev]
            t0, t1, a, b = times[j], times[i], out[j], out[i]
            for q in prev+1:p-1
                k = order[q]
                out[k] = t1 == t0 ? a : a + (b - a) * (times[k] - t0) / (t1 - t0)
            end
        end
        prev = p
    end
    return out
end

# ---------------------------------------------------------------------------
# Resampling

"""
    resample!(df, opts) -> df

Replace the rows of `df` with rows on a fixed time grid every `opts.resample`.
Grid times are multiples of the period, so data from several sensors
resampled with the same period lines up row for row. Per method:
- `linear`: values at each grid time, interpolated between the neighbouring
  readings (numeric columns) or the latest reading at or before it (others);
  grid times are those within the span of the data.
- `mean` / `last`: one row per period interval starting at the grid time,
  with the mean (numeric columns; `last` for others) or the last reading in
  it. Intervals without readings give missing values, so the grid stays regular.
"""
function resample!(df::DataFrame, opts::CleanOptions)
    opts.resample === nothing && return df
    Δ = period_ns(opts.resample)
    tname = opts.time_column
    times = time_ns_column(df, opts)
    rows = sort!(findall(!ismissing, times); by=i -> times[i])
    out = DataFrame()
    if isempty(rows)
        out[!, tname] = Timestamp[]
        for name in names(df)
            name == tname || (out[!, name] = similar(df[!, name], 0))
        end
    else
        t = Int64[times[i] for i in rows]
        linear = opts.resample_method == "linear"
        start = linear ? cld(t[1], Δ) * Δ : fld(t[1], Δ) * Δ
        n = t[end] < start ? 0 : fld(t[end] - start, Δ) + 1
        n <= MAX_RESAMPLED_ROWS || throw(ArgumentError(
            "resample: a period of $(opts.resample) would make $n rows; choose a longer period"))
        grid = [start + (k - 1) * Δ for k in 1:n]
        out[!, tname] = Timestamp.(grid)
        for name in names(df)
            name == tname && continue
            col = df[!, name][rows]
            out[!, name] = linear ? resample_linear(col, t, grid) :
                           resample_bins(col, t, start, Δ, n, opts.resample_method == "mean")
        end
    end
    @info "Resampled $(nrow(df)) row$(nrow(df) == 1 ? "" : "s") to $(nrow(out)) at $(opts.resample) ($(opts.resample_method))"
    select!(df, String[])  # in place: callers may hold on to `df`
    for name in names(out)
        df[!, name] = out[!, name]
    end
    return df
end

# Values of `col` (rows sorted by time `t`) at each grid time
function resample_linear(col::AbstractVector, t::Vector{Int64}, grid::Vector{Int64})
    present = findall(!ismissing, col)
    numeric = is_numeric_column(col)
    T = numeric ? Float64 : nonmissingtype(eltype(col))
    out = Vector{Union{Missing, T}}(missing, length(grid))
    isempty(present) && return out
    j = 1  # index into `present`: the last reading at or before the grid time
    for (k, g) in enumerate(grid)
        while j < length(present) && t[present[j+1]] <= g
            j += 1
        end
        i = present[j]
        t[i] > g && continue  # before the first reading
        if !numeric
            out[k] = col[i]
        elseif t[i] == g || j == length(present)
            t[i] == g && (out[k] = Float64(col[i]))  # past the last reading: no extrapolation
        else
            i2 = present[j+1]
            a, b = Float64(col[i]), Float64(col[i2])
            out[k] = a + (b - a) * (g - t[i]) / (t[i2] - t[i])
        end
    end
    return out
end

# Mean (numeric, when `mean`) or last value of `col` per interval [start + (k-1)Δ, start + kΔ)
function resample_bins(col::AbstractVector, t::Vector{Int64}, start::Int64, Δ::Int64, n::Int, mean::Bool)
    numeric = mean && is_numeric_column(col)
    T = numeric ? Float64 : nonmissingtype(eltype(col))
    T === Union{} && return fill(missing, n)
    out = Vector{Union{Missing, T}}(missing, n)
    sums, counts = zeros(n), zeros(Int, n)
    for i in eachindex(col)
        x = col[i]
        ismissing(x) && continue
        k = fld(t[i] - start, Δ) + 1
        if numeric
            sums[k] += x
            counts[k] += 1
        else
            out[k] = x  # rows are in time order: the last one wins
        end
    end
    if numeric
        for k in 1:n
            counts[k] > 0 && (out[k] = sums[k] / counts[k])
        end
    end
    return out
end
