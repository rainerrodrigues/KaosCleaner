# Build libkaoscleaner into kaos_binaries/:  julia build.jl
# PackageCompiler lives in its own environment (build/) so it is not bundled
# into the library.
import Pkg
Pkg.activate(joinpath(@__DIR__, "build"))
Pkg.develop(path=@__DIR__)
Pkg.add("PackageCompiler")
Pkg.instantiate()

using PackageCompiler

create_library(@__DIR__, joinpath(@__DIR__, "kaos_binaries");
    lib_name="libkaoscleaner",
    precompile_execution_file=joinpath(@__DIR__, "build", "precompile.jl"),
    header_files=[joinpath(@__DIR__, "include", "kaoscleaner.h")],
    # A single CPU target keeps compile memory low; the multi-target default
    # gets OOM-killed on ~8 GB machines. Use KAOS_CPU_TARGET=generic for a
    # library that must run on other CPUs.
    cpu_target=get(ENV, "KAOS_CPU_TARGET", "native"),
    force=true,
)
