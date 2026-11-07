# Arrow C Data Interface export.
# Spec: https://arrow.apache.org/docs/format/CDataInterface.html
#
# A DataFrame is exported as a struct array ("+s") with one child per column,
# which is what consumers such as pyarrow's `RecordBatch._import_from_c` expect.
# All memory handed to the consumer is malloc'd and owned by the exported
# structs; the consumer frees it by calling the `release` callback.

using Dates

struct ArrowSchema
    format::Ptr{UInt8}
    name::Ptr{UInt8}
    metadata::Ptr{UInt8}
    flags::Int64
    n_children::Int64
    children::Ptr{Ptr{ArrowSchema}}
    dictionary::Ptr{ArrowSchema}
    release::Ptr{Cvoid}
    private_data::Ptr{Cvoid}
end

struct ArrowArray
    length::Int64
    null_count::Int64
    offset::Int64
    n_buffers::Int64
    n_children::Int64
    buffers::Ptr{Ptr{Cvoid}}
    children::Ptr{Ptr{ArrowArray}}
    dictionary::Ptr{ArrowArray}
    release::Ptr{Cvoid}
    private_data::Ptr{Cvoid}
end

const ARROW_FLAG_NULLABLE = Int64(2)

# ---------------------------------------------------------------------------
# Memory ownership: every struct's private_data points to a malloc'd block
# [n, ptr_1, ..., ptr_n] listing the allocations that release must free.

function cmalloc!(allocs::Vector{Ptr{Cvoid}}, nbytes::Integer)
    p = Libc.calloc(max(nbytes, 1), 1)
    p == C_NULL && throw(OutOfMemoryError())
    push!(allocs, p)
    return p
end

function cstring!(allocs::Vector{Ptr{Cvoid}}, s::String)
    n = sizeof(s)
    p = Ptr{UInt8}(cmalloc!(allocs, n + 1))  # calloc'd, so already NUL-terminated
    GC.@preserve s unsafe_copyto!(p, pointer(s), n)
    return p
end

function private_block(allocs::Vector{Ptr{Cvoid}})
    n = length(allocs)
    blk = Ptr{UInt}(Libc.malloc((n + 1) * sizeof(UInt)))
    blk == C_NULL && throw(OutOfMemoryError())
    unsafe_store!(blk, UInt(n), 1)
    for i in 1:n
        unsafe_store!(blk, UInt(allocs[i]), i + 1)
    end
    return Ptr{Cvoid}(blk)
end

free_allocs(allocs::Vector{Ptr{Cvoid}}) = foreach(Libc.free, allocs)

function free_private(p::Ptr{Cvoid})
    p == C_NULL && return
    blk = Ptr{UInt}(p)
    for i in 1:unsafe_load(blk, 1)
        Libc.free(Ptr{Cvoid}(unsafe_load(blk, i + 1)))
    end
    Libc.free(p)
end

# ---------------------------------------------------------------------------
# Release callbacks. Children are released through their own callback (as the
# spec requires) before the parent frees the memory holding them.

function release_schema(p::Ptr{ArrowSchema})
    p == C_NULL && return
    s = unsafe_load(p)
    s.release == C_NULL && return
    for i in 1:s.n_children
        c = unsafe_load(s.children, i)
        if c != C_NULL && unsafe_load(c).release != C_NULL
            ccall(unsafe_load(c).release, Cvoid, (Ptr{ArrowSchema},), c)
        end
    end
    free_private(s.private_data)
    unsafe_store!(Ptr{Ptr{Cvoid}}(p + fieldoffset(ArrowSchema, 8)), C_NULL)
    return
end

function release_array(p::Ptr{ArrowArray})
    p == C_NULL && return
    a = unsafe_load(p)
    a.release == C_NULL && return
    for i in 1:a.n_children
        c = unsafe_load(a.children, i)
        if c != C_NULL && unsafe_load(c).release != C_NULL
            ccall(unsafe_load(c).release, Cvoid, (Ptr{ArrowArray},), c)
        end
    end
    free_private(a.private_data)
    unsafe_store!(Ptr{Ptr{Cvoid}}(p + fieldoffset(ArrowArray, 9)), C_NULL)
    return
end

schema_release_ptr() = @cfunction(release_schema, Cvoid, (Ptr{ArrowSchema},))
array_release_ptr() = @cfunction(release_array, Cvoid, (Ptr{ArrowArray},))

"""
    release!(schema_ptr, array_ptr)

Call the release callbacks of an exported schema/array pair (consumer side).
Only needed when the data is consumed from Julia, e.g. in tests.
"""
function release!(schema::Ptr, array::Ptr)
    s = Ptr{ArrowSchema}(schema)
    a = Ptr{ArrowArray}(array)
    if s != C_NULL && unsafe_load(s).release != C_NULL
        ccall(unsafe_load(s).release, Cvoid, (Ptr{ArrowSchema},), s)
    end
    if a != C_NULL && unsafe_load(a).release != C_NULL
        ccall(unsafe_load(a).release, Cvoid, (Ptr{ArrowArray},), a)
    end
    return
end

# ---------------------------------------------------------------------------
# Column encoders. Each returns (format, buffers, null_count).

function validity!(allocs, col::AbstractVector)
    nulls = count(ismissing, col)
    nulls == 0 && return Ptr{Cvoid}(C_NULL), 0
    bits = Ptr{UInt8}(cmalloc!(allocs, cld(length(col), 8)))
    for (i, x) in enumerate(col)
        ismissing(x) && continue
        j = (i - 1) >> 3 + 1
        unsafe_store!(bits, unsafe_load(bits, j) | (0x01 << ((i - 1) & 7)), j)
    end
    return Ptr{Cvoid}(bits), nulls
end

for (T, fmt) in ((Int8, "c"), (UInt8, "C"), (Int16, "s"), (UInt16, "S"),
                 (Int32, "i"), (UInt32, "I"), (Int64, "l"), (UInt64, "L"),
                 (Float32, "f"), (Float64, "g"))
    @eval encode!(allocs, ::Type{$T}, col) = encode_fixed!(allocs, $fmt, $T, identity, col)
end

encode!(allocs, ::Type{Date}, col) =
    encode_fixed!(allocs, "tdD", Int32, d -> Dates.value(d - Date(1970)), col)
encode!(allocs, ::Type{DateTime}, col) =
    encode_fixed!(allocs, "tsm:", Int64, d -> Dates.value(d - DateTime(1970)), col)

function encode_fixed!(allocs, fmt, ::Type{S}, conv, col) where {S}
    valid, nulls = validity!(allocs, col)
    data = Ptr{S}(cmalloc!(allocs, length(col) * sizeof(S)))
    for (i, x) in enumerate(col)
        ismissing(x) || unsafe_store!(data, S(conv(x)), i)
    end
    return fmt, Ptr{Cvoid}[valid, data], nulls
end

function encode!(allocs, ::Type{Bool}, col)
    valid, nulls = validity!(allocs, col)
    bits = Ptr{UInt8}(cmalloc!(allocs, cld(length(col), 8)))
    for (i, x) in enumerate(col)
        x === true || continue
        j = (i - 1) >> 3 + 1
        unsafe_store!(bits, unsafe_load(bits, j) | (0x01 << ((i - 1) & 7)), j)
    end
    return "b", Ptr{Cvoid}[valid, bits], nulls
end

# Column of only missings -> Arrow null type, which has no buffers.
encode!(allocs, ::Type{Union{}}, col) = "n", Ptr{Cvoid}[], length(col)

# Strings, and anything without a native mapping, are exported as utf8.
tostr(x) = ismissing(x) ? missing : String(valid_utf8(x isa AbstractString ? x : string(x)))

function encode!(allocs, ::Type, col)
    eltype(col) <: Union{Missing, AbstractString} || return encode!(allocs, String, map(tostr, col))
    total = 0
    for x in col
        ismissing(x) || (total += ncodeunits(x))
    end
    O = total <= typemax(Int32) ? Int32 : Int64
    fmt = O === Int32 ? "u" : "U"
    n_before = length(allocs)
    result = encode_strings!(allocs, fmt, O, col, total)
    utf8_ok(result[2][2], result[2][3], length(col), total, O) && return result
    # Arrow requires valid UTF-8: rare columns with bad bytes are repaired
    # into a String column (valid by construction) and encoded again.
    foreach(Libc.free, splice!(allocs, n_before+1:length(allocs)))
    return encode!(allocs, String, map(tostr, col))
end

function encode_strings!(allocs, fmt, ::Type{O}, col, total) where {O}
    valid, nulls = validity!(allocs, col)
    offsets = Ptr{O}(cmalloc!(allocs, (length(col) + 1) * sizeof(O)))
    data = Ptr{UInt8}(cmalloc!(allocs, total))
    pos = 0
    for (i, x) in enumerate(col)
        if !ismissing(x)
            for b in codeunits(x)  # iterating beats codeunit(s, i) ~15x for InlineStrings
                pos += 1
                unsafe_store!(data, b, pos)
            end
        end
        unsafe_store!(offsets, O(pos), i + 1)
    end
    return fmt, Ptr{Cvoid}[valid, offsets, data], nulls
end

# Every value in an encoded string column is valid UTF-8 iff the whole data
# buffer is, and no value starts with a continuation byte (which would let two
# broken values combine into one valid sequence). One fast pass over the
# buffer instead of validating each value separately.
function utf8_ok(offsets::Ptr, data::Ptr, n::Int, total::Int, ::Type{O}) where {O}
    total == 0 && return true
    bytes = unsafe_wrap(Array, Ptr{UInt8}(data), total)
    isvalid(String, bytes) || return false
    offs = Ptr{O}(offsets)
    for i in 1:n
        start = unsafe_load(offs, i)
        start < total && (bytes[start + 1] & 0xc0) == 0x80 && return false
    end
    return true
end

# ---------------------------------------------------------------------------

# Fill `sch`/`arr` for one column. On failure everything allocated is freed.
function export_column!(sch::Ptr{ArrowSchema}, arr::Ptr{ArrowArray}, name::String, col::AbstractVector;
                        nullable::Bool=false)
    sallocs = Ptr{Cvoid}[]
    aallocs = Ptr{Cvoid}[]
    try
        T = nonmissingtype(eltype(col))
        fmt, bufs, nulls = encode!(aallocs, T, col)
        flags = (!nullable && T === eltype(col) && T !== Union{}) ? Int64(0) : ARROW_FLAG_NULLABLE

        bufptr = Ptr{Ptr{Cvoid}}(cmalloc!(aallocs, length(bufs) * sizeof(Ptr{Cvoid})))
        for (i, b) in enumerate(bufs)
            unsafe_store!(bufptr, b, i)
        end
        unsafe_store!(arr, ArrowArray(length(col), nulls, 0, length(bufs), 0, bufptr,
                                      C_NULL, C_NULL, array_release_ptr(), private_block(aallocs)))

        f = cstring!(sallocs, fmt)
        n = cstring!(sallocs, String(valid_utf8(name)))
        unsafe_store!(sch, ArrowSchema(f, n, C_NULL, flags, 0, C_NULL, C_NULL,
                                       schema_release_ptr(), private_block(sallocs)))
    catch
        free_allocs(sallocs)
        free_allocs(aallocs)
        rethrow()
    end
    return
end

"""
    export_dataframe(df, out_schema, out_array; nullable=false)

Export `df` through the Arrow C Data Interface into caller-allocated
`ArrowSchema`/`ArrowArray` structs. Ownership passes to the caller, who must
eventually call each struct's `release` callback. `nullable=true` marks every
field nullable, so batches of a stream share one schema whether or not a
given batch happens to contain missing values.
"""
function export_dataframe(df::AbstractDataFrame, out_schema::Ptr{ArrowSchema}, out_array::Ptr{ArrowArray};
                          nullable::Bool=false, parallel::Bool=nrow(df) >= PARALLEL_MIN_ROWS)
    ncols = ncol(df)
    sallocs = Ptr{Cvoid}[]
    aallocs = Ptr{Cvoid}[]
    schildren = Ptr{Ptr{ArrowSchema}}(cmalloc!(sallocs, ncols * sizeof(Ptr{Cvoid})))
    achildren = Ptr{Ptr{ArrowArray}}(cmalloc!(aallocs, ncols * sizeof(Ptr{Cvoid})))
    exported = zeros(Bool, ncols)  # which children own their buffers (freed on failure)
    try
        # The parent's allocation lists are only touched here, on one task
        for i in 1:ncols
            unsafe_store!(schildren, Ptr{ArrowSchema}(cmalloc!(sallocs, sizeof(ArrowSchema))), i)
            unsafe_store!(achildren, Ptr{ArrowArray}(cmalloc!(aallocs, sizeof(ArrowArray))), i)
        end
        # Columns are independent (each export_column! has its own allocations),
        # so large tables export them concurrently
        export_one(i) = (export_column!(unsafe_load(schildren, i), unsafe_load(achildren, i),
                                        names(df)[i], df[!, i]; nullable); exported[i] = true)
        if parallel && ncols > 1
            failures, failures_lock = Any[], ReentrantLock()
            @sync for i in 1:ncols
                Threads.@spawn try
                    export_one(i)
                catch e  # @sync waits for every task; failures are checked below
                    lock(() -> push!(failures, e), failures_lock)
                end
            end
            isempty(failures) || throw(first(failures))
        else
            foreach(export_one, 1:ncols)
        end
        buffers = Ptr{Ptr{Cvoid}}(cmalloc!(aallocs, sizeof(Ptr{Cvoid})))  # [validity = NULL]
        f = cstring!(sallocs, "+s")
        n = cstring!(sallocs, "")
        unsafe_store!(out_array, ArrowArray(nrow(df), 0, 0, 1, ncols, buffers, achildren, C_NULL,
                                            array_release_ptr(), private_block(aallocs)))
        unsafe_store!(out_schema, ArrowSchema(f, n, C_NULL, 0, ncols, schildren, C_NULL,
                                              schema_release_ptr(), private_block(sallocs)))
    catch
        for i in 1:ncols
            exported[i] || continue
            release_schema(unsafe_load(schildren, i))
            release_array(unsafe_load(achildren, i))
        end
        free_allocs(sallocs)
        free_allocs(aallocs)
        rethrow()
    end
    return
end
