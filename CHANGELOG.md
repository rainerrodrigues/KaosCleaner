# Changelog

Written by python-semantic-release from Conventional Commit messages on each
release; see `releaserc.toml`.

<!-- version list -->

## v0.1.3 (2026-11-07)

### Documentation

- Benchmark script and results at 100k, 1M and 10M rows
  ([`1972aa5`](https://github.com/rainerrodrigues/KaosCleaner/commit/1972aa5f31113cb65dbab4d4abdaaa09250464e7))

### Performance Improvements

- Parallel duplicate detection and Arrow export, leaner type inference
  ([`443f37e`](https://github.com/rainerrodrigues/KaosCleaner/commit/443f37e37cc9450b4e034712fc3bc35a9175067f))


## v0.1.2 (2026-11-07)

### Bug Fixes

- Remove an invalid PyPI classifier
  ([`7bac0f5`](https://github.com/rainerrodrigues/KaosCleaner/commit/7bac0f59fae0a9ef4fa23148b5bd61a3f46e19d7))


## v0.1.1 (2026-11-07)

### Bug Fixes

- Strip only real binaries, and never fail the build over it
  ([`50a85d7`](https://github.com/rainerrodrigues/KaosCleaner/commit/50a85d701a2ebe7ea13653c5651133c764276363))

### Performance Improvements

- Strip debug info from the bundled Julia libraries
  ([`ce29d12`](https://github.com/rainerrodrigues/KaosCleaner/commit/ce29d1293454ce9bd7c9b28daca8195f8821afdf))


## v0.1.0 (2026-11-07)

First release. Wheels for Linux x86_64, Windows x86_64 and macOS (Apple
silicon) are attached to the
[GitHub release](https://github.com/rainerrodrigues/KaosCleaner/releases/tag/v0.1.0).

### Features

- Clean CSV files into Polars DataFrames or PyArrow tables through the Arrow
  C Data Interface: missing-value markers, whitespace, invalid UTF-8,
  snake_case names, empty and duplicate rows
- Cleaning options passed from Python: `drop`, `keep`, `missing_values`,
  `rename`, `dedupe`, `drop_empty_rows`, `infer_types`, `datetime_formats`,
  `impute`
- Type inference for text columns: booleans, common date formats, numbers
  with currency signs and thousands separators
- Imputation: mean, median, mode, zero, forward and backward fill
- Out-of-core cleaning with `iter_clean_csv` and `clean_csv_to_parquet`
  (Arrow C Stream Interface)
- Engine log records forwarded to Python's `logging` (`"kaos_cleaner"`)
- Thread-safe initialization (`kaos_init_julia`) and a C API with streaming

### Performance

- Multi-threaded CSV parsing, in-place cleaning and faster Arrow export:
  about 3.5x faster than the first prototype on 1M rows
- Smaller runtime (685 → 601 MB) and wheels (200 → 103 MB)

### Bug fixes

- Calls from several threads no longer deadlock the runtime
- Files with hundreds of columns no longer stall duplicate detection
- A crash while unpacking the runtime no longer leaves a broken copy
- Streaming works for files that fit in a single chunk
- macOS: wheels are tagged for macOS 11+ and the library finds its runtime
  from any host program
