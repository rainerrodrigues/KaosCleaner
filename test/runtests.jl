using KaosCleaner, DataFrames, Dates, JSON3, Random, Test
using Aqua
using KaosCleaner: ArrowSchema, ArrowArray, ArrowArrayStream

# A value type whose hash is constant: distinct values collide on purpose
struct ConstHash
    v::Int
end
Base.hash(::ConstHash, h::UInt) = h
Base.isequal(x::ConstHash, y::ConstHash) = x.v == y.v

# Minimal consumer: read one exported child column back into Julia values.
function read_column(s::ArrowSchema, a::ArrowArray)
    fmt = unsafe_string(s.format)
    n = a.length
    bufs = [unsafe_load(a.buffers, i) for i in 1:a.n_buffers]
    fmt == "n" && return fill(missing, n)
    bit(p, i) = (unsafe_load(Ptr{UInt8}(p), (i - 1) >> 3 + 1) >> ((i - 1) & 7)) & 0x01 == 0x01
    valid(i) = bufs[1] == C_NULL || bit(bufs[1], i)
    get = if fmt == "l"
        i -> unsafe_load(Ptr{Int64}(bufs[2]), i)
    elseif fmt == "g"
        i -> unsafe_load(Ptr{Float64}(bufs[2]), i)
    elseif fmt == "b"
        i -> bit(bufs[2], i)
    elseif fmt == "tdD"
        i -> Date(1970) + Day(unsafe_load(Ptr{Int32}(bufs[2]), i))
    elseif fmt == "u"
        i -> begin
            lo = unsafe_load(Ptr{Int32}(bufs[2]), i)
            hi = unsafe_load(Ptr{Int32}(bufs[2]), i + 1)
            unsafe_string(Ptr{UInt8}(bufs[3]) + lo, hi - lo)
        end
    else
        error("unhandled format $fmt")
    end
    return [valid(i) ? get(i) : missing for i in 1:n]
end

function export_and_read(f)
    schema = Ptr{ArrowSchema}(Libc.calloc(1, sizeof(ArrowSchema)))
    array = Ptr{ArrowArray}(Libc.calloc(1, sizeof(ArrowArray)))
    try
        rc = f(schema, array)
        rc == 0 || return rc, nothing
        s, a = unsafe_load(schema), unsafe_load(array)
        @test unsafe_string(s.format) == "+s"
        @test s.n_children == a.n_children
        cols = map(1:s.n_children) do i
            cs = unsafe_load(unsafe_load(s.children, i))
            ca = unsafe_load(unsafe_load(a.children, i))
            @test ca.length == a.length
            unsafe_string(cs.name) => read_column(cs, ca)
        end
        KaosCleaner.release!(schema, array)
        @test unsafe_load(schema).release == C_NULL
        @test unsafe_load(array).release == C_NULL
        return rc, DataFrame(cols)
    finally
        Libc.free(schema)
        Libc.free(array)
    end
end

@testset "KaosCleaner" begin
    @testset "package quality (Aqua.jl)" begin
        # Ambiguities are checked for this package's own methods only:
        # DataFrames and CSV bring many of their own that are not ours to fix.
        Aqua.test_all(KaosCleaner; ambiguities=false)
        Aqua.test_ambiguities(KaosCleaner; recursive=false)
    end

    @testset "normalize_name" begin
        @test KaosCleaner.normalize_name(" Bill Length (mm)") == "bill_length_mm"
        @test KaosCleaner.normalize_name("***") == "column"
        @test KaosCleaner.normalize_name("caf\xe9") == "caf"  # U+FFFD is not a letter: dropped
    end

    @testset "options" begin
        o = KaosCleaner.parse_options("""{"drop": "ID", "impute": {"x": "ffill"}, "dedupe": false}""")
        @test o.drop == ["ID"] && o.impute == Dict("x" => "ffill") && !o.dedupe
        @test KaosCleaner.parse_options("").rename
        @test_throws ArgumentError KaosCleaner.parse_options("""{"dorp": 1}""")
        @test_throws ArgumentError KaosCleaner.parse_options("""{"impute": "avg"}""")
        @test_throws ArgumentError KaosCleaner.parse_options("""{"rename": "yes"}""")
        @test_throws ArgumentError KaosCleaner.parse_options("[1]")

        df = DataFrame("ID" => [1, 2], "Full Name" => ["a", "b"], "x" => [3, 4])
        @test names(clean_dataset(df, CleanOptions(drop=["ID"]))) == ["full_name", "x"]
        @test names(clean_dataset(df, CleanOptions(keep=["Full Name", "x"]))) == ["full_name", "x"]
        @test names(clean_dataset(df, CleanOptions(rename=false))) == ["ID", "Full Name", "x"]
        @test_throws ArgumentError clean_dataset(df, CleanOptions(drop=["nope"]))
        dup = DataFrame(a=[1, 1])
        @test nrow(clean_dataset(dup, CleanOptions(dedupe=false))) == 2
        @test isequal(clean_dataset(DataFrame(a=["x", "-"]), CleanOptions(missing_values=["-"], drop_empty_rows=false)).a, ["x", missing])
    end

    @testset "type inference" begin
        df = DataFrame(paid=["Yes", "no", missing, "T"], amount=["\$1,200.50", "€3", missing, "40"],
                       day=["13/01/2024", "02/02/2024", missing, "28/02/2024"],
                       ambiguous=["01/02/2024", "03/04/2024", missing, "05/06/2024"],
                       stamp=["2024-01-02 10:30", "2024-01-03 11:00", missing, "2024-01-04 12:15"],
                       words=["yes", "maybe", missing, "no"], count=["1,000", "25", missing, "3"])
        keep_rows = CleanOptions(drop_empty_rows=false)  # row 3 is all missing on purpose
        out = clean_dataset(df, keep_rows)
        @test isequal(out.paid, [true, false, missing, true])
        @test isequal(out.amount, [1200.5, 3.0, missing, 40.0])
        @test isequal(out.day, [Date(2024, 1, 13), Date(2024, 2, 2), missing, Date(2024, 2, 28)])
        @test eltype(out.ambiguous) == Union{Missing, String}          # dd/mm vs mm/dd: left alone
        @test isequal(clean_dataset(df, CleanOptions(datetime_formats=["mm/dd/yyyy"], drop_empty_rows=false)).ambiguous[1], Date(2024, 1, 2))
        @test out.stamp[1] == DateTime(2024, 1, 2, 10, 30)
        @test eltype(out.words) == Union{Missing, String}              # "maybe" is not a boolean
        @test isequal(out.count, [1000, 25, missing, 3])               # integers stay integers
        # Formatted integers beyond Int64 keep the column as text instead of failing (review fix)
        big = clean_dataset(DataFrame(n=["\$12,345,678,901,234,567,890", "\$1"]))
        @test eltype(big.n) == String
        @test eltype(clean_dataset(df, CleanOptions(infer_types=false, drop_empty_rows=false)).paid) == Union{Missing, String}
    end

    @testset "imputation" begin
        df = DataFrame(x=[1, missing, 3, missing], s=["a", missing, "a", "b"], e=[missing, missing, missing, missing])
        imp(strategy) = clean_dataset(df, CleanOptions(impute=strategy, dedupe=false, drop_empty_rows=false))
        @test imp("mean").x == [1, 2, 3, 2]
        @test imp("median").x == [1, 2, 3, 2]
        @test imp("zero").x == [1, 0, 3, 0]
        @test isequal(imp("mean").s, ["a", missing, "a", "b"])         # global numeric strategy skips text
        @test imp("mode").s == ["a", "a", "a", "b"]
        @test imp("ffill").x == [1, 1, 3, 3]
        @test isequal(imp("bfill").x, [1, 3, 3, missing])               # nothing after the last value
        @test all(ismissing, imp("mean").e)                             # all-missing column: nothing to fill from
        @test imp(Dict("x" => "zero", "s" => "ffill")).s == ["a", "a", "a", "b"]
        @test_throws ArgumentError imp(Dict("s" => "mean"))             # explicit misuse is an error
        @test_throws ArgumentError imp(Dict("nope" => "mean"))
    end

    @testset "log records are buffered, not printed" begin
        KaosCleaner.take_logs!()
        path = joinpath(mktempdir(), "logs.csv")
        write(path, "a,b\n1,2\n1,2\n,\n")
        s = Ptr{ArrowSchema}(Libc.calloc(1, sizeof(ArrowSchema))); a = Ptr{ArrowArray}(Libc.calloc(1, sizeof(ArrowArray)))
        @test KaosCleaner.process_dataset(path, "", s, a) == 0
        KaosCleaner.release!(s, a); Libc.free(s); Libc.free(a)
        msgs = last.(KaosCleaner.take_logs!())
        @test "Dropped 1 empty row" in msgs && "Dropped 1 duplicate row" in msgs
        @test isempty(KaosCleaner.take_logs!())
        @test JSON3.read(unsafe_string(KaosCleaner.kaos_take_logs())) == []
    end

    @testset "streaming (Arrow C Stream Interface)" begin
        # Consume a stream through its C callbacks, as pyarrow does
        function read_stream(path, options="", chunk_bytes=64)
            st = Ptr{ArrowArrayStream}(Libc.calloc(1, sizeof(ArrowArrayStream)))
            rc = GC.@preserve path options KaosCleaner.kaos_open_stream(
                Base.unsafe_convert(Cstring, path), Base.unsafe_convert(Cstring, options), Int64(chunk_bytes), Ptr{Cvoid}(st))
            rc == 0 || (Libc.free(st); return unsafe_string(KaosCleaner.kaos_last_error()))
            s = unsafe_load(st)
            sch = Ptr{ArrowSchema}(Libc.calloc(1, sizeof(ArrowSchema)))
            @test ccall(s.get_schema, Cint, (Ptr{ArrowArrayStream}, Ptr{ArrowSchema}), st, sch) == 0
            schema = unsafe_load(sch)
            names_ = [unsafe_string(unsafe_load(unsafe_load(schema.children, i)).name) for i in 1:schema.n_children]
            @test all(i -> unsafe_load(unsafe_load(schema.children, i)).flags == KaosCleaner.ARROW_FLAG_NULLABLE, 1:schema.n_children)
            batches = DataFrame[]
            arr = Ptr{ArrowArray}(Libc.calloc(1, sizeof(ArrowArray)))
            while true
                @test ccall(s.get_next, Cint, (Ptr{ArrowArrayStream}, Ptr{ArrowArray}), st, arr) == 0
                a = unsafe_load(arr)
                a.release == C_NULL && break  # end of stream
                cols = [names_[i] => read_column(unsafe_load(unsafe_load(schema.children, i)), unsafe_load(unsafe_load(a.children, i)))
                        for i in 1:a.n_children]
                push!(batches, DataFrame(cols))
                ccall(a.release, Cvoid, (Ptr{ArrowArray},), arr)
            end
            ccall(schema.release, Cvoid, (Ptr{ArrowSchema},), sch)
            ccall(s.release, Cvoid, (Ptr{ArrowArrayStream},), st)
            @test unsafe_load(st).release == C_NULL
            foreach(Libc.free, (st, sch, arr))
            return batches
        end

        dir = mktempdir()
        path = joinpath(dir, "stream.csv")
        open(path, "w") do io
            println(io, "ID, Paid ,Score,City")
            for i in 1:200
                println(io, i % 50, ",", isodd(i) ? "yes" : "no", ",", i % 7 == 0 ? "NA" : string(i % 50), ",", i % 3 == 0 ? "" : "c$(i % 50)")
            end
        end
        batches = read_stream(path)
        @test length(batches) > 3                                   # really chunked
        streamed = reduce(vcat, batches)
        @test isequal(streamed, clean_dataset(load_dataset(path)))  # same as in memory, dedupe across chunks
        @test nonmissingtype(eltype(streamed.paid)) == Bool         # conversion from the sample
        # One chunk covers the file (the default 256 MB, or CSV.jl declining to
        # split a small file): read as a single CSV.File instead of failing
        for chunk in (256 * 2^20, 2_000)
            whole = read_stream(path, "", chunk)
            @test whole isa Vector{DataFrame} && isequal(reduce(vcat, whole), streamed)
        end

        ff = reduce(vcat, read_stream(path, """{"impute": {"score": "ffill"}, "dedupe": false}"""))
        @test !any(ismissing, ff.score[2:end])                      # carried across batches
        @test KaosCleaner.take_logs!() isa Vector

        late = joinpath(dir, "late.csv")
        open(late, "w") do io
            println(io, "flag,n")
            for i in 1:(KaosCleaner.SAMPLE_ROWS + 10)
                println(io, i <= KaosCleaner.SAMPLE_ROWS ? (isodd(i) ? "yes" : "no") : "maybe", ",", i)
            end
        end
        KaosCleaner.take_logs!()
        lb = reduce(vcat, read_stream(late, "", 100_000))
        @test count(ismissing, lb.flag) == 10                        # "maybe" did not fit Bool
        @test any(m -> occursin("did not fit Bool", m), last.(KaosCleaner.take_logs!()))

        # Misfits beyond CSV.jl's 100-warning limit are all counted (review fix)
        decimals = joinpath(dir, "decimals.csv")
        open(decimals, "w") do io
            println(io, "n,label")
            for i in 1:(KaosCleaner.SAMPLE_ROWS + 500)
                println(io, i <= KaosCleaner.SAMPLE_ROWS ? string(i) : "$(i).5", ",x$(i)")
            end
        end
        KaosCleaner.take_logs!()
        db = reduce(vcat, read_stream(decimals, "", 100_000))
        @test count(ismissing, db.n) == 500
        @test any(m -> occursin("500 values in `n` did not fit Int64", m), last.(KaosCleaner.take_logs!()))
        # Same as one chunk: CSV.jl then parses with tasks, wrapping the error
        whole = reduce(vcat, read_stream(decimals, "", 256 * 2^20))
        @test count(ismissing, whole.n) == 500

        @test occursin("needs the whole file", read_stream(path, """{"impute": "median"}"""))
        @test occursin("file not found", read_stream(joinpath(dir, "nope.csv")))
        @test isempty(KaosCleaner.STREAMS)                           # every stream released

        # source_row survives chunking, empty-row and cross-chunk duplicate drops
        tracked = reduce(vcat, read_stream(path, """{"source_row": true}"""))
        o = CleanOptions(source_row=true)
        @test isequal(tracked, clean_dataset!(load_dataset(path, o), o))
        @test tracked.source_row == sort(tracked.source_row) && names(tracked)[1] == "source_row"
        @test occursin("not available when streaming", read_stream(path, """{"raw": true}"""))
    end

    @testset "byte_summary fast path matches the generic loop" begin
        IS = KaosCleaner.CSV.InlineStrings
        generic(s) = invoke(KaosCleaner.byte_summary, Tuple{AbstractString}, s)
        chars = vcat(collect(" \tab_9"), Char(0xe9), Char(0xa0), Char(0x3000))
        for T in (IS.String3, IS.String7, IS.String15), len in 0:sizeof(T)-1, _ in 1:20
            s = String(rand(chars, len))
            ncodeunits(s) < sizeof(T) || continue
            @test KaosCleaner.byte_summary(T(s)) == generic(T(s))
        end
        @test KaosCleaner.byte_summary(IS.String7("a\xff")) == generic(IS.String7("a\xff"))
    end

    @testset "Arrow import" begin
        df = DataFrame(i=[1, missing, 3], f=[1.5, 2.5, missing], b=[true, missing, false], s=[" x ", "NA", "héllo"],
                       d=[Date(2024, 1, 2), missing, Date(1969, 12, 31)],
                       t=[DateTime(2024, 1, 2, 3, 4, 5, 6), missing, DateTime(1970)], n=[missing, missing, missing])
        sch = Ptr{ArrowSchema}(Libc.calloc(1, sizeof(ArrowSchema)))
        arr = Ptr{ArrowArray}(Libc.calloc(1, sizeof(ArrowArray)))
        export_dataframe(df, sch, arr)
        @test isequal(KaosCleaner.import_dataframe(sch, arr), df)          # export -> import round trip
        @test unsafe_load(sch).release == C_NULL && unsafe_load(arr).release == C_NULL  # input released

        export_dataframe(df, sch, arr)
        osch = Ptr{ArrowSchema}(Libc.calloc(1, sizeof(ArrowSchema)))
        oarr = Ptr{ArrowArray}(Libc.calloc(1, sizeof(ArrowArray)))
        @test KaosCleaner.clean_arrow(sch, arr, """{"impute": "zero"}""", osch, oarr) == 0
        cleaned = KaosCleaner.import_dataframe(osch, oarr)  # the importer reads every exported format
        @test cleaned.i == [1, 0, 3] && isequal(cleaned.s, ["x", missing, "héllo"])
        foreach(Libc.free, (osch, oarr))

        export_dataframe(df, sch, arr)  # invalid options: an error, and the input is still released
        @test KaosCleaner.clean_arrow(sch, arr, """{"dorp": 1}""", C_NULL, C_NULL) == 1
        @test unsafe_load(arr).release == C_NULL

        for empty in (DataFrame(i=Int64[], s=String[]), df[1:0, :])  # zero rows keep their column types
            export_dataframe(empty, sch, arr)
            back = KaosCleaner.import_dataframe(sch, arr)
            @test nrow(back) == 0 && names(back) == names(empty)
            @test all(nonmissingtype(eltype(back[!, c])) == nonmissingtype(eltype(empty[!, c])) for c in names(empty))
        end
        foreach(Libc.free, (sch, arr))
    end

    @testset "parsing options" begin
        dir = mktempdir()
        eu = joinpath(dir, "eu.csv")
        write(eu, "id;price;city\n1;1.234,50;Köln\n# a comment\n2;12,75;Bonn\n")
        o = KaosCleaner.parse_options("""{"delimiter": ";", "decimal": ",", "thousands": ".", "comment": "#"}""")
        out = clean_dataset!(load_dataset(eu, o), o)
        @test out.price == [1234.5, 12.75] && out.city == ["Köln", "Bonn"]
        hdr = joinpath(dir, "hdr.tsv")
        write(hdr, "title\nexported 2024\nid\tname\n1\tA\n2\tB\n")
        h = CleanOptions(header=3)
        @test names(clean_dataset!(load_dataset(hdr, h), h)) == ["id", "name"]
        none = CleanOptions(header=0)
        @test names(clean_dataset!(load_dataset(hdr, CleanOptions(header=0, comment="t")), none))[1] == "column1"
        @test_throws ArgumentError KaosCleaner.parse_options("""{"decimal": ",", "delimiter": ","}""")
        @test_throws ArgumentError KaosCleaner.parse_options("""{"delimiter": "ab"}""")
        @test_throws ArgumentError KaosCleaner.parse_options("""{"header": true}""")
    end

    @testset "source rows and raw reading" begin
        dir = mktempdir()
        path = joinpath(dir, "messy.csv")
        write(path, " Customer ID ,Spend\n 1 ,NA\n 1 ,NA\n\n,\n2,\"\$1,250\"\n")
        o = CleanOptions(source_row=true)
        df = clean_dataset!(load_dataset(path, o), o)
        @test names(df) == ["source_row", "customer_id", "spend"]
        @test df.source_row == [1, 4] && df.spend[2] == 1250    # rows 2 (duplicate) and 3 (empty) dropped
        r = CleanOptions(raw=true, source_row=true)
        raw = clean_dataset!(load_dataset(path, r), r)
        @test names(raw) == ["source_row", " Customer ID ", "Spend"]
        @test raw[!, " Customer ID "] == [" 1 ", " 1 ", "", "2"] && raw.Spend == ["NA", "NA", "", "\$1,250"]
        @test raw[df.source_row, "Spend"] == ["NA", "\$1,250"]  # the original cells of the cleaned rows
        eu = CleanOptions(raw=true, delimiter=";", decimal=",", thousands=".")  # number marks do not apply
        write(joinpath(dir, "eu.csv"), "a;b\n1.234,5;x\n")
        @test clean_dataset!(load_dataset(joinpath(dir, "eu.csv"), eu), eu).a == ["1.234,5"]
        k = CleanOptions(raw=true, keep=["Spend"])
        @test names(clean_dataset!(load_dataset(path, k), k)) == ["Spend"]
        # tables: positions in the input; a clash with an existing column is an error
        t = clean_dataset(DataFrame(a=[1, 1, missing, 2]), o)
        @test t.source_row == [1, 4]
        @test_throws ArgumentError clean_dataset(DataFrame(source_row=[1]), o)
        @test KaosCleaner.parse_options("""{"source_row": true, "raw": true}""").raw
        @test_throws ArgumentError KaosCleaner.parse_options("""{"raw": 1}""")
    end

    @testset "sensor data: timestamps, epochs, interpolation" begin
        T = KaosCleaner.Timestamp
        @test KaosCleaner.parse_timestamp("2024-01-31T10:30:00.123456789") ==
              T(Dates.value(DateTime(2024, 1, 31, 10, 30) - DateTime(1970)) * 1_000_000 + 123_456_789)
        @test KaosCleaner.parse_timestamp("2024-01-31 10:30:00,5Z").ns % 1_000_000_000 == 500_000_000
        @test KaosCleaner.parse_timestamp("2024-02-30T10:30:00.1") === nothing   # no such day
        @test KaosCleaner.parse_timestamp("2024-01-31T10:30:00.1234567890") === nothing
        @test string(T(1_500_000_001)) == "1970-01-01T00:00:01.500000001"
        @test T(DateTime(1970, 1, 1, 0, 0, 1)) == T(1_000_000_000)

        dir = mktempdir()
        path = joinpath(dir, "imu.csv")
        write(path, "t,stamp_ns,stamp_s,accel\n" *
                    "2024-01-01T10:00:00.000100,1700000000000000001,1700000000.25,1.0\n" *
                    "2024-01-01T10:00:00.000200,1700000000000000002,1700000000.5,\n" *
                    "2024-01-01 10:00:00.0003,1700000000000000003,1700000000.75,\n" *
                    "2024-01-01T10:00:00.000400,1700000000000000004,1700000001,4.0\n")
        o = CleanOptions(epoch=Dict("stamp_ns" => "ns", "stamp_s" => "s"), impute=Dict("accel" => "interpolate"))
        df = clean_dataset!(load_dataset(path, o), o)
        @test nonmissingtype(eltype(df.t)) == T && df.t[2].ns - df.t[1].ns == 100_000   # microseconds kept
        @test df.stamp_ns[1] == T(1700000000000000001) && df.stamp_ns[4].ns - df.stamp_ns[1].ns == 3
        @test df.stamp_s[1] == T(1_700_000_000_250_000_000)
        @test df.accel == [1.0, 2.0, 3.0, 4.0]
        # exported as Arrow timestamp[ns] and read back exactly
        sch = Ptr{ArrowSchema}(Libc.calloc(1, sizeof(ArrowSchema))); arr = Ptr{ArrowArray}(Libc.calloc(1, sizeof(ArrowArray)))
        export_dataframe(df, sch, arr)
        @test unsafe_string(unsafe_load(unsafe_load(unsafe_load(sch).children, 1)).format) == "tsn:"
        @test isequal(KaosCleaner.import_dataframe(sch, arr), df)
        foreach(Libc.free, (sch, arr))
        # plain timestamps without fractions stay DateTime; interpolation leaves the ends alone
        @test KaosCleaner.infer_timestamp(["2024-01-01 10:00:00"]) === nothing
        @test isequal(KaosCleaner.interpolate_linear([missing, 1, missing, 3, missing]), [missing, 1.0, 2.0, 3.0, missing])
        @test_throws ArgumentError clean_dataset(DataFrame(a=["x"]), CleanOptions(epoch=Dict("a" => "s")))
        @test_throws ArgumentError clean_dataset(DataFrame(a=[1]), CleanOptions(epoch=Dict("b" => "s")))
        @test_throws ArgumentError KaosCleaner.parse_options("""{"epoch": {"a": "minutes"}}""")
        @test_throws ArgumentError clean_dataset(DataFrame(a=["x", missing], b=[1, 2]), CleanOptions(impute=Dict("a" => "interpolate")))
        @test KaosCleaner.epoch_timestamp(UInt64(10)^19, 1) === nothing
        @test KaosCleaner.epoch_timestamp("1.5", 1000) == T(1500) && KaosCleaner.epoch_timestamp(-1.5, 1) == T(-2)
        @test KaosCleaner.epoch_timestamp(1.7e9 + 0.000001, 1_000_000_000).ns % 1_000_000_000 in 750:1250  # Float64 resolves ~240 ns here
    end

    @testset "streaming coercion" begin
        @test KaosCleaner.coerce_value(Int64, 3.0) === 3
        @test KaosCleaner.coerce_value(Int64, 3.5) === nothing
        @test KaosCleaner.coerce_value(Int64, "7") === 7
        @test KaosCleaner.coerce_value(Bool, 1) === true
        @test KaosCleaner.coerce_value(Bool, 2) === nothing
        @test KaosCleaner.coerce_value(DateTime, Date(2024, 1, 2)) == DateTime(2024, 1, 2)
        @test KaosCleaner.coerce_value(Int64, 1e30) === nothing
        out, failures = KaosCleaner.coerce_column(Union{Missing, Float64}[1.0, 2.5, missing], Int64)
        @test isequal(out, [1, missing, missing]) && failures == 1
    end

    @testset "parallel paths match sequential" begin
        # Force the parallel code even for small tables and single-threaded runs
        rng = Random.MersenneTwister(4)
        d = DataFrame(a=rand(rng, 1:40, 5_000), b=rand(rng, ["x", "y", missing], 5_000), c=rand(rng, [1.5, NaN, -0.0, 0.0], 5_000))
        seq = KaosCleaner.duplicate_rows(d; tasks=1)
        @test seq == KaosCleaner.duplicate_rows(d; tasks=5, min_rows=0)
        @test isequal(d[.!seq, :], unique(d))
        # Distinct rows with equal hashes: the batched check must fall back to exact
        c = DataFrame(x=ConstHash.(repeat([1, 2, 1, 3, 2, 2], 10)))
        @test findall(KaosCleaner.duplicate_rows(c; tasks=3, min_rows=0)) == findall(nonunique(c))

        df = DataFrame(i=[1, 2, missing], s=["héllo", missing, ""], f=[1.5, missing, 3.0])
        _, par = export_and_read((s, a) -> (export_dataframe(df, s, a; parallel=true); 0))
        _, seqx = export_and_read((s, a) -> (export_dataframe(df, s, a; parallel=false); 0))
        @test isequal(par, seqx) && isequal(par, df)
    end

    @testset "duplicate_rows" begin
        d = DataFrame(a=[1, 1, missing, missing, 2, 2], b=[NaN, NaN, missing, missing, -0.0, 0.0])
        @test isequal(d[.!KaosCleaner.duplicate_rows(d), :], unique(d))  # same rules as unique!
        # Hundreds of columns must not hit unique!'s minutes-long compile
        wide = DataFrame(["c$i" => [i, i] for i in 1:1000])
        elapsed = @elapsed out = clean_dataset(wide)
        @test elapsed < 30
        @test size(out) == (1, 1000)
    end

    @testset "invalid UTF-8 is replaced" begin
        out = clean_dataset(DataFrame("n\xffme" => ["ok", "b\xfead", " \xff "]))
        @test names(out) == ["n_me"]
        @test out[!, 1] == ["ok", "b�ad", "�"]
        @test all(isvalid, out[!, 1])
        # The exporter guarantees valid utf8 even for uncleaned data
        rc, back = export_and_read((s, a) -> (export_dataframe(DataFrame("x\xff" => ["a\xfeb"]), s, a); 0))
        @test names(back) == ["x�"]
        @test back[!, 1] == ["a�b"]
    end

    @testset "clean_dataset" begin
        df = DataFrame("A B" => [1, 1, missing, 2], "c" => [" x ", " x ", missing, "NA"])
        out = clean_dataset(df)
        @test names(out) == ["a_b", "c"]
        @test nrow(out) == 2                      # duplicate and all-missing rows dropped
        @test eltype(out.a_b) == Int              # narrowed after dropping the empty row
        @test isequal(out.c, ["x", missing])
    end

    @testset "C Data export round trip" begin
        df = DataFrame(i=[1, 2, missing], f=[1.5, missing, 3.0], b=[true, false, missing],
                       d=[Date(2024, 1, 2), missing, Date(1969, 12, 31)],
                       s=["héllo", missing, ""], n=[missing, missing, missing])
        rc, back = export_and_read((s, a) -> (export_dataframe(df, s, a); 0))
        @test rc == 0
        @test names(back) == names(df)
        for name in names(df)
            @test isequal(collect(back[!, name]), collect(df[!, name]))
        end
    end

    @testset "process_dataset" begin
        path = joinpath(mktempdir(), "messy.csv")
        write(path, """
        Name ,Score,When
        alice, 1.5,2024-01-01
        bob,NA,2024-01-02
        bob,NA,2024-01-02
        ,,
        """)
        rc, back = export_and_read() do s, a
            GC.@preserve path KaosCleaner.process_dataset(Base.unsafe_convert(Cstring, path), Ptr{Cvoid}(s), Ptr{Cvoid}(a))
        end
        @test rc == 0
        @test names(back) == ["name", "score", "when"]
        @test isequal(back.score, [1.5, missing])
        @test back.when == [Date(2024, 1, 1), Date(2024, 1, 2)]

        sample = joinpath(@__DIR__, "..", "test_set.csv")
        if isfile(sample)
            rc, back = export_and_read((s, a) -> KaosCleaner.process_dataset(sample, s, a))
            @test rc == 0
            @test nrow(back) > 0
        end
    end

    @testset "errors" begin
        @test KaosCleaner.process_dataset("does_not_exist.csv", C_NULL, C_NULL) == 1
        @test occursin("file not found", unsafe_string(KaosCleaner.kaos_last_error()))
        @test KaosCleaner.process_dataset(Cstring(C_NULL), C_NULL, C_NULL) == 1
    end
end
