# Build libkaoscleaner into kaos_binaries/:  julia build.jl
# PackageCompiler lives in its own environment (build/) so it is not bundled
# into the library.
import Pkg
Pkg.activate(joinpath(@__DIR__, "build"))
Pkg.develop(path=@__DIR__)
Pkg.add("PackageCompiler")
Pkg.instantiate()

using PackageCompiler, Artifacts

const OUT = joinpath(@__DIR__, "kaos_binaries")

create_library(@__DIR__, OUT;
    lib_name="libkaoscleaner",
    precompile_execution_file=joinpath(@__DIR__, "build", "precompile.jl"),
    header_files=[joinpath(@__DIR__, "include", "kaoscleaner.h")],
    # A single CPU target keeps compile memory low; the multi-target default
    # gets OOM-killed on ~8 GB machines. Use KAOS_CPU_TARGET=generic for a
    # library that must run on other CPUs.
    cpu_target=get(ENV, "KAOS_CPU_TARGET", "native"),
    # Leave out stdlibs our dependency tree never loads (Pkg, REPL, ...)
    filter_stdlibs=true,
    force=true,
)

# CSV.jl declares its test data as a non-lazy artifact, so it gets bundled,
# but nothing uses it at runtime.
csv = only(d for d in values(Pkg.dependencies()) if d.name == "CSV")
for toml in (joinpath(csv.source, "Artifacts.toml"), joinpath(csv.source, "test", "Artifacts.toml"))
    isfile(toml) || continue
    testfiles = artifact_hash("testfiles", toml)
    testfiles === nothing || rm(joinpath(OUT, "share", "julia", "artifacts", string(testfiles));
                                recursive=true, force=true)
end

# Drop DWARF debug info. Exported and function symbols stay, so crash traces
# keep function names but lose source line numbers.
if !Sys.iswindows() && Sys.which("strip") !== nothing
    lib = joinpath(OUT, "lib", Sys.isapple() ? "libkaoscleaner.dylib" : "libkaoscleaner.so")
    run(Sys.isapple() ? `strip -S $lib` : `strip --strip-debug $lib`)
end
