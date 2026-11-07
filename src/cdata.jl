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
tostr(x::AbstractString) = valid_utf8(x)
tostr(x) = valid_utf8(string(x))

function encode!(allocs, ::Type, col)
    total = 0
    for x in col
        ismissing(x) || (total += ncodeunits(tostr(x)))
    end
    total <= typemax(Int32) ? encode_strings!(allocs, "u", Int32, col, total) :
                              encode_strings!(allocs, "U", Int64, col, total)
end

function encode_strings!(allocs, fmt, ::Type{O}, col, total) where {O}
    valid, nulls = validity!(allocs, col)
    offsets = Ptr{O}(cmalloc!(allocs, (length(col) + 1) * sizeof(O)))
    data = Ptr{UInt8}(cmalloc!(allocs, total))
    pos = 0
    for (i, x) in enumerate(col)
        if !ismissing(x)
            for b in codeunits(tostr(x))
                pos += 1
                unsafe_store!(data, b, pos)
            end
        end
        unsafe_store!(offsets, O(pos), i + 1)
    end
    return fmt, Ptr{Cvoid}[valid, offsets, data], nulls
end

# ---------------------------------------------------------------------------

# Fill `sch`/`arr` for one column. On failure everything allocated is freed.
function export_column!(sch::Ptr{ArrowSchema}, arr::Ptr{ArrowArray}, name::String, col::AbstractVector)
    sallocs = Ptr{Cvoid}[]
    aallocs = Ptr{Cvoid}[]
    try
        T = nonmissingtype(eltype(col))
        fmt, bufs, nulls = encode!(aallocs, T, col)
        flags = (T === eltype(col) && T !== Union{}) ? Int64(0) : ARROW_FLAG_NULLABLE

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
    export_dataframe(df, out_schema, out_array)

Export `df` through the Arrow C Data Interface into caller-allocated
`ArrowSchema`/`ArrowArray` structs. Ownership passes to the caller, who must
eventually call each struct's `release` callback.
"""
function export_dataframe(df::AbstractDataFrame, out_schema::Ptr{ArrowSchema}, out_array::Ptr{ArrowArray})
    ncols = ncol(df)
    sallocs = Ptr{Cvoid}[]
    aallocs = Ptr{Cvoid}[]
    schildren = Ptr{Ptr{ArrowSchema}}(cmalloc!(sallocs, ncols * sizeof(Ptr{Cvoid})))
    achildren = Ptr{Ptr{ArrowArray}}(cmalloc!(aallocs, ncols * sizeof(Ptr{Cvoid})))
    done = 0
    try
        for (i, name) in enumerate(names(df))
            cs = Ptr{ArrowSchema}(cmalloc!(sallocs, sizeof(ArrowSchema)))
            ca = Ptr{ArrowArray}(cmalloc!(aallocs, sizeof(ArrowArray)))
            unsafe_store!(schildren, cs, i)
            unsafe_store!(achildren, ca, i)
            export_column!(cs, ca, name, df[!, name])
            done = i
        end
        buffers = Ptr{Ptr{Cvoid}}(cmalloc!(aallocs, sizeof(Ptr{Cvoid})))  # [validity = NULL]
        f = cstring!(sallocs, "+s")
        n = cstring!(sallocs, "")
        unsafe_store!(out_array, ArrowArray(nrow(df), 0, 0, 1, ncols, buffers, achildren, C_NULL,
                                            array_release_ptr(), private_block(aallocs)))
        unsafe_store!(out_schema, ArrowSchema(f, n, C_NULL, 0, ncols, schildren, C_NULL,
                                              schema_release_ptr(), private_block(sallocs)))
    catch
        for i in 1:done
            release_schema(unsafe_load(schildren, i))
            release_array(unsafe_load(achildren, i))
        end
        free_allocs(sallocs)
        free_allocs(aallocs)
        rethrow()
    end
    return
end
