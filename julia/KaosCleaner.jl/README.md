# KaosCleaner.jl

The Julia engine of [kaos-cleaner](https://github.com/rainerrodrigues/KaosCleaner):
fast, forgiving cleaning of messy tabular files (CSV and more) into clean,
typed, deduplicated DataFrames.

kaos-cleaner is mainly a Python package ([`kaos-cleaner` on PyPI](https://pypi.org/project/kaos-cleaner/))
that calls this engine compiled into a native library. This directory is the
same engine as an ordinary Julia package, so Julia users get the same cleaning
directly, with no compiled library, and results as DataFrames. It also
provides the outlier statistics (z-score, IQR, MAD, Hampel) used for sensor
and robot logs.

## Installation

```julia
using Pkg
Pkg.add("KaosCleaner")
```

## Usage

```julia
using KaosCleaner

df = clean_dataset!(load_dataset("orders.csv"))

opts = CleanOptions(drop = ["Internal ID"], datetime_formats = ["dd/mm/yyyy"],
                    impute = Dict("amount" => "median"))
df = clean_dataset!(load_dataset("orders.csv"), opts)
```

## Documentation

- [Using from Julia](https://rainerrodrigues.github.io/KaosCleaner/julia/)
- [Cleaning options](https://rainerrodrigues.github.io/KaosCleaner/options/)
- [Sensor and robot data](https://rainerrodrigues.github.io/KaosCleaner/sensor-data/)
- [Full documentation](https://rainerrodrigues.github.io/KaosCleaner/)

The rest of the repository holds the Python package, the C API and the build
of the native library.

## License

MIT, see [LICENSE](LICENSE).
