# KaosCleaner

[![CI](https://github.com/rainerrodrigues/KaosCleaner/actions/workflows/ci.yml/badge.svg)](https://github.com/rainerrodrigues/KaosCleaner/actions/workflows/ci.yml)
[![Docs](https://github.com/rainerrodrigues/KaosCleaner/actions/workflows/docs.yml/badge.svg)](https://rainerrodrigues.github.io/KaosCleaner/)
[![Release](https://img.shields.io/github/v/release/rainerrodrigues/KaosCleaner?include_prereleases&sort=semver)](https://github.com/rainerrodrigues/KaosCleaner/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Fast, forgiving CSV cleaning for Python, powered by a compiled Julia engine.**
Point it at a messy file and get back a clean, typed, deduplicated
[Polars](https://pola.rs) DataFrame or [PyArrow](https://arrow.apache.org/docs/python/)
table. No Julia installation needed.

```python
from kaos_cleaner import clean_csv

df = clean_csv("customers.csv", drop=["Internal ID"], impute={"spend_usd": "median"})
```

For example, given this file:

```text
 Customer ID, Full Name ,Signup Date,Spend (USD),Active,Paid
1,  Alice Smith ,13/01/2024,"$1,200.50",true,Yes
2,Bob Jones,02/02/2024,NA,false,no
2,Bob Jones,02/02/2024,NA,false,no
,,,,,
3,N/A,28/02/2024,null,,Y
```

`clean_csv("customers.csv")` returns:

```text
shape: (3, 6)
┌─────────────┬─────────────┬─────────────┬───────────┬────────┬───────┐
│ customer_id ┆ full_name   ┆ signup_date ┆ spend_usd ┆ active ┆ paid  │
│ ---         ┆ ---         ┆ ---         ┆ ---       ┆ ---    ┆ ---   │
│ i64         ┆ str         ┆ date        ┆ f64       ┆ bool   ┆ bool  │
╞═════════════╪═════════════╪═════════════╪═══════════╪════════╪═══════╡
│ 1           ┆ Alice Smith ┆ 2024-01-13  ┆ 1200.5    ┆ true   ┆ true  │
│ 2           ┆ Bob Jones   ┆ 2024-02-02  ┆ null      ┆ false  ┆ false │
│ 3           ┆ null        ┆ 2024-02-28  ┆ null      ┆ null   ┆ true  │
└─────────────┴─────────────┴─────────────┴───────────┴────────┴───────┘
```

Names were tidied, `N/A`/`NA`/`null` became nulls, the dates, the dollar
amount and the yes/no column were typed, and the duplicate and empty rows
were dropped.

## Features

- **Missing values**: `""`, `NA`, `N/A`, `NaN`, `null`, `None` and friends (plus
  your own) become real nulls.
- **Types**: numbers, dates and timestamps are detected; text columns that are
  really booleans (`Yes`/`No`, `T`/`F`), dates in other formats (`13/01/2024`,
  `12 Jan 2024`) or formatted numbers (`$1,250.00`) are converted. Ambiguous
  day/month dates are left alone instead of guessed.
- **Tidy names**: `" Spend (USD)"` → `spend_usd`, made unique.
- **Whitespace and encoding**: cells are trimmed; invalid UTF-8 becomes `�`.
- **Empty and duplicate rows** are dropped.
- **Imputation** on request: mean, median, mode, zero, forward or backward fill.
- **Larger-than-memory files** stream through in chunks, straight to Parquet.
- **Zero-copy handoff** through the Arrow C Data Interface, multi-threaded
  parsing, safe to call from many Python threads.
- **Everything is optional** and every step reports what it did through
  Python's `logging`.

## Install

Wheels for Linux x86_64, Windows x86_64 and macOS (Apple silicon), Python 3.9+,
are attached to each [GitHub release](https://github.com/rainerrodrigues/KaosCleaner/releases).
Download the one for your platform and install it:

```bash
pip install kaos_cleaner-0.1.0-py3-none-manylinux_2_17_x86_64.manylinux2014_x86_64.whl
```

Once the package is on PyPI this becomes `pip install kaos-cleaner`.

The first call unpacks the bundled Julia runtime (about 600 MB) into your user
cache directory, which takes a few seconds once.

## Usage

```python
from kaos_cleaner import clean_csv, process_dataset, clean_csv_to_parquet, iter_clean_csv

df = clean_csv("data.csv")                       # polars.DataFrame
table = process_dataset("data.csv")              # pyarrow.Table

df = clean_csv(
    "orders.csv",
    keep=["order_id", "date", "amount", "region"],
    missing_values=["-", "n.a."],
    datetime_formats=["dd/mm/yyyy"],
    impute={"amount": "median", "region": "mode"},
)

rows = clean_csv_to_parquet("huge.csv", "huge.parquet")   # chunk by chunk
for batch in iter_clean_csv("huge.csv"):                  # pyarrow.RecordBatch
    ...
```

See the **[documentation](https://rainerrodrigues.github.io/KaosCleaner/)** for
all options, the type-inference rules, large files, logging, recipes,
troubleshooting and the C API.

## Performance

Same cleaning in three engines, median of 5 runs on a 6-core laptop
([details and caveats](https://rainerrodrigues.github.io/KaosCleaner/benchmarks/)):

| Rows | pandas | Polars | kaos-cleaner |
|---:|---:|---:|---:|
| 100,000 | 61 ms | 63 ms | **43 ms** |
| 1,000,000 | **421 ms** | 431 ms | 478 ms |

kaos-cleaner also infers booleans, dates and formatted numbers, which the
pandas and Polars versions do not.

## How it works

The cleaning engine is a Julia package ([CSV.jl](https://github.com/JuliaData/CSV.jl),
[DataFrames.jl](https://dataframes.juliadata.org)) compiled ahead of time with
[PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl) into a
native library with a C interface (`include/kaoscleaner.h`). Python calls it
through `ctypes`; the engine writes the cleaned columns into Arrow buffers and
PyArrow wraps them without copying. More in
[How it works](https://rainerrodrigues.github.io/KaosCleaner/how-it-works/).

## Repository layout

| Path | What it is |
|---|---|
| `src/` | Julia engine: options, cleaning, type inference, logging, Arrow export, streaming |
| `test/` | Julia tests |
| `python/kaos_cleaner/` | The Python package |
| `python/tests/` | Python bridge tests and benchmarks |
| `build.jl`, `build/` | Compile the engine with PackageCompiler |
| `include/kaoscleaner.h` | C API |
| `scripts/` | Wheel builder and memory check |
| `docs/`, `mkdocs.yml` | Documentation site |
| `.github/workflows/` | CI, releases, docs |

## Contributing

Build, test and release instructions are in the
[development guide](https://rainerrodrigues.github.io/KaosCleaner/development/).
Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/),
because releases are generated from them.

## License

MIT, see [LICENSE](LICENSE). Wheels bundle the Julia runtime and Julia packages
under their own (mostly MIT) licenses, included in the wheel.
