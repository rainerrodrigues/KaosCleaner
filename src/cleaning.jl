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
    normalize_name(name) -> String

Lowercase snake_case column name: `" Bill Length (mm)"` -> `"bill_length_mm"`.
"""
function normalize_name(name::AbstractString)
    s = lowercase(strip(name))
    s = replace(s, r"[^\p{L}\p{N}]+" => "_")
    s = strip(s, '_')
    return isempty(s) ? "column" : String(s)
end

function clean_string(x)
    ismissing(x) && return missing
    s = strip(x)
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

    unique!(out)
    disallowmissing!(out; error=false)
    return out
end
