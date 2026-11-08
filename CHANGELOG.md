# Changelog

Written by python-semantic-release from Conventional Commit messages on each
release; see `releaserc.toml`.

<!-- version list -->

## v0.4.0 (2026-11-08)

### Documentation

- Pipeline diagram on the How it works page
  ([`0af1d46`](https://github.com/rainerrodrigues/KaosCleaner/commit/0af1d4624589bd2ee68f2ecbfc707f266556bbd3))

### Features

- Undo the cleaning with source_row and restore
  ([`e8ef3aa`](https://github.com/rainerrodrigues/KaosCleaner/commit/e8ef3aa6cb2638694d4feb21976809949e2434e1))


## v0.3.0 (2026-11-08)

### Features

- Clean_file for Parquet, Arrow, JSON and Excel, and clean_table
  ([`562b725`](https://github.com/rainerrodrigues/KaosCleaner/commit/562b725152b471b4865cb81f588eaeba87e9ddab))

- Parsing options and in-memory cleaning in the engine
  ([`9d4f35a`](https://github.com/rainerrodrigues/KaosCleaner/commit/9d4f35a0d710b5397105f6882a6970e6656354f3))


## v0.2.0 (2026-11-08)

### Documentation

- Julia usage page, code-quality checks and registry steps
  ([`977b359`](https://github.com/rainerrodrigues/KaosCleaner/commit/977b359279767d60d7947079ba945d886e433345))

### Features

- C SDK downloads with a pkg-config file on every release
  ([`617efcd`](https://github.com/rainerrodrigues/KaosCleaner/commit/617efcd8d63abd3fb3a163b610832964c7041ce0))

### Refactoring

- Read nullable stream fields into locals (JET-clean)
  ([`cef68c4`](https://github.com/rainerrodrigues/KaosCleaner/commit/cef68c4e89558108587b25f94496789a7231b356))


## v0.1.4 (2026-11-07)

### Bug Fixes

- Exact misfit counts when streaming, no overflow abort on big numbers
  ([`0946d7c`](https://github.com/rainerrodrigues/KaosCleaner/commit/0946d7ce50d9ca3e659c80e7ac626c1cb49d8b8b))

- Release unimported results, RuntimeError for stream errors, prune old runtimes
  ([`824e16f`](https://github.com/rainerrodrigues/KaosCleaner/commit/824e16f4e16d42666f33d388149321cdb5a3fbf1))

### Documentation

- PyPI install, current benchmarks, C API threading note, v0.1.0 notes
  ([`7c2eacd`](https://github.com/rainerrodrigues/KaosCleaner/commit/7c2eacd92aa4c44ede45dc67d99cb09bc5634f51))


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
