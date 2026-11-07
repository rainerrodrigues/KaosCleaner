using KaosCleaner, DataFrames, Dates, Test
using KaosCleaner: ArrowSchema, ArrowArray

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
    @testset "normalize_name" begin
        @test KaosCleaner.normalize_name(" Bill Length (mm)") == "bill_length_mm"
        @test KaosCleaner.normalize_name("***") == "column"
        @test KaosCleaner.normalize_name("caf\xe9") == "caf"  # U+FFFD is not a letter: dropped
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
