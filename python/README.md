# kaos-cleaner

Fast CSV and tabular data cleaning for Python, powered by a pre-compiled Julia engine. Results
come back through the Arrow C Data Interface as a `pyarrow.Table` or a
`polars.DataFrame`, with no Julia installation needed.

```bash
pip install kaos-cleaner
```

```python
from kaos_cleaner import clean_csv, process_dataset

df = clean_csv("data.csv")            # polars.DataFrame
table = process_dataset("data.csv")   # pyarrow.Table

df = clean_csv("orders.csv", drop=["Internal ID"], datetime_formats=["dd/mm/yyyy"],
               impute={"amount": "median", "region": "mode"})
```

Full documentation: https://rainerrodrigues.github.io/KaosCleaner/

## What the cleaning does

- Treats `""`, `NA`, `N/A`, `NaN`, `null`, `NULL`, `None` (and lowercase
  variants, plus any you add) as missing
- Detects numbers, dates and timestamps, and converts text columns that hold
  booleans (`Yes`/`No`, `T`/`F`), dates in other formats (`13/01/2024`) or
  formatted numbers (`$1,250.00`); ambiguous day/month dates are left alone
- Trims whitespace and replaces invalid UTF-8
- Renames columns to unique `snake_case` (`" Spend (USD)"` → `spend_usd`)
- Drops rows that are entirely empty, and duplicate rows
- Imputes on request: mean, median, mode, zero, forward or backward fill

Every step is an option. Errors (a missing file, an invalid option) are raised
as `RuntimeError` with the engine's message; the engine's notes (rows dropped,
columns converted) go to the `logging` logger `"kaos_cleaner"`.

## Other formats and in-memory data

```python
from kaos_cleaner import clean_file, clean_table

df = clean_file("orders.tsv")                 # also .csv.gz, .parquet, .arrow, .jsonl, .json, .xlsx
df = clean_csv("umsatz.csv", delimiter=";", decimal=",", thousands=".")
df = clean_table(pandas_or_polars_or_arrow)   # returns the same kind
```

## Undo the cleaning

```python
from kaos_cleaner import restore

df = clean_csv("orders.csv", source_row=True)   # remembers each row's position
original = restore(df, "orders.csv")            # those rows exactly as in the file
removed = restore(df, "orders.csv", rows="dropped")
```

## Files larger than memory

```python
from kaos_cleaner import clean_csv_to_parquet, iter_clean_csv

clean_csv_to_parquet("huge.csv", "huge.parquet")    # chunk by chunk
for batch in iter_clean_csv("huge.csv"):            # pyarrow.RecordBatch stream
    ...
```

## Good to know

- **First import** unpacks the bundled Julia runtime (~500 MB) into your user
  cache directory (`~/.cache/kaos_cleaner` on Linux, `~/Library/Caches` on
  macOS, `%LOCALAPPDATA%` on Windows). This takes a few seconds once; later
  imports start in well under a second.
- **Platforms:** wheels are built for Linux x86_64 (glibc 2.17+), Windows
  x86_64 and macOS arm64. There is no source distribution.
- **Threads:** parsing uses all CPU cores (set `KAOSCLEANER_THREADS` to limit); calls are serialized, so it is safe to call from several threads.
- Set `KAOSCLEANER_HOME` to a `kaos_binaries/` directory to use your own build
  of the engine.

## License

MIT. The wheel bundles the Julia runtime and Julia packages under their own
(mostly MIT) licenses; their texts are in `share/licenses/` inside the
unpacked runtime.
