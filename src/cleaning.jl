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

function clean_string(x)
    ismissing(x) && return missing
    s = strip(valid_utf8(x))
    return s in MISSING_STRINGS ? missing : String(s)
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
function clean_dataset(df::AbstractDataFrame)
    out = DataFrame(df; copycols=true)
    rename!(out, normalize_name.(names(out)); makeunique=true)

    for name in names(out)
        col = out[!, name]
        if nonmissingtype(eltype(col)) <: AbstractString
            out[!, name] = Union{Missing, String}[clean_string(x) for x in col]
        end
    end

    if ncol(out) > 0
        empty_row = trues(nrow(out))
        for col in eachcol(out)
            empty_row .&= ismissing.(col)
        end
        deleteat!(out, empty_row)
    end

    deleteat!(out, duplicate_rows(out))
    disallowmissing!(out; error=false)
    return out
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
