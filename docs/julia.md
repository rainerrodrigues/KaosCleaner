# Using from Julia

kaos-cleaner's engine is an ordinary Julia package, `KaosCleaner`, which you
can use directly from Julia: same cleaning, no compiled library, results as
DataFrames.

```julia
using Pkg
Pkg.add(url="https://github.com/rainerrodrigues/KaosCleaner")
```

Once the package is in Julia's General registry, this becomes
`Pkg.add("KaosCleaner")`.

## Clean a file

```julia
using KaosCleaner

df = clean_dataset!(load_dataset("orders.csv"))
```

`load_dataset` reads the file with the missing-value markers applied, and
`clean_dataset!` cleans it in place. `clean_dataset(df)` (without `!`) leaves
its input alone and returns a cleaned copy, for DataFrames that come from
elsewhere.

## Options

Options are fields of `CleanOptions`, with the same names and meaning as the
Python keyword arguments (see [Cleaning options](options.md)):

```julia
opts = CleanOptions(
    drop = ["Internal ID"],
    missing_values = ["-", "n.a."],
    datetime_formats = ["dd/mm/yyyy"],
    impute = Dict("amount" => "median", "region" => "mode"),
)
df = clean_dataset!(load_dataset("orders.csv"; missing_values = opts.missing_values), opts)
```

## Log messages

The engine reports what it did with Julia's standard logging (`@info`), so
messages appear in the REPL as usual:

```text
[ Info: Converted column `paid` from text to Bool
[ Info: Dropped 2 duplicate rows
```

## Exporting to Arrow

`export_dataframe(df, schema_ptr, array_ptr)` writes a DataFrame into
caller-allocated Arrow C Data Interface structs. It is what the compiled
library uses to hand results to Python, and it is only needed when passing
data to non-Julia code in the same process; see the [C API](c-api.md).
