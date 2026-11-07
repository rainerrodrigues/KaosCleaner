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

Releases are automatic. Write commit messages (or squash-merge PR titles) as
[Conventional Commits](https://www.conventionalcommits.org/):

| Message | Effect |
|---|---|
| `fix: ...` | patch release (0.1.0 → 0.1.1) |
| `feat: ...` | minor release (0.1.0 → 0.2.0) |
| `BREAKING CHANGE:` in the body | minor while below 1.0, major after |
| `docs:`, `test:`, `ci:`, `chore:`, ... | no release |

On each push to `main`, `.github/workflows/build_wheel.yml` runs
python-semantic-release (`releaserc.toml`). If a release is due, it bumps the
version in `Project.toml` and `python/kaos_cleaner/__init__.py`, updates
`CHANGELOG.md`, tags `vX.Y.Z`, creates a GitHub release, builds and tests one
wheel per OS from that tag, and publishes them to TestPyPI and then PyPI via
Trusted Publishing. Only wheels are published, never an sdist.

There are no tags yet, so the first release counts from 0.0.0: make it a
`feat:` commit to release 0.1.0 (a `fix:` would give 0.0.1).

## License

MIT, see [LICENSE](LICENSE).
