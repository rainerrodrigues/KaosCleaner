# Getting started

## Install

```bash
pip install kaos-cleaner
```

Wheels are published for Linux x86_64 (glibc 2.17 or newer), Windows x86_64
and macOS on Apple silicon, for Python 3.9 and later. Each wheel contains the
compiled engine and its Julia runtime, so nothing else needs installing.

!!! note "First import"
    The first time the engine starts it unpacks its runtime (about 600 MB)
    into your user cache directory, which takes a few seconds. Later starts
    take well under a second. The cache lives in `~/.cache/kaos_cleaner`
    (Linux), `~/Library/Caches/kaos_cleaner` (macOS) or
    `%LOCALAPPDATA%\kaos_cleaner` (Windows).

## Clean a file

```python
from kaos_cleaner import clean_csv

df = clean_csv("data.csv")   # polars.DataFrame
print(df.schema)
```

Prefer PyArrow? `process_dataset` takes the same arguments and returns a
`pyarrow.Table`:

```python
from kaos_cleaner import process_dataset

table = process_dataset("data.csv")
pandas_df = table.to_pandas()   # if you need pandas
```

## Pass options

```python
df = clean_csv(
    "orders.csv",
    drop=["Internal ID"],                 # original or snake_case names
    missing_values=["-", "n.a."],
    datetime_formats=["dd/mm/yyyy"],
    impute={"amount": "median", "region": "mode"},
)
```

All options are described in [Cleaning options](options.md).

## Errors

Problems come back as a Python `RuntimeError` carrying the engine's message:

```python
>>> clean_csv("missing.csv")
RuntimeError: ArgumentError: file not found: missing.csv
>>> clean_csv("data.csv", impute={"name": "mean"})
RuntimeError: ArgumentError: impute: `mean` needs a numeric column, `name` is String
```

## Threads

CSV parsing uses one thread per CPU core. To change that, set
`KAOSCLEANER_THREADS` before the first call:

```bash
KAOSCLEANER_THREADS=4 python my_script.py
```

Calling the cleaner from several Python threads is safe; calls run one at a
time.
