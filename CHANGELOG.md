# Changelog

Written by python-semantic-release from Conventional Commit messages on each
release; see `releaserc.toml`.

<!-- version list -->

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
