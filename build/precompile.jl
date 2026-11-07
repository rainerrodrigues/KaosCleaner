# Precompile trace for create_library: exercise the real C entry point on a
# CSV covering every column type the exporter handles, so CSV parsing,
# cleaning and Arrow export are all compiled into libkaoscleaner.
using KaosCleaner
using KaosCleaner: ArrowSchema, ArrowArray

path = joinpath(mktempdir(), "trace.csv")
write(path, """
Int Col,Float Col,Bool Col,Date Col,DateTime Col,Text Col,Empty Col
1,1.5,true,2024-01-01,2024-01-01T10:00:00,a,
2,NA,false,2024-01-02,2024-01-02T11:30:00, b ,NA
,3.5,,,,NA,
2,NA,false,2024-01-02,2024-01-02T11:30:00, b ,NA
""")

# Big enough for CSV.jl to parse in parallel (build.jl runs this with
# threads), so the multi-threaded parsing path is compiled in as well.
big = joinpath(dirname(path), "trace_big.csv")
open(big, "w") do io
    println(io, "ID,Reading, Place ,When,Label")
    for i in 1:60_000  # above PARALLEL_MIN_ROWS, so the parallel paths are compiled in
        println(io, i, ",", isodd(i) ? "NA" : string(i / 7), ",", (" loc_1", "loc_2 ", "N/A")[i % 3 + 1],
                ",2024-01-0", i % 9 + 1, "T10:30:00,label_", i % 997)
    end
end

csvs = [path, big]
sample = joinpath(@__DIR__, "..", "test_set.csv")
isfile(sample) && push!(csvs, sample)

for csv in csvs
    schema = Libc.calloc(1, sizeof(ArrowSchema))
    array = Libc.calloc(1, sizeof(ArrowArray))
    rc = GC.@preserve csv KaosCleaner.process_dataset(Base.unsafe_convert(Cstring, csv), schema, array)
    rc == 0 || error("precompile trace failed: ", unsafe_string(KaosCleaner.kaos_last_error()))
    KaosCleaner.release!(schema, array)
    Libc.free(schema)
    Libc.free(array)
end

# Options, type inference, imputation and log collection
messy = joinpath(dirname(path), "trace_messy.csv")
write(messy, """
Paid,Amount,Day,Score,City
Yes,"\$1,200.50",13/01/2024,1.5,A
no,€3,02/02/2024,,
Y,40,28/02/2024,3,A
""")
options = """{"drop": ["City"], "impute": {"score": "median"}, "missing_values": ["-"],
              "datetime_formats": ["dd/mm/yyyy"]}"""
for opts in (options, """{"impute": "ffill"}""", """{"impute": "mean"}""", """{"impute": "mode"}""")
    schema = Libc.calloc(1, sizeof(ArrowSchema))
    array = Libc.calloc(1, sizeof(ArrowArray))
    rc = GC.@preserve messy opts KaosCleaner.process_dataset_with_options(
        Base.unsafe_convert(Cstring, messy), Base.unsafe_convert(Cstring, opts), schema, array)
    rc == 0 || error("precompile trace failed: ", unsafe_string(KaosCleaner.kaos_last_error()))
    KaosCleaner.release!(schema, array)
    Libc.free(schema)
    Libc.free(array)
end
unsafe_string(KaosCleaner.kaos_take_logs())

# Streaming: open a stream over the big file in small chunks and drain it
# through its C callbacks, as pyarrow does
using KaosCleaner: ArrowArrayStream
# A file whose later rows do not fit the sampled types, so the strict-parse
# fallback and coerce_column are compiled in too
misfit = joinpath(dirname(path), "trace_misfit.csv")
open(misfit, "w") do io
    println(io, "n,when,label")
    for i in 1:(KaosCleaner.SAMPLE_ROWS + 5_000)
        late = i > KaosCleaner.SAMPLE_ROWS
        println(io, late ? "$(i).5" : string(i), ",", late ? "soon" : "2024-01-02T10:30:00", ",x", i)
    end
end
for (file, opts) in ((big, ""), (big, """{"impute": "ffill"}"""), (misfit, ""))
    st = Ptr{ArrowArrayStream}(Libc.calloc(1, sizeof(ArrowArrayStream)))
    rc = GC.@preserve file opts KaosCleaner.kaos_open_stream(
        Base.unsafe_convert(Cstring, file), Base.unsafe_convert(Cstring, opts), Int64(256 * 1024), Ptr{Cvoid}(st))
    rc == 0 || error("precompile trace failed: ", unsafe_string(KaosCleaner.kaos_last_error()))
    s = unsafe_load(st)
    sch = Ptr{ArrowSchema}(Libc.calloc(1, sizeof(ArrowSchema)))
    arr = Ptr{ArrowArray}(Libc.calloc(1, sizeof(ArrowArray)))
    ccall(s.get_schema, Cint, (Ptr{ArrowArrayStream}, Ptr{ArrowSchema}), st, sch)
    while ccall(s.get_next, Cint, (Ptr{ArrowArrayStream}, Ptr{ArrowArray}), st, arr) == 0
        unsafe_load(arr).release == C_NULL && break
        ccall(unsafe_load(arr).release, Cvoid, (Ptr{ArrowArray},), arr)
    end
    ccall(unsafe_load(sch).release, Cvoid, (Ptr{ArrowSchema},), sch)
    ccall(s.release, Cvoid, (Ptr{ArrowArrayStream},), st)
    foreach(Libc.free, (st, sch, arr))
end
unsafe_string(KaosCleaner.kaos_take_logs())

# Error path
GC.@preserve begin
    KaosCleaner.process_dataset(Base.unsafe_convert(Cstring, "does_not_exist.csv"), C_NULL, C_NULL)
    unsafe_string(KaosCleaner.kaos_last_error())
end
