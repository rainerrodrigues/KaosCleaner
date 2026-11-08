# Cleaning options. Python passes them as a JSON object (clean_csv's keyword
# arguments); every key is validated here so typos fail loudly.

const IMPUTE_STRATEGIES = ("mean", "median", "mode", "zero", "ffill", "bfill")

Base.@kwdef struct CleanOptions
    "Columns to remove (original or snake_case names)."
    drop::Vector{String} = String[]
    "If set, only these columns are kept."
    keep::Union{Nothing, Vector{String}} = nothing
    "Extra cell values to treat as missing, on top of MISSING_STRINGS."
    missing_values::Vector{String} = String[]
    "Rename columns to unique snake_case."
    rename::Bool = true
    "Drop rows that repeat an earlier row."
    dedupe::Bool = true
    "Drop rows where every value is missing."
    drop_empty_rows::Bool = true
    "Convert text columns that hold booleans, dates or formatted numbers."
    infer_types::Bool = true
    "Date formats (Dates.DateFormat syntax), e.g. \"dd/mm/yyyy\"; when given, only these are tried."
    datetime_formats::Vector{String} = String[]
    "Fill missing values: one strategy for every column, or column => strategy."
    impute::Union{Nothing, String, Dict{String, String}} = nothing
    "Field separator, one character (e.g. \"\\t\"); detected automatically when not given."
    delimiter::Union{Nothing, String} = nothing
    "Decimal mark in numbers: \".\" or e.g. \",\"."
    decimal::String = "."
    "Thousands separator inside numbers, e.g. \".\" together with decimal \",\"."
    thousands::Union{Nothing, String} = nothing
    "Lines starting with this text are skipped."
    comment::Union{Nothing, String} = nothing
    "Line number of the header row (lines above it are skipped); 0 when the file has none."
    header::Int = 1
    "Add a first column `source_row`: each row's position among the input's data rows (1 = first)."
    source_row::Bool = false
    "Read a file as it is: every column as untrimmed text, no missing markers, no cleaning steps."
    raw::Bool = false
end

"""
    parse_options(json) -> CleanOptions

Options from a JSON object such as `{"drop": ["id"], "impute": "median"}`.
"""
function parse_options(json::AbstractString)
    isempty(strip(json)) && return CleanOptions()
    obj = JSON3.read(json)
    obj isa JSON3.Object || throw(ArgumentError("options must be a JSON object"))
    valid = fieldnames(CleanOptions)
    kw = Dict{Symbol, Any}()
    for (key, value) in obj
        key in valid || throw(ArgumentError("unknown option `$key`; valid options are: $(join(valid, ", "))"))
        value === nothing && continue
        kw[key] = option_value(key, value)
    end
    return check_parsing(CleanOptions(; kw...))
end

"Reject parsing options CSV.jl would misread (one mark used for two roles)."
function check_parsing(o::CleanOptions)
    marks = filter(!isnothing, [o.delimiter, o.decimal, o.thousands])
    allunique(marks) || throw(ArgumentError("delimiter, decimal and thousands must be different characters"))
    return o
end

function option_value(key::Symbol, value)
    if key in (:rename, :dedupe, :drop_empty_rows, :infer_types, :source_row, :raw)
        value isa Bool || throw(ArgumentError("option `$key` must be true or false, got $(repr(value))"))
        return value
    elseif key in (:delimiter, :decimal, :thousands)
        value isa AbstractString && length(value) == 1 ||
            throw(ArgumentError("option `$key` must be a single character, got $(repr(value))"))
        return String(value)
    elseif key == :comment
        value isa AbstractString && !isempty(value) ||
            throw(ArgumentError("option `comment` must be a non-empty string"))
        return String(value)
    elseif key == :header
        value isa Integer && !(value isa Bool) && value >= 0 ||
            throw(ArgumentError("option `header` must be a line number (0 for no header), got $(repr(value))"))
        return Int(value)
    elseif key in (:drop, :keep, :missing_values, :datetime_formats)
        strings = value isa AbstractString ? [value] : value
        (strings isa AbstractVector && all(s -> s isa AbstractString, strings)) ||
            throw(ArgumentError("option `$key` must be a string or a list of strings"))
        return String.(strings)
    else # :impute
        if value isa AbstractString
            return check_strategy(value)
        elseif value isa JSON3.Object
            return Dict(String(k) => check_strategy(v) for (k, v) in value)
        end
        throw(ArgumentError("option `impute` must be a strategy or a {column: strategy} mapping"))
    end
end

function check_strategy(s)
    s isa AbstractString && s in IMPUTE_STRATEGIES ||
        throw(ArgumentError("unknown impute strategy $(repr(s)); use one of: $(join(IMPUTE_STRATEGIES, ", "))"))
    return String(s)
end
