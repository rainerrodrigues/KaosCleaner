# Development

## Requirements

- [Julia](https://julialang.org/downloads/) 1.12 (the version in `Manifest.toml`)
- Python 3.9+
- A C compiler (PackageCompiler uses it to link the library; on Windows it
  downloads one itself)
- About 8 GB of RAM and 15 minutes for a full engine build

## Layout

| Path | What |
|---|---|
| `src/KaosCleaner.jl` | Module and C entry points |
| `src/options.jl` | Cleaning options and their JSON parsing |
| `src/cleaning.jl` | Loading, text cleaning, renaming, selection, deduplication |
| `src/inference.jl` | Type inference and imputation |
| `src/logging.jl` | Buffered logging for the host |
| `src/cdata.jl` | Arrow C Data Interface export |
| `src/streaming.jl` | Chunked processing and the Arrow C Stream Interface |
| `build.jl`, `build/` | Engine build: PackageCompiler environment, precompile trace, thread-safe init (`kaos_init.c`) |
| `include/kaoscleaner.h` | C API |
| `python/kaos_cleaner/` | Python package: `__init__.py` (public API), `_runtime.py` (finding, unpacking and loading the engine) |
| `scripts/build_wheel.py` | Packs a build into a platform wheel |
| `scripts/benchmark.py` | Times pandas, Polars and kaos-cleaner on generated data |
| `test/`, `python/tests/` | Julia and Python tests |
| `docs/`, `mkdocs.yml` | This site |

## Test the engine

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

The Julia tests exercise everything, including the C entry points and the
stream callbacks, without compiling the library.

## Build the engine

```bash
julia build.jl
```

This writes `kaos_binaries/`. It targets your CPU; set
`KAOS_CPU_TARGET=generic` for a library that must run on other machines (CI
does). The build runs `build/precompile.jl` so the code paths it exercises
are compiled in; add to it when you add a feature, or the first call that
uses the feature will be slow.

## Test from Python

```bash
python -m venv venv && . venv/bin/activate
pip install pyarrow polars cffi pytest pytest-benchmark pandas
pytest python/tests -v
```

Run from a checkout, the tests use `python/kaos_cleaner` with
`kaos_binaries/`. Crash- and hang-prone tests run in child processes with
timeouts, so a segfault fails one test instead of the run.

## Build a wheel

```bash
pip install build
python scripts/build_wheel.py          # xz-compressed, a few minutes
python scripts/build_wheel.py --gzip   # larger, seconds; for local testing
```

The wheel lands in `dist/`. On Linux it is tagged manylinux with the oldest
glibc the runtime needs.

## Docs

```bash
pip install -r docs/requirements.txt
mkdocs serve
```

The API reference comes from the docstrings in `python/kaos_cleaner`.

## Code quality checks

```bash
pip install pre-commit && pre-commit install
```

pre-commit then runs ruff (lint and format) and a few file checks on every
commit. CI runs the same ruff checks plus mypy on every pull request:

```bash
ruff check python/ scripts/ && ruff format --check python/ scripts/
```
```bash
cd python && mypy
```

On the Julia side, the test suite includes [Aqua.jl](https://github.com/JuliaTesting/Aqua.jl)
(compat bounds, unused dependencies, piracy, ambiguities). For deeper checks,
[JET.jl](https://github.com/aviatesk/JET.jl) finds type instabilities and
calls that cannot succeed:

```julia
using JET, KaosCleaner
report_package(KaosCleaner; target_modules=(KaosCleaner,))
```

## Commit messages

Releases are generated from commit messages, so use
[Conventional Commits](https://www.conventionalcommits.org/):

| Message | Release |
|---|---|
| `fix: ...`, `perf: ...` | patch (0.1.0 → 0.1.1) |
| `feat: ...` | minor (0.1.0 → 0.2.0) |
| `BREAKING CHANGE:` in the body | minor while below 1.0, major after |
| `docs:`, `test:`, `ci:`, `chore:`, `refactor:`, `style:` | none |

For a pull request that will be squash-merged, the PR title is the commit
message that counts.

## Continuous integration

| Workflow | When | What |
|---|---|---|
| `ci.yml` | Every pull request | Julia tests, Linux engine build, Python tests, speed gate against pandas |
| `docs.yml` | PRs and `main` touching docs or the Python package | Strict docs build; deploy to GitHub Pages from `main` |
| `build_wheel.yml` | Every push to `main`, or manually | Release (see below); manual runs on a branch build and test all wheels without releasing |

To test the Windows and macOS wheels of a branch before merging:

```bash
gh workflow run build_wheel.yml --ref my-branch
```

## Releasing

Merging to `main` is releasing. `build_wheel.yml`:

1. runs python-semantic-release (`releaserc.toml`), which reads the commits
   since the last tag and, if a release is due, bumps the version in
   `Project.toml` and `python/kaos_cleaner/__init__.py`, updates
   `CHANGELOG.md`, commits, tags `vX.Y.Z` and creates a GitHub release;
2. builds the engine and a wheel on Linux, Windows and macOS from that tag,
   and tests each installed wheel;
3. attaches the wheels to the GitHub release;
4. if the repository variable `PUBLISH_TO_PYPI` is `true`, publishes to
   TestPyPI and then, after approval in the `pypi` environment, to PyPI.

Publishing uses Trusted Publishing: each index needs a publisher for this
repository, workflow `build_wheel.yml` and environment `testpypi` or `pypi`.
No tokens are stored.

PyPI enforces two things only at upload time, so both are checked earlier:

- **File size**: each wheel must stay under PyPI's 100 MiB per-file limit.
  `build.jl` strips debug information from the bundled Julia libraries to
  get there (Linux ~81 MiB, Windows ~74 MiB, macOS ~68 MiB).
- **Classifiers**: every classifier in `python/pyproject.toml` must be on
  PyPI's official list; `python/tests/test_metadata.py` checks this in CI.

## Publishing to Julia's General registry

The Julia package (`KaosCleaner`) can be registered so that Julia users get
it with `Pkg.add("KaosCleaner")`. `Project.toml` already has the required
compat bounds for every dependency and for Julia itself, which Aqua.jl checks.

1. Install the [JuliaRegistrator](https://github.com/JuliaRegistries/Registrator.jl)
   GitHub app on this repository.
2. On the commit to register (a release commit on `main`), comment
   `@JuliaRegistrator register`. Registrator opens a pull request on
   [General](https://github.com/JuliaRegistries/General).
3. New packages wait three days before the pull request is merged
   automatically, provided the automated checks pass.
4. Every later release needs the same comment on its release commit;
   versions come from `Project.toml`, which semantic-release keeps in step
   with the Python package.
