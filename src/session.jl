# Live cleaning sessions: tables cleaned batch by batch as they arrive (a
# sensor feed, a message queue), with what streaming keeps between chunks kept
# between calls: column types decided by the first batch, duplicate
# fingerprints, the last value of each column for ffill, and row numbers.

mutable struct Session
    opts::CleanOptions
    lock::ReentrantLock
    columns::Union{Nothing, Vector{String}}  # output columns, fixed by the first batch
    types::Dict{String, Type}                # their element types (non-missing)
    conversions::Dict{String, Conversion}    # inferred on the first batch, applied to the rest
    seen::Union{Nothing, Set{Tuple{UInt, UInt}}}
    carry::Dict{String, Any}
    rows::Int                                # input rows so far, for source_row
end

function Session(opts::CleanOptions)
    opts.raw && throw(ArgumentError("the raw option reads files; it does not apply to sessions"))
    check_incremental(opts, "in a live session")
    if opts.impute !== nothing
        strategies = opts.impute isa Dict ? values(opts.impute) : (opts.impute,)
        for s in strategies
            s in STREAMING_IMPUTE || throw(ArgumentError(
                "impute strategy `$s` needs the whole data; in a live session use $(join(STREAMING_IMPUTE, " or "))"))
        end
    end
    return Session(opts, ReentrantLock(), nothing, Dict{String, Type}(), Dict{String, Conversion}(),
                   opts.dedupe ? Set{Tuple{UInt, UInt}}() : nothing, Dict{String, Any}(), 0)
end

"""
    clean_batch!(s, df) -> df

Clean the next batch of a session. The first batch decides the output
columns and their types; later batches must have the same columns, and values
that do not fit a column's type become missing (counted in a warning).
"""
function clean_batch!(s::Session, df::DataFrame)
    opts = s.opts
    rows = opts.source_row ? collect(s.rows .+ (1:nrow(df))) : nothing
    opts.rename && rename!(df, normalize_name.(names(df)); makeunique=true)
    select_columns!(df, opts)
    clean_strings!(df, Markers(opts.missing_values))
    if s.columns === nothing
        opts.infer_types && merge!(s.conversions, infer_types!(df, opts))
        merge!(s.conversions, apply_epochs!(df, opts))
        s.columns = names(df)
        for name in names(df)
            s.types[name] = text_type(nonmissingtype(eltype(df[!, name])))
        end
    else
        names(df) == s.columns || throw(ArgumentError(
            "this batch has columns $(join(names(df), ", ")); the session's first batch had $(join(s.columns, ", "))"))
        fit_batch!(s, df)
    end
    s.rows += nrow(df)
    opts.drop_empty_rows && drop_empty_rows!(df, rows)
    seen = s.seen
    seen === nothing || drop_seen_rows!(df, seen, rows)
    impute_session!(s, df)
    return add_source_row!(df, rows)
end

# Later batches: the first batch's conversions, and its types
function fit_batch!(s::Session, df::DataFrame)
    for name in s.columns
        col = df[!, name]
        c = get(s.conversions, name, nothing)
        T = s.types[name]
        if c !== nothing && !fits(col, T)
            out, failures = apply_conversion(c, col)
        elseif fits(col, T) || nonmissingtype(eltype(col)) === Union{}
            nonmissingtype(eltype(col)) === Union{} && (df[!, name] = Vector{Union{Missing, T}}(missing, length(col)))
            continue
        else
            out, failures = coerce_column(col, T)
        end
        failures > 0 && @warn "$failures value$(failures == 1 ? "" : "s") in `$name` did not fit $(nameof(T)) and became missing"
        df[!, name] = out
    end
    return df
end

function impute_session!(s::Session, df::DataFrame)
    impute = s.opts.impute
    impute === nothing && return
    plan = impute isa Dict ? impute : Dict(n => impute for n in s.columns)
    for (name, strategy) in plan
        name in names(df) || throw(ArgumentError("impute: no column named $name"))
        col = df[!, name]
        if strategy == "zero"
            is_numeric(s.types[name]) || (impute isa Dict ?
                throw(ArgumentError("impute: `zero` needs a numeric column, `$name` is $(s.types[name])")) : continue)
            df[!, name] = fill_zero(col)
        else  # ffill, carrying the last value over from the previous batch
            df[!, name], s.carry[name] = fill_forward(col, get(s.carry, name, missing))
        end
    end
end

# ---------------------------------------------------------------------------
# C entry points. Sessions live in SESSIONS under an id until closed.

const SESSIONS = Dict{Int64, Session}()
const SESSIONS_LOCK = ReentrantLock()
const NEXT_SESSION_ID = Ref(Int64(0))

"Open a session with `options_json`; returns its id, or 0 on failure (see kaos_last_error)."
function session_open(options_json::AbstractString)::Int64
    try
        s = Session(parse_options(options_json))
        id = lock(SESSIONS_LOCK) do
            NEXT_SESSION_ID[] += 1
            SESSIONS[NEXT_SESSION_ID[]] = s
            NEXT_SESSION_ID[]
        end
        set_error!("")
        return id
    catch e
        set_error!(sprint(showerror, e))
        return 0
    end
end

"""
    session_clean(id, in_schema, in_array, out_schema, out_array) -> Cint

Clean the next batch of session `id`, a record batch passed in through the
Arrow C Data Interface (always released), into `out_schema`/`out_array`. Every
output field is nullable, so batches share one schema. Returns 0 or 1.
"""
function session_clean(id::Integer, in_schema::Ptr, in_array::Ptr, out_schema::Ptr, out_array::Ptr)::Cint
    status = with_logger(LOGGER) do
        try
            df = import_dataframe(Ptr{ArrowSchema}(in_schema), Ptr{ArrowArray}(in_array))
            s = lock(() -> get(SESSIONS, Int64(id), nothing), SESSIONS_LOCK)
            s === nothing && throw(ArgumentError("no open session with id $id"))
            df = lock(() -> clean_batch!(s, df), s.lock)
            (out_schema == C_NULL || out_array == C_NULL) &&
                throw(ArgumentError("out_schema and out_array must not be NULL"))
            export_dataframe(df, Ptr{ArrowSchema}(out_schema), Ptr{ArrowArray}(out_array); nullable=true)
            set_error!("")
            Cint(0)
        catch e
            set_error!(sprint(showerror, e))
            Cint(1)
        end
    end
    GC.gc(false)
    return status
end

"Close session `id` and free its state; unknown ids are ignored."
session_close(id::Integer) = (lock(() -> delete!(SESSIONS, Int64(id)), SESSIONS_LOCK); nothing)
