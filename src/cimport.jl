# Arrow C Data Interface import: the counterpart of cdata.jl, for tables the
# host passes in (pyarrow, Polars, pandas via the Python package). Values are
# copied into Julia vectors and the incoming structs are released right away.
#
# Supported column formats: null, boolean, signed/unsigned integers, float32/64,
# utf8 and large utf8, date32/date64 and timestamps without a time zone. The
# Python package converts other types (dictionary-encoded, time zones,
# decimals, ...) into these before handing a table over.

"""
    import_dataframe(schema, array) -> DataFrame

Copy an exported struct array (a record batch) into a DataFrame, then release
the structs as the C Data Interface requires of a consumer.
"""
function import_dataframe(schema::Ptr{ArrowSchema}, array::Ptr{ArrowArray})
    try
        s, a = unsafe_load(schema), unsafe_load(array)
        format = unsafe_string(s.format)
        format == "+s" || throw(ArgumentError("expected a record batch (struct array), got Arrow format $(repr(format))"))
        cols = map(1:s.n_children) do i
            cs = unsafe_load(unsafe_load(s.children, i))
            ca = unsafe_load(unsafe_load(a.children, i))
            # A child's values start at its own offset plus the parent's
            String(valid_utf8(unsafe_string(cs.name))) => import_column(cs, ca, ca.offset + a.offset, Int(a.length))
        end
        return DataFrame(cols; makeunique=true, copycols=false)
    finally
        release_imported(schema, array)
    end
end

function release_imported(schema::Ptr{ArrowSchema}, array::Ptr{ArrowArray})
    if schema != C_NULL && unsafe_load(schema).release != C_NULL
        ccall(unsafe_load(schema).release, Cvoid, (Ptr{ArrowSchema},), schema)
    end
    if array != C_NULL && unsafe_load(array).release != C_NULL
        ccall(unsafe_load(array).release, Cvoid, (Ptr{ArrowArray},), array)
    end
end

const PRIMITIVE_TYPES = Dict("c" => Int8, "C" => UInt8, "s" => Int16, "S" => UInt16, "i" => Int32, "I" => UInt32,
                             "l" => Int64, "L" => UInt64, "f" => Float32, "g" => Float64)
const TIMESTAMP_UNITS = Dict('s' => 1000, 'm' => 1, 'u' => 1 // 1000, 'n' => 1 // 1_000_000)  # -> milliseconds

bit(p::Ptr{UInt8}, i::Integer) = (unsafe_load(p, i >> 3 + 1) >> (i & 7)) & 0x01 == 0x01  # i is 0-based

"Column `i`'s values (0-based offset `off`, length `n`) as a Julia vector."
function import_column(s::ArrowSchema, a::ArrowArray, off::Int, n::Int)
    format = unsafe_string(s.format)
    s.dictionary == C_NULL ||
        throw(ArgumentError("dictionary-encoded columns are not supported; decode them first"))
    format == "n" && return Vector{Missing}(fill(missing, n))
    buffer(k) = unsafe_load(a.buffers, k)
    validity = a.n_buffers > 0 && a.null_count != 0 ? Ptr{UInt8}(buffer(1)) : Ptr{UInt8}(C_NULL)
    valid(i) = validity == C_NULL || bit(validity, off + i - 1)

    nulls = validity != C_NULL
    if haskey(PRIMITIVE_TYPES, format)
        T = PRIMITIVE_TYPES[format]
        data = Ptr{T}(buffer(2))
        return collect_column(i -> unsafe_load(data, off + i), valid, n, T, nulls)
    elseif format == "b"
        bits = Ptr{UInt8}(buffer(2))
        return collect_column(i -> bit(bits, off + i - 1), valid, n, Bool, nulls)
    elseif format in ("u", "U")
        O = format == "u" ? Int32 : Int64
        offsets, chars = Ptr{O}(buffer(2)), Ptr{UInt8}(buffer(3))
        get_string = i -> begin
            lo, hi = unsafe_load(offsets, off + i), unsafe_load(offsets, off + i + 1)
            String(valid_utf8(unsafe_string(chars + lo, hi - lo)))
        end
        return collect_column(get_string, valid, n, String, nulls)
    elseif format == "tdD"
        days = Ptr{Int32}(buffer(2))
        return collect_column(i -> Date(1970) + Day(unsafe_load(days, off + i)), valid, n, Date, nulls)
    elseif format == "tdm"
        ms = Ptr{Int64}(buffer(2))
        return collect_column(i -> Date(1970) + Day(fld(unsafe_load(ms, off + i), 86_400_000)), valid, n, Date, nulls)
    elseif startswith(format, "ts") && length(format) >= 4 && format[4] == ':'
        length(format) == 4 ||
            throw(ArgumentError("timestamps with a time zone are not supported; convert them to UTC first"))
        scale = TIMESTAMP_UNITS[format[3]]
        ticks = Ptr{Int64}(buffer(2))
        get_time = i -> DateTime(1970) + Millisecond(round(Int64, unsafe_load(ticks, off + i) * scale, RoundDown))
        return collect_column(get_time, valid, n, DateTime, nulls)
    end
    throw(ArgumentError("column `$(unsafe_string(s.name))` has unsupported Arrow format $(repr(format))"))
end

# Function barrier: `get` is a different closure type per format, so this loop
# is compiled for each. The element type is explicit: an inferred one would
# depend on the compiler for empty columns. Vector{T} without nulls, otherwise
# Vector{Union{Missing, T}}, as CSV.jl returns.
function collect_column(get::F, valid::V, n::Int, ::Type{T}, nulls::Bool) where {F, V, T}
    nulls || return T[get(i) for i in 1:n]
    out = Vector{Union{Missing, T}}(undef, n)
    @inbounds for i in 1:n
        out[i] = valid(i) ? get(i) : missing
    end
    return out
end
