# KaosCleaner.jl

Fast, forgiving cleaning of messy tabular data (CSV, TSV, Parquet, JSON, Excel)
into clean, typed DataFrames:

- missing-value markers (`NA`, `N/A`, `null`, …) become real `missing`s;
- numbers, dates and booleans are inferred from text;
- column names are tidied;
- whitespace is trimmed, and empty and duplicate rows are dropped;
- imputation is optional;
- for sensor and robot logs, there is outlier removal, time-aware interpolation
  and resampling onto a fixed grid.

This folder is the Julia package at the heart of the
[KaosCleaner](https://github.com/rainerrodrigues/KaosCleaner) project. The same
code is compiled into a native library that powers the
[`kaos-cleaner`](https://pypi.org/project/kaos-cleaner/) Python package (in
`python/` at the repository root) and a C API. From Julia you use it directly,
with no compiled library involved.

## Installation

```julia
using Pkg
Pkg.add("KaosCleaner")
```

Requires Julia 1.12 or newer.

## Usage

```julia
using KaosCleaner

df = clean_dataset!(load_dataset("orders.csv"))

opts = CleanOptions(
    drop = ["Internal ID"],
    missing_values = ["-", "n.a."],
    impute = Dict("amount" => "median", "region" => "mode"),
)
df = clean_dataset!(load_dataset("orders.csv"; missing_values = opts.missing_values), opts)
```

Every step reports what it did through Julia's standard logging
(`[ Info: Dropped 2 duplicate rows`).

## Documentation

The full documentation covers every cleaning option, the type-inference rules,
large files, sensor data and the C API:
<https://rainerrodrigues.github.io/KaosCleaner/>. For Julia specifically, see
[Using from Julia](https://rainerrodrigues.github.io/KaosCleaner/julia/).

## License

MIT, see [LICENSE](LICENSE).
