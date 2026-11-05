module KaosCleaner

using CSV, DataFrames

export load_dataset, clean_dataset, export_dataframe

include("cleaning.jl")
include("cdata.jl")

# Message for the most recent failure, readable from C via kaos_last_error().
const LAST_ERROR = Ref("")

set_error!(msg::AbstractString) = (LAST_ERROR[] = replace(msg, '\0' => ' '); nothing)

"""
    process_dataset(filepath, out_schema, out_array) -> Cint

Load and clean `filepath`, then export the result through the Arrow C Data
Interface into the caller-allocated `ArrowSchema`/`ArrowArray` structs.
Returns 0 on success and 1 on failure (see `kaos_last_error`).
"""
function process_dataset(filepath::AbstractString, out_schema::Ptr, out_array::Ptr)::Cint
    try
        df = clean_dataset(load_dataset(filepath))
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

# C entry point: int process_dataset(const char*, struct ArrowSchema*, struct ArrowArray*)
Base.@ccallable function process_dataset(filepath::Cstring, out_schema::Ptr{Cvoid}, out_array::Ptr{Cvoid})::Cint
    if filepath == C_NULL
        set_error!("filepath must not be NULL")
        return 1
    end
    return process_dataset(unsafe_string(filepath), out_schema, out_array)
end

# C entry point: const char* kaos_last_error(void). The pointer stays valid
# until the next call into the library.
Base.@ccallable function kaos_last_error()::Cstring
    return Base.unsafe_convert(Cstring, LAST_ERROR[])
end

end
