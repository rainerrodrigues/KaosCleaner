module KaosCleaner

using CSV, DataFrames, Dates, JSON3, Logging

export load_dataset, clean_dataset, clean_dataset!, export_dataframe, CleanOptions, Timestamp

"Below this many rows, splitting work across tasks costs more than it saves."
const PARALLEL_MIN_ROWS = 50_000

include("timestamps.jl")
include("options.jl")
include("cleaning.jl")
include("inference.jl")
include("sensor.jl")
include("logging.jl")
include("cdata.jl")
include("cimport.jl")
include("streaming.jl")
include("session.jl")

# Message for the most recent failure, readable from C via kaos_last_error().
const LAST_ERROR = Ref("")
# Last kaos_take_logs() result, kept alive for the returned pointer.
const LAST_LOGS = Ref("[]")

set_error!(msg::AbstractString) = (LAST_ERROR[] = replace(msg, '\0' => ' '); nothing)

"""
    process_dataset(filepath, options_json, out_schema, out_array) -> Cint

Load and clean `filepath` with the options in `options_json` (a JSON object,
see `CleanOptions`; "" for the defaults), then export the result through the
Arrow C Data Interface into the caller-allocated `ArrowSchema`/`ArrowArray`
structs. Returns 0 on success and 1 on failure (see `kaos_last_error`).
"""
function process_dataset(filepath::AbstractString, options_json::AbstractString, out_schema::Ptr, out_array::Ptr)::Cint
    # Task-local, so CSV.jl's worker tasks log here too, without touching the
    # global logger of Julia users of this package.
    status = with_logger(() -> _process_dataset(filepath, options_json, out_schema, out_array), LOGGER)
    # The exported buffers live outside the Julia heap, so everything Julia
    # allocated for this file is garbage now. Collect it before handing control
    # back: left to its own heuristics, the GC keeps hundreds of MB of dead
    # DataFrames around between calls (~5% slower, much flatter memory).
    GC.gc(false)
    return status
end

process_dataset(filepath::AbstractString, out_schema::Ptr, out_array::Ptr) =
    process_dataset(filepath, "", out_schema, out_array)

function _process_dataset(filepath::AbstractString, options_json::AbstractString, out_schema::Ptr, out_array::Ptr)::Cint
    try
        opts = parse_options(options_json)
        df = clean_dataset!(load_dataset(filepath, opts), opts)
        (out_schema == C_NULL || out_array == C_NULL) &&
            throw(ArgumentError("out_schema and out_array must not be NULL"))
        export_dataframe(df, Ptr{ArrowSchema}(out_schema), Ptr{ArrowArray}(out_array))
        set_error!("")
        return 0
    catch e
        set_error!(sprint(showerror, e))
        return 1
    end
end

"""
    clean_arrow(in_schema, in_array, options_json, out_schema, out_array) -> Cint

Clean a table passed in through the Arrow C Data Interface (a record batch,
e.g. exported by pyarrow) and export the result into `out_schema`/`out_array`.
The input structs are always released. Parsing options (delimiter, ...) do not
apply. Returns 0 on success and 1 on failure (see `kaos_last_error`).
"""
function clean_arrow(in_schema::Ptr, in_array::Ptr, options_json::AbstractString, out_schema::Ptr, out_array::Ptr)::Cint
    status = with_logger(LOGGER) do
        try
            # Import first: it releases the input even if the options are invalid
            df = import_dataframe(Ptr{ArrowSchema}(in_schema), Ptr{ArrowArray}(in_array))
            df = clean_dataset!(df, parse_options(options_json))
            (out_schema == C_NULL || out_array == C_NULL) &&
                throw(ArgumentError("out_schema and out_array must not be NULL"))
            export_dataframe(df, Ptr{ArrowSchema}(out_schema), Ptr{ArrowArray}(out_array))
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

# C entry point: int kaos_clean_arrow(struct ArrowSchema* in_schema, struct ArrowArray* in_array,
#     const char* options_json, struct ArrowSchema* out_schema, struct ArrowArray* out_array)
Base.@ccallable function kaos_clean_arrow(in_schema::Ptr{Cvoid}, in_array::Ptr{Cvoid}, options_json::Cstring,
                                          out_schema::Ptr{Cvoid}, out_array::Ptr{Cvoid})::Cint
    (in_schema == C_NULL || in_array == C_NULL) && (set_error!("in_schema and in_array must not be NULL"); return 1)
    options = options_json == C_NULL ? "" : unsafe_string(options_json)
    return clean_arrow(in_schema, in_array, options, out_schema, out_array)
end

# C entry point: int process_dataset(const char*, struct ArrowSchema*, struct ArrowArray*)
Base.@ccallable function process_dataset(filepath::Cstring, out_schema::Ptr{Cvoid}, out_array::Ptr{Cvoid})::Cint
    if filepath == C_NULL
        set_error!("filepath must not be NULL")
        return 1
    end
    return process_dataset(unsafe_string(filepath), out_schema, out_array)
end

# C entry point: int process_dataset_with_options(const char* filepath,
#     const char* options_json, struct ArrowSchema*, struct ArrowArray*)
Base.@ccallable function process_dataset_with_options(filepath::Cstring, options_json::Cstring,
                                                      out_schema::Ptr{Cvoid}, out_array::Ptr{Cvoid})::Cint
    if filepath == C_NULL
        set_error!("filepath must not be NULL")
        return 1
    end
    options = options_json == C_NULL ? "" : unsafe_string(options_json)
    return process_dataset(unsafe_string(filepath), options, out_schema, out_array)
end

# C entry point: int kaos_open_stream(const char* filepath, const char* options_json,
#     int64_t chunk_bytes, struct ArrowArrayStream* out_stream)
# Out-of-core cleaning: batches are parsed and cleaned as the consumer pulls them.
Base.@ccallable function kaos_open_stream(filepath::Cstring, options_json::Cstring, chunk_bytes::Int64,
                                          out_stream::Ptr{Cvoid})::Cint
    (filepath == C_NULL || out_stream == C_NULL) && (set_error!("filepath and out_stream must not be NULL"); return 1)
    try
        options = options_json == C_NULL ? "" : unsafe_string(options_json)
        s = with_logger(LOGGER) do
            open_stream(unsafe_string(filepath), parse_options(options), chunk_bytes)
        end
        export_stream!(Ptr{ArrowArrayStream}(out_stream), s)
        set_error!("")
        return 0
    catch e
        set_error!(sprint(showerror, e))
        return 1
    end
end

# C entry point: int64_t kaos_session_open(const char* options_json). Returns
# the id of a new live cleaning session, or 0 on failure (see kaos_last_error).
Base.@ccallable function kaos_session_open(options_json::Cstring)::Int64
    options = options_json == C_NULL ? "" : unsafe_string(options_json)
    return with_logger(() -> session_open(options), LOGGER)
end

# C entry point: int kaos_session_clean(int64_t id, struct ArrowSchema* in_schema,
#     struct ArrowArray* in_array, struct ArrowSchema* out_schema, struct ArrowArray* out_array)
Base.@ccallable function kaos_session_clean(id::Int64, in_schema::Ptr{Cvoid}, in_array::Ptr{Cvoid},
                                            out_schema::Ptr{Cvoid}, out_array::Ptr{Cvoid})::Cint
    (in_schema == C_NULL || in_array == C_NULL) && (set_error!("in_schema and in_array must not be NULL"); return 1)
    return session_clean(id, in_schema, in_array, out_schema, out_array)
end

# C entry point: void kaos_session_close(int64_t id)
Base.@ccallable function kaos_session_close(id::Int64)::Cvoid
    session_close(id)
    return nothing
end

# C entry point: const char* kaos_last_error(void). The pointer stays valid
# until the next call into the library.
Base.@ccallable function kaos_last_error()::Cstring
    return Base.unsafe_convert(Cstring, LAST_ERROR[])
end

# C entry point: const char* kaos_take_logs(void). Log records since the last
# call as a JSON array of [level, message] (Julia levels: Info 0, Warn 1000,
# Error 2000). Valid until the next call into the library.
Base.@ccallable function kaos_take_logs()::Cstring
    LAST_LOGS[] = replace(JSON3.write(take_logs!()), '\0' => ' ')
    return Base.unsafe_convert(Cstring, LAST_LOGS[])
end

end
