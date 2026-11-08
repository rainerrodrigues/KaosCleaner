# Loading and cleaning of messy tabular data.

"Cell values treated as missing, both when parsing and in string columns."
const MISSING_STRINGS = ["", "NA", "N/A", "n/a", "na", "NaN", "nan", "null", "NULL", "None", "none"]

"""
    load_dataset(path, opts=CleanOptions()) -> DataFrame
    load_dataset(path; missing_values=String[]) -> DataFrame

Read a delimited file (gzip-compressed is fine), mapping common missing-value
markers plus `opts.missing_values` to `missing` and applying the parsing
options of `opts` (delimiter, decimal, thousands, comment, header).
"""
function load_dataset(path::AbstractString, opts::CleanOptions)
    isfile(path) || throw(ArgumentError("file not found: $path"))
    return CSV.read(path, DataFrame; csv_options(opts)...)
end

load_dataset(path::AbstractString; missing_values::Vector{String}=String[]) =
    load_dataset(path, CleanOptions(; missing_values))

"CSV.jl keyword arguments for the parsing options in `opts`."
function csv_options(opts::CleanOptions)
    header = opts.header == 0 ? false : opts.header
    kw = opts.raw ? (types=String, missingstring=nothing, stripwhitespace=false, header) :
         (missingstring=vcat(MISSING_STRINGS, opts.missing_values), stripwhitespace=true,
          decimal=only(opts.decimal), header)
    opts.delimiter === nothing || (kw = (; kw..., delim=only(opts.delimiter)))
    opts.thousands === nothing || opts.raw || (kw = (; kw..., groupmark=only(opts.thousands)))
    opts.comment === nothing || (kw = (; kw..., comment=opts.comment))
    return kw
end

"""
    valid_utf8(s) -> AbstractString

`s` with invalid UTF-8 sequences replaced by U+FFFD. Arrow string columns must
be valid UTF-8, and CSV files with stray Latin-1 or binary bytes are common.
"""
valid_utf8(s::AbstractString) = isvalid(s) ? s : map(c -> isvalid(c) ? c : '�', s)

"""
    normalize_name(name) -> String

Lowercase snake_case column name: `" Bill Length (mm)"` -> `"bill_length_mm"`.
"""
function normalize_name(name::AbstractString)
    s = lowercase(strip(valid_utf8(name)))
    s = replace(s, r"[^\p{L}\p{N}]+" => "_")
    s = strip(s, '_')
    return isempty(s) ? "column" : String(s)
end

"The cell values treated as missing, with their longest length for a cheap pre-check."
struct Markers
    values::Vector{String}
    max_length::Int
end
Markers(extra::Vector{String}=String[]) =
    (v = unique(vcat(MISSING_STRINGS, extra)); Markers(v, maximum(ncodeunits, v)))

is_missing_marker(s, m::Markers) = ncodeunits(s) <= m.max_length && s in m.values

function clean_string(x, m::Markers=Markers())
    ismissing(x) && return missing
    s = strip(valid_utf8(x))
    return is_missing_marker(s, m) ? missing : String(s)
end

# Whether clean_string would change `x`. For CSV input the parser has already
# stripped whitespace and mapped missing markers, so this is usually false and
# the column (often compact InlineStrings) can be kept as it is.
# isspace for bytes below 0x80 (space, \t \n \v \f \r), minus the Char conversion
is_ascii_space(b::UInt8) = b == 0x20 || 0x09 <= b <= 0x0d

"""
    byte_summary(s) -> (ncodeunits, all_ascii, first_byte, last_byte)

What `needs_cleaning` needs to know, without generic `isvalid`/`first`/`last`,
which are slow on InlineStrings.
"""
function byte_summary(s::AbstractString)
    n, ascii, first_byte, last_byte = 0, true, 0x00, 0x00
    for b in codeunits(s)
        n += 1
        n == 1 && (first_byte = b)
        last_byte = b
        ascii &= b < 0x80
    end
    return n, ascii, first_byte, last_byte
end

# CSV.jl parses short text into InlineStrings, which keep their bytes in an
# integer: first byte most significant, length in the lowest byte, unused
# bytes zero. Bit operations then replace ~8 ns of extraction per byte.
const IS = CSV.InlineStrings
const INLINE_INTS = ((IS.String3, UInt32), (IS.String7, UInt64), (IS.String15, UInt128))
for (S, U) in INLINE_INTS
    @eval function byte_summary(s::$S)
        v = reinterpret($U, s)
        n = Int(v % UInt8)
        high_bits = (typemax($U) ÷ 0xff * 0x80) & ~$U(0xff)  # 0x80 in every byte but the length
        first_byte = (v >> (8 * ($(sizeof(U)) - 1))) % UInt8
        last_byte = n == 0 ? 0x00 : (v >> (8 * ($(sizeof(U)) - n))) % UInt8
        return n, (v & high_bits) == 0, first_byte, last_byte
    end
end

function needs_cleaning(x, m::Markers=Markers())
    ismissing(x) && return false
    n, ascii, first_byte, last_byte = byte_summary(x)
    n == 0 && return true
    ascii && return is_ascii_space(first_byte) || is_ascii_space(last_byte) || is_missing_marker(x, m)
    return !isvalid(x) || isspace(first(x)) || isspace(last(x)) || is_missing_marker(x, m)
end

"""
    clean_dataset(df, opts=CleanOptions()) -> DataFrame

Return a cleaned copy of `df`. With the default options:
1. column names normalised to unique snake_case,
2. string cells stripped, with missing markers turned into `missing`,
3. text columns holding booleans, dates or formatted numbers converted,
4. rows where every value is missing dropped,
5. duplicate rows dropped,
6. columns that no longer contain missings narrowed to non-missing types.
Columns can be dropped or kept and missing values imputed; see `CleanOptions`.
"""
clean_dataset(df::AbstractDataFrame, opts::CleanOptions=CleanOptions()) =
    clean_dataset!(DataFrame(df; copycols=true), opts)

"""
    clean_dataset!(df, opts=CleanOptions()) -> df

[`clean_dataset`](@ref) in place, for a DataFrame whose columns the caller
owns, such as one fresh from [`load_dataset`](@ref). Saves copying every column.
"""
function clean_dataset!(df::DataFrame, opts::CleanOptions=CleanOptions())
    rows = opts.source_row ? collect(1:nrow(df)) : nothing  # input positions of the remaining rows
    if opts.raw
        select_columns!(df, CleanOptions(; opts.keep, opts.drop, rename=false))
        raw_strings!(df)
        return add_source_row!(df, rows)
    end
    opts.rename && rename!(df, normalize_name.(names(df)); makeunique=true)
    select_columns!(df, opts)

    clean_strings!(df, Markers(opts.missing_values))
    opts.infer_types && infer_types!(df, opts)

    if opts.drop_empty_rows
        n = drop_empty_rows!(df, rows)
        n > 0 && @info "Dropped $n empty row$(n == 1 ? "" : "s")"
    end

    if opts.dedupe
        dup = duplicate_rows(df)
        n = count(dup)
        if n > 0
            deleteat!(df, dup)
            rows === nothing || deleteat!(rows, dup)
            @info "Dropped $n duplicate row$(n == 1 ? "" : "s")"
        end
    end

    impute!(df, opts)
    disallowmissing!(df; error=false)
    return add_source_row!(df, rows)
end

"""
    add_source_row!(df, rows) -> df

Insert `rows` (input positions, 1-based) as the first column, `source_row`.
`nothing` leaves `df` alone.
"""
add_source_row!(df::DataFrame, ::Nothing) = df
function add_source_row!(df::DataFrame, rows::Vector{Int})
    "source_row" in names(df) &&
        throw(ArgumentError("the data already has a column named `source_row`; rename or drop it to use source_row"))
    return insertcols!(df, 1, "source_row" => rows)
end

"Text cells as valid UTF-8, otherwise untouched (the raw option)."
function raw_strings!(df::DataFrame)
    for name in names(df)
        col = df[!, name]
        if nonmissingtype(eltype(col)) <: AbstractString && any(x -> !ismissing(x) && !isvalid(x), col)
            df[!, name] = [ismissing(x) ? missing : String(valid_utf8(x)) for x in col]
        end
    end
    return df
end

"""
    drop_empty_rows!(df, rows=nothing) -> Int

Delete rows where every value is missing, and the same positions of `rows`
when given; returns how many were dropped.
"""
function drop_empty_rows!(df::DataFrame, rows::Union{Nothing, Vector{Int}}=nothing)
    # A row can only be entirely missing if every column allows missing values
    (ncol(df) > 0 && all(col -> Missing <: eltype(col), eachcol(df))) || return 0
    empty_row = trues(nrow(df))
    for col in eachcol(df)
        empty_row .&= ismissing.(col)
    end
    n = count(empty_row)
    n > 0 && deleteat!(df, empty_row)
    n > 0 && rows !== nothing && deleteat!(rows, empty_row)
    return n
end

"Strip text cells and turn missing markers into `missing`, column by column."
function clean_strings!(df::DataFrame, markers::Markers)
    for name in names(df)
        col = df[!, name]
        T = nonmissingtype(eltype(col))
        # T === Union{}: an all-missing column, kept as a nullable string column
        if T <: AbstractString && (T === Union{} || any(x -> needs_cleaning(x, markers), col))
            df[!, name] = Union{Missing, String}[clean_string(x, markers) for x in col]
        end
    end
    return df
end

"""
    select_columns!(df, opts)

Apply `opts.drop` and `opts.keep`. Names may be given as in the file or in
their snake_case form; unknown names are an error rather than a silent no-op.
"""
function select_columns!(df::DataFrame, opts::CleanOptions)
    resolve(user) = begin
        user in names(df) && return user
        n = normalize_name(user)
        opts.rename && n in names(df) && return n
        throw(ArgumentError("no column named $(repr(user)); columns are: $(join(names(df), ", "))"))
    end
    opts.keep === nothing || select!(df, unique(resolve.(opts.keep)))
    isempty(opts.drop) || select!(df, Not(unique(resolve.(opts.drop))))
    return df
end

"""
    duplicate_rows(df; tasks=Threads.nthreads(), min_rows=PARALLEL_MIN_ROWS) -> BitVector

Mark rows equal (by `isequal`, as `unique!`) to an earlier row. Rows are
hashed one column at a time and only hash matches are compared in full.
DataFrames' `unique!` specializes on all column types at once, which takes
minutes to compile for files with hundreds of columns.

Tables of at least `min_rows` rows are processed by `tasks` tasks: rows are
hashed in ranges, then
split into groups by hash. Equal rows always share a hash and so a group, and
each group is scanned in row order, so the first occurrence is kept exactly
as in a sequential scan.
"""
function duplicate_rows(df::AbstractDataFrame; tasks::Integer=Threads.nthreads(),
                        min_rows::Integer=PARALLEL_MIN_ROWS)
    cols = collect(AbstractVector, eachcol(df))
    n = nrow(df)
    tasks = n < min_rows ? 1 : max(1, tasks)
    hashes = zeros(UInt, n)
    @sync for rows in Iterators.partition(1:n, max(1, cld(n, tasks)))
        Threads.@spawn for col in cols
            hash_column!(hashes, col, rows)
        end
    end
    dup = zeros(Bool, n)  # not a BitVector: tasks write neighbouring elements
    @sync for group in 0:tasks-1
        Threads.@spawn mark_duplicates!(dup, hashes, cols, UInt(group), UInt(tasks))
    end
    return BitVector(dup)
end

# Mark duplicates among the rows whose hash falls in `group` (of `ngroups`).
# Rows repeating an earlier row's hash are confirmed column by column in one
# batch (a type-stable loop per column) rather than value by value through
# dynamic dispatch, which cost ~1 µs per duplicate. If any pair turns out to
# be a hash collision, the group is redone exactly, row by row.
function mark_duplicates!(dup::Vector{Bool}, hashes::Vector{UInt}, cols, group::UInt, ngroups::UInt)
    first = Dict{UInt, Int}()  # hash -> first row with it
    sizehint!(first, cld(length(hashes), Int(ngroups)))
    rows, earlier = Int[], Int[]  # candidate duplicate and the row it would repeat
    for (i, h) in enumerate(hashes)
        h % ngroups == group || continue
        j = get!(first, h, i)
        j == i || (push!(rows, i); push!(earlier, j))
    end
    equal = trues(length(rows))
    for col in cols
        confirm_equal!(equal, col, rows, earlier)
    end
    if all(equal)
        dup[rows] .= true
    else
        mark_duplicates_exactly!(dup, hashes, cols, group, ngroups)
    end
end

function confirm_equal!(equal::BitVector, col::AbstractVector, rows::Vector{Int}, earlier::Vector{Int})
    @inbounds for k in eachindex(rows)
        equal[k] && (equal[k] = isequal(col[rows[k]], col[earlier[k]]))
    end
end

# Row-by-row version, which handles distinct rows sharing a hash
function mark_duplicates_exactly!(dup::Vector{Bool}, hashes::Vector{UInt}, cols, group::UInt, ngroups::UInt)
    same(i, j) = all(col -> isequal(col[i], col[j]), cols)
    first = Dict{UInt, Int}()
    others = Dict{UInt, Vector{Int}}()  # further distinct rows sharing a hash
    for (i, h) in enumerate(hashes)
        h % ngroups == group || continue
        j = get(first, h, 0)
        if j == 0
            first[h] = i
        elseif same(i, j) || any(k -> same(i, k), get(others, h, ()))
            dup[i] = true
        else
            push!(get!(Vector{Int}, others, h), i)
        end
    end
end

# Function barrier: compiled once per column type, not per combination of them
function hash_column!(hashes::Vector{UInt}, col::AbstractVector, rows=eachindex(hashes, col))
    for i in rows
        hashes[i] = hash(col[i], hashes[i])
    end
end
