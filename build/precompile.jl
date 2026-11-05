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

csvs = [path]
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

# Error path
GC.@preserve begin
    KaosCleaner.process_dataset(Base.unsafe_convert(Cstring, "dummy.csv"), C_NULL, C_NULL)
    unsafe_string(KaosCleaner.kaos_last_error())
end
