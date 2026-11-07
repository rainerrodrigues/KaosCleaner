# Loading and cleaning of messy tabular data.

"Cell values treated as missing, both when parsing and in string columns."
const MISSING_STRINGS = ["", "NA", "N/A", "n/a", "na", "NaN", "nan", "null", "NULL", "None", "none"]

"""
    load_dataset(path) -> DataFrame

Read a delimited file, mapping common missing-value markers to `missing`.
"""
function load_dataset(path::AbstractString)
    isfile(path) || throw(ArgumentError("file not found: $path"))
    return CSV.read(path, DataFrame; missingstring=MISSING_STRINGS, stripwhitespace=true)
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

const MAX_MISSING_LENGTH = maximum(ncodeunits, MISSING_STRINGS)

is_missing_marker(s) = ncodeunits(s) <= MAX_MISSING_LENGTH && s in MISSING_STRINGS

function clean_string(x)
    ismissing(x) && return missing
    s = strip(valid_utf8(x))
    return is_missing_marker(s) ? missing : String(s)
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

function needs_cleaning(x)
    ismissing(x) && return false
    n, ascii, first_byte, last_byte = byte_summary(x)
    n == 0 && return true
    ascii && return is_ascii_space(first_byte) || is_ascii_space(last_byte) || is_missing_marker(x)
    return !isvalid(x) || isspace(first(x)) || isspace(last(x)) || is_missing_marker(x)
end

"""
    clean_dataset(df) -> DataFrame

Return a cleaned copy of `df`:
1. column names normalised to unique snake_case,
2. string cells stripped, with missing markers turned into `missing`,
3. rows where every value is missing dropped,
4. duplicate rows dropped,
5. columns that no longer contain missings narrowed to non-missing types.
"""
clean_dataset(df::AbstractDataFrame) = clean_dataset!(DataFrame(df; copycols=true))

"""
    clean_dataset!(df) -> df

[`clean_dataset`](@ref) in place, for a DataFrame whose columns the caller
owns, such as one fresh from [`load_dataset`](@ref). Saves copying every column.
"""
function clean_dataset!(df::DataFrame)
    rename!(df, normalize_name.(names(df)); makeunique=true)

    for name in names(df)
        col = df[!, name]
        T = nonmissingtype(eltype(col))
        # T === Union{}: an all-missing column, kept as a nullable string column
        if T <: AbstractString && (T === Union{} || any(needs_cleaning, col))
            df[!, name] = Union{Missing, String}[clean_string(x) for x in col]
        end
    end

    # A row can only be entirely missing if every column allows missing values
    if ncol(df) > 0 && all(col -> Missing <: eltype(col), eachcol(df))
        empty_row = trues(nrow(df))
        for col in eachcol(df)
            empty_row .&= ismissing.(col)
        end
        any(empty_row) && deleteat!(df, empty_row)
    end

    dup = duplicate_rows(df)
    any(dup) && deleteat!(df, dup)
    disallowmissing!(df; error=false)
    return df
end

"""
    duplicate_rows(df) -> BitVector

Mark rows equal (by `isequal`, as `unique!`) to an earlier row. Rows are
hashed one column at a time and only hash matches are compared in full.
DataFrames' `unique!` specializes on all column types at once, which takes
minutes to compile for files with hundreds of columns.
"""
function duplicate_rows(df::AbstractDataFrame)
    cols = collect(AbstractVector, eachcol(df))
    hashes = zeros(UInt, nrow(df))
    for col in cols
        hash_column!(hashes, col)
    end
    same(i, j) = all(col -> isequal(col[i], col[j]), cols)
    first = sizehint!(Dict{UInt, Int}(), length(hashes))  # hash -> first row with it
    others = Dict{UInt, Vector{Int}}()  # further distinct rows sharing a hash (rare)
    dup = falses(length(hashes))
    for (i, h) in enumerate(hashes)
        j = get(first, h, 0)
        if j == 0
            first[h] = i
        elseif same(i, j) || any(k -> same(i, k), get(others, h, ()))
            dup[i] = true
        else
            push!(get!(Vector{Int}, others, h), i)
        end
    end
    return dup
end

# Function barrier: compiled once per column type, not per combination of them
function hash_column!(hashes::Vector{UInt}, col::AbstractVector)
    for i in eachindex(hashes, col)
        hashes[i] = hash(col[i], hashes[i])
    end
end
