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

# The library parses with several threads when the host starts it that way
# (kaos_init_julia with --threads); run the precompile trace threaded too so
# that code path is compiled in rather than JIT-compiled on first use.
ENV["JULIA_NUM_THREADS"] = "4"

create_library(@__DIR__, OUT;
    lib_name="libkaoscleaner",
    precompile_execution_file=joinpath(@__DIR__, "build", "precompile.jl"),
    header_files=[joinpath(@__DIR__, "include", "kaoscleaner.h")],
    # Adds kaos_init_julia, which makes the library safe to call from threads
    julia_init_c_file=[PackageCompiler.default_julia_init(), joinpath(@__DIR__, "build", "kaos_init.c")],
    julia_init_h_file=[PackageCompiler.default_julia_init_header()],
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

# Ship the licenses of everything compiled or bundled into the library: Julia
# (whose LICENSE.md also covers the libraries it bundles) and every package.
licenses = joinpath(OUT, "share", "licenses")
rm(licenses; recursive=true, force=true)
mkpath(joinpath(licenses, "julia"))
cp(joinpath(Sys.BINDIR, "..", "LICENSE.md"), joinpath(licenses, "julia", "LICENSE.md"); force=true)
# Walk KaosCleaner's dependency tree; the build environment also holds
# PackageCompiler, which is not part of the library.
deps = Pkg.dependencies()
bundled, todo = Set{Base.UUID}(), [only(u for (u, d) in deps if d.name == "KaosCleaner")]
while !isempty(todo)
    u = pop!(todo)
    u in bundled || (push!(bundled, u); append!(todo, values(deps[u].dependencies)))
end
for u in bundled
    dep = deps[u]
    (dep.source === nothing || !isdir(dep.source)) && continue
    for file in readdir(dep.source)
        if occursin(r"^(licen[cs]e|copying)"i, file) && isfile(joinpath(dep.source, file))
            mkpath(joinpath(licenses, dep.name))
            cp(joinpath(dep.source, file), joinpath(licenses, dep.name, file); force=true)
        end
    end
end

# Drop DWARF debug info. Exported and function symbols stay, so crash traces
# keep function names but lose source line numbers.
if !Sys.iswindows() && Sys.which("strip") !== nothing
    lib = joinpath(OUT, "lib", Sys.isapple() ? "libkaoscleaner.dylib" : "libkaoscleaner.so")
    run(Sys.isapple() ? `strip -S $lib` : `strip --strip-debug $lib`)
end
