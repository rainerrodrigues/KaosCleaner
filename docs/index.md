# kaos-cleaner

Fast, forgiving CSV cleaning for Python. Point it at a messy file and get a
clean [Polars](https://pola.rs) DataFrame or [PyArrow](https://arrow.apache.org/docs/python/)
table back, typed and deduplicated, with no Julia installation needed.

```python
from kaos_cleaner import clean_csv

df = clean_csv("exports/customers.csv", drop=["internal_id"], impute={"spend_usd": "median"})
```

## What it does for you

- **Missing values**: `""`, `NA`, `N/A`, `NaN`, `null`, `None` (and lowercase
  forms, plus any you add) become real nulls.
- **Types**: numbers, dates and timestamps are detected while parsing; text
  columns that are really booleans (`Yes`/`No`, `T`/`F`), dates in other
  formats (`13/01/2024`, `12 Jan 2024`) or formatted numbers (`$1,250.00`) are
  converted.
- **Tidy names**: `" Spend (USD)"` becomes `spend_usd`, and clashes get suffixes.
- **Whitespace and encoding**: cells are trimmed; invalid UTF-8 bytes become
  `�` instead of breaking downstream tools.
- **Empty and duplicate rows** are dropped.
- **Imputation** on request: mean, median, mode, zero, forward or backward fill.
- **Files bigger than memory** stream through in chunks, straight to Parquet if
  you like.

Every step can be switched off; see [Cleaning options](options.md).

## Why a Julia engine?

The cleaning runs in [Julia](https://julialang.org), compiled ahead of time
into a native library that ships inside the wheel. Results cross into Python
through the [Arrow C Data Interface](https://arrow.apache.org/docs/format/CDataInterface.html),
so the cleaned columns are handed over, not serialised. See
[How it works](how-it-works.md) and the [benchmarks](benchmarks.md).
