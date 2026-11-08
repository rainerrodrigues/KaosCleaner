# Out-of-core cleaning. A file is parsed and cleaned chunk by chunk and handed
# to the host through the Arrow C Stream Interface, one record batch at a time,
# so memory use follows the chunk size rather than the file size.
# https://arrow.apache.org/docs/format/CStreamInterface.html
#
# Batches of a stream must share one schema, so column types and conversions
# are decided once, from a sample at the start of the file, and later chunks
# are made to fit them: values that do not fit become missing, counted in a
# logged warning. Duplicates are found across the whole file through a 128-bit
# fingerprint per distinct row. Imputation is limited to strategies that need
# no look-ahead (zero, ffill).

struct ArrowArrayStream
    get_schema::Ptr{Cvoid}
    get_next::Ptr{Cvoid}
    get_last_error::Ptr{Cvoid}
    release::Ptr{Cvoid}
    private_data::Ptr{Cvoid}
end

const SAMPLE_ROWS = 20_000
const STREAMING_IMPUTE = ("zero", "ffill")
const EIO = Cint(5)
const EINVAL = Cint(22)

"How one output column is produced from a column of the file."
struct ColumnPlan
    source::String                         # header in the file
    name::String                           # output name
    parse_type::Type                       # what CSV.jl parses it as
    conversion::Union{Nothing, Conversion} # applied after parsing
    out_type::Type                         # output element type (non-missing)
end

"The whole file as a single chunk, parsed when it is read (like CSV.Chunks)."
struct WholeFile
    path::String
    kwargs::NamedTuple
end
Base.length(::WholeFile) = 1
Base.iterate(w::WholeFile, i=1) = i > 1 ? nothing : (CSV.File(w.path; w.kwargs...), i + 1)

mutable struct CleanStream
    plan::Vector{ColumnPlan}
    opts::CleanOptions
    markers::Markers
    chunks::Union{CSV.Chunks, WholeFile}   # planned types, strict: iterate(chunks, i) -> (CSV.File, i + 1)
    fallback::Union{CSV.Chunks, WholeFile, Nothing}  # same chunks, only text typed; made on first misfit
    fallback_args::Tuple{String, Int, NamedTuple}    # (path, nchunks, kwargs) to make it
    next_chunk::Int
    seen::Union{Nothing, Set{Tuple{UInt, UInt}}}  # row fingerprints, for dedupe
    carry::Dict{String, Any}                      # last value per column, for ffill
    rows::Int
    empty_rows::Int
    duplicates::Int
    error::String
end

text_type(T) = (T === Union{} || T <: AbstractString) ? String : T

"Decide output columns, types and conversions from the first rows of `path`."
function stream_plan(path::AbstractString, opts::CleanOptions)
    sample = DataFrame(CSV.File(path; limit=SAMPLE_ROWS, missingstring=vcat(MISSING_STRINGS, opts.missing_values),
                                stripwhitespace=true); copycols=true)
    sources = names(sample)
    parse_types = Dict(s => text_type(nonmissingtype(eltype(sample[!, s]))) for s in sources)
    opts.rename && rename!(sample, normalize_name.(sources); makeunique=true)
    source_of = Dict(zip(names(sample), sources))
    select_columns!(sample, opts)
    clean_strings!(sample, Markers(opts.missing_values))
    conversions = opts.infer_types ? infer_types!(sample, opts) : Dict{String, Conversion}()
    plan = map(names(sample)) do name
        source = source_of[name]
        conversion = get(conversions, name, nothing)
        ColumnPlan(source, name, parse_types[source], conversion,
                   conversion === nothing ? parse_types[source] : output_type(conversion))
    end
    isempty(plan) && throw(ArgumentError("no columns left to output"))
    return plan
end

function check_streaming_impute(plan::Vector{ColumnPlan}, opts::CleanOptions)
    opts.impute === nothing && return
    strategies = opts.impute isa Dict ? collect(opts.impute) : ["" => opts.impute]
    for (name, strategy) in strategies
        strategy in STREAMING_IMPUTE || throw(ArgumentError(
            "impute strategy `$strategy` needs the whole file; when streaming use $(join(STREAMING_IMPUTE, " or ")), or impute afterwards"))
        isempty(name) && continue
        p = findfirst(p -> p.name == name, plan)
        p === nothing && throw(ArgumentError("impute: no column named $name"))
        strategy == "zero" && !is_numeric(plan[p].out_type) &&
            throw(ArgumentError("impute: `zero` needs a numeric column, `$name` is $(plan[p].out_type)"))
    end
end

is_numeric(T) = T <: Real && !(T <: Bool)

"""
    open_stream(path, opts, chunk_bytes) -> CleanStream

Plan the output from a sample, then prepare to parse `path` in chunks of
about `chunk_bytes`.
"""
function open_stream(path::AbstractString, opts::CleanOptions, chunk_bytes::Integer)
    isfile(path) || throw(ArgumentError("file not found: $path"))
    chunk_bytes > 0 || throw(ArgumentError("chunk size must be positive"))
    plan = stream_plan(path, opts)
    check_streaming_impute(plan, opts)
    nchunks = max(1, cld(filesize(path), chunk_bytes))
    # Chunks are parsed with the planned types in strict mode, which is fast
    # and raises at the first value that does not fit (without strict, CSV.jl
    # silently turns misfits into missings, reporting only the first 100). A
    # chunk that raises is parsed again with only its text columns typed, and
    # coerce_column then counts every misfit. Chunk boundaries do not depend
    # on the types, so both parses split the file identically.
    base = (select=[p.source for p in plan], missingstring=vcat(MISSING_STRINGS, opts.missing_values),
            stripwhitespace=true)
    typed = Dict(p.source => Union{Missing, p.parse_type} for p in plan)
    text = Dict(p.source => Union{Missing, String} for p in plan if p.parse_type === String)
    chunks = file_chunks(path, nchunks, (; base..., types=typed, strict=true))
    seen = opts.dedupe ? Set{Tuple{UInt, UInt}}() : nothing
    return CleanStream(plan, opts, Markers(opts.missing_values), chunks, nothing,
                       (String(path), nchunks, (; base..., types=text)), 1, seen, Dict{String, Any}(), 0, 0, 0, "")
end

"""
    file_chunks(path, nchunks, kwargs)

The chunks to parse `path` in: `CSV.Chunks`, or the whole file as one chunk.
CSV.jl only splits a file it would parse in parallel (more than one chunk and
a file that is not small); anything else is read with a single `CSV.File`.
"""
function file_chunks(path::AbstractString, nchunks::Integer, kwargs::NamedTuple)
    nchunks == 1 && return WholeFile(path, kwargs)
    try
        return CSV.Chunks(path; ntasks=nchunks, kwargs...)
    catch e
        e isa ArgumentError && occursin("unable to iterate chunks", e.msg) && return WholeFile(path, kwargs)
        rethrow()
    end
end

"Chunk `i`, parsed again without fixed numeric types if a value does not fit them."
function read_chunk(s::CleanStream, i::Int)
    try
        return iterate(s.chunks, i)
    catch e
        is_misfit(e) || rethrow()
        fallback = s.fallback
        fallback === nothing && (fallback = s.fallback = file_chunks(s.fallback_args...))
        return iterate(fallback, i)
    end
end

# A strict-mode parse error, possibly from one of the tasks CSV.jl parses a
# whole file with (then wrapped in a TaskFailedException)
is_misfit(e) = e isa CSV.Error ||
               (e isa TaskFailedException && is_misfit(e.task.result)) ||
               (e isa CompositeException && any(is_misfit, e.exceptions)) ||
               (e isa CapturedException && is_misfit(e.ex))

"The next cleaned, non-empty batch, or `nothing` at the end of the file."
function next_batch!(s::CleanStream)
    while s.next_chunk <= length(s.chunks)
        file, s.next_chunk = read_chunk(s, s.next_chunk)
        df = clean_chunk!(s, DataFrame(file; copycols=false))
        if nrow(df) > 0
            s.rows += nrow(df)
            return df
        end
    end
    s.empty_rows > 0 && @info "Dropped $(s.empty_rows) empty row$(s.empty_rows == 1 ? "" : "s")"
    s.duplicates > 0 && @info "Dropped $(s.duplicates) duplicate row$(s.duplicates == 1 ? "" : "s")"
    return nothing
end

# Element types a column may have and still export with its planned type
fits(col, T) = nonmissingtype(eltype(col)) !== Union{} &&
               eltype(col) <: Union{Missing, (T === String ? AbstractString : T)}

function clean_chunk!(s::CleanStream, df::DataFrame)
    rename!(df, [p.source => p.name for p in s.plan])
    select!(df, [p.name for p in s.plan])
    clean_strings!(df, s.markers)
    for p in s.plan
        col = df[!, p.name]
        p.conversion === nothing && fits(col, p.out_type) && continue
        out, failures = p.conversion === nothing ? coerce_column(col, p.out_type) : apply_conversion(p.conversion, col)
        failures > 0 && @warn "$failures value$(failures == 1 ? "" : "s") in `$(p.name)` did not fit $(nameof(p.out_type)) and became missing"
        df[!, p.name] = out
    end
    s.opts.drop_empty_rows && (s.empty_rows += drop_empty_rows!(df))
    seen = s.seen
    seen === nothing || (s.duplicates += drop_seen_rows!(df, seen))
    impute_stream!(s, df)
    return df
end

"""
    coerce_column(col, T) -> (Vector{Union{Missing, T}}, failures)

`col`, as CSV.jl inferred it for one chunk, converted to the planned element
type `T`. Values that cannot be represented (text in a numeric column, a
decimal in an integer column) become missing and are counted.
"""
function coerce_column(col::AbstractVector, ::Type{T}) where {T}
    out = Vector{Union{Missing, T}}(undef, length(col))
    failures = 0
    for (i, x) in enumerate(col)
        v = ismissing(x) ? missing : coerce_value(T, x)
        v === nothing && (failures += 1; v = missing)
        out[i] = v
    end
    return out, failures
end

function coerce_value(::Type{T}, x) where {T}
    x isa T && return x
    if x isa AbstractString
        return T === String ? String(x) : tryparse(T, x)
    elseif T <: Integer && x isa Real  # includes Bool: 0/1 columns
        return isinteger(x) && typemin(T) <= x <= typemax(T) ? T(x) : nothing
    elseif T <: AbstractFloat && x isa Real
        return T(x)
    elseif T === DateTime && x isa Date
        return DateTime(x)
    end
    return nothing
end

"Drop rows whose fingerprint was seen in this or an earlier batch."
function drop_seen_rows!(df::DataFrame, seen::Set{Tuple{UInt, UInt}})
    h1 = zeros(UInt, nrow(df))
    h2 = fill(UInt(0x9e3779b97f4a7c15), nrow(df))  # second, independently seeded hash
    for col in eachcol(df)
        hash_column!(h1, col)
        hash_column!(h2, col)
    end
    dup = falses(nrow(df))
    for i in eachindex(h1)
        key = (h1[i], h2[i])
        key in seen ? (dup[i] = true) : push!(seen, key)
    end
    n = count(dup)
    n > 0 && deleteat!(df, dup)
    return n
end

function impute_stream!(s::CleanStream, df::DataFrame)
    impute = s.opts.impute
    impute === nothing && return
    plan = impute isa Dict ? impute : Dict(p.name => impute for p in s.plan)
    for (name, strategy) in plan
        col = df[!, name]
        T = nonmissingtype(eltype(col))
        if strategy == "zero"
            is_numeric(T) && (df[!, name] = fill_zero(col))  # global strategy: numeric columns only
        else  # ffill, carrying the last value over from the previous batch
            df[!, name], s.carry[name] = fill_forward(col, get(s.carry, name, missing))
        end
    end
end

# ---------------------------------------------------------------------------
# C Stream Interface callbacks. Each stream's state lives in STREAMS, keyed by
# the id stored in private_data, until the consumer releases the stream.

const STREAMS = Dict{UInt, CleanStream}()
const STREAMS_LOCK = ReentrantLock()
const NEXT_STREAM_ID = Ref(UInt(0))

stream_state(p::Ptr{ArrowArrayStream}) =
    lock(() -> get(STREAMS, UInt(unsafe_load(p).private_data), nothing), STREAMS_LOCK)

function stream_get_schema(p::Ptr{ArrowArrayStream}, out::Ptr{ArrowSchema})::Cint
    s = stream_state(p)
    s === nothing && return EINVAL
    try
        empty = DataFrame([pl.name => Vector{Union{Missing, pl.out_type}}() for pl in s.plan])
        tmp = Ptr{ArrowArray}(Libc.calloc(1, sizeof(ArrowArray)))
        try
            export_dataframe(empty, out, tmp; nullable=true)
            release_array(tmp)
        finally
            Libc.free(tmp)
        end
        return 0
    catch e
        s.error = replace(sprint(showerror, e), '\0' => ' ')
        return EIO
    end
end

function stream_get_next(p::Ptr{ArrowArrayStream}, out::Ptr{ArrowArray})::Cint
    s = stream_state(p)
    s === nothing && return EINVAL
    try
        df = with_logger(() -> next_batch!(s), LOGGER)
        if df === nothing  # end of stream: a released (zeroed) array
            unsafe_store!(out, ArrowArray(0, 0, 0, 0, 0, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL))
        else
            tmp = Ptr{ArrowSchema}(Libc.calloc(1, sizeof(ArrowSchema)))
            try
                export_dataframe(df, tmp, out; nullable=true)
                release_schema(tmp)
            finally
                Libc.free(tmp)
            end
        end
        GC.gc(false)  # the chunk is garbage now; keep memory flat across batches
        return 0
    catch e
        s.error = replace(sprint(showerror, e), '\0' => ' ')
        return EIO
    end
end

function stream_get_last_error(p::Ptr{ArrowArrayStream})::Cstring
    s = stream_state(p)
    (s === nothing || isempty(s.error)) && return Cstring(C_NULL)
    return Base.unsafe_convert(Cstring, s.error)
end

function stream_release(p::Ptr{ArrowArrayStream})
    p == C_NULL && return
    st = unsafe_load(p)
    st.release == C_NULL && return
    lock(() -> delete!(STREAMS, UInt(st.private_data)), STREAMS_LOCK)
    unsafe_store!(Ptr{Ptr{Cvoid}}(p + fieldoffset(ArrowArrayStream, 4)), C_NULL)
    return
end

"Register `s` and fill the caller's ArrowArrayStream struct with its callbacks."
function export_stream!(out::Ptr{ArrowArrayStream}, s::CleanStream)
    id = lock(STREAMS_LOCK) do
        NEXT_STREAM_ID[] += 1
        STREAMS[NEXT_STREAM_ID[]] = s
        NEXT_STREAM_ID[]
    end
    unsafe_store!(out, ArrowArrayStream(
        @cfunction(stream_get_schema, Cint, (Ptr{ArrowArrayStream}, Ptr{ArrowSchema})),
        @cfunction(stream_get_next, Cint, (Ptr{ArrowArrayStream}, Ptr{ArrowArray})),
        @cfunction(stream_get_last_error, Cstring, (Ptr{ArrowArrayStream},)),
        @cfunction(stream_release, Cvoid, (Ptr{ArrowArrayStream},)),
        Ptr{Cvoid}(id)))
    return
end
