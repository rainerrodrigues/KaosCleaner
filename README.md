# KaosCleaner

A CSV cleaning engine written in Julia, compiled with PackageCompiler into a
C shared library (`libkaoscleaner`), and used from Python through the Arrow C
Data Interface. The Python package is published as `kaos-cleaner`; see
[python/README.md](python/README.md) for how to use it.

## Layout

| Path | What it is |
|---|---|
| `src/` | Julia package: loading/cleaning (`cleaning.jl`), Arrow C Data export (`cdata.jl`), C entry points |
| `test/` | Julia test suite |
| `build.jl`, `build/` | Compiles `kaos_binaries/` with PackageCompiler (own environment, precompile trace) |
| `include/kaoscleaner.h` | C header for `process_dataset` / `kaos_last_error` |
| `python/` | The `kaos-cleaner` Python package |
| `scripts/build_wheel.py` | Packs `kaos_binaries/` into a platform wheel in `dist/` |
| `scripts/memory_test.py` | Repeated-call memory check |
| `.github/workflows/build_wheel.yml` | Builds and smoke-tests wheels on Linux, Windows and macOS |

## Developing

```bash
julia --project=. -e 'using Pkg; Pkg.test()'   # Julia tests
julia build.jl                                  # compile kaos_binaries/ (~15 min, ~8 GB RAM)
python bridge_test.py dummy.csv                 # call the compiled library from Python
python scripts/build_wheel.py                   # wheel in dist/ (--gzip for a quick local one)
```

`build.jl` targets the local CPU; set `KAOS_CPU_TARGET=generic` for binaries
that must run on other machines (CI does this).

## Releasing

Push a `vX.Y.Z` tag. The workflow builds one wheel per OS and collects them
in the `kaos-cleaner-wheels` artifact. Upload those wheels (not an sdist) with:

```bash
python -m twine upload dist/*.whl
```

## License

MIT, see [LICENSE](LICENSE).
