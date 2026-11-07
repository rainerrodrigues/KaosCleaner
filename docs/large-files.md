# Large files

`clean_csv` loads the whole file into memory. For files larger than your RAM,
stream them instead: the engine parses and cleans one chunk at a time, so
memory use follows the chunk size, not the file size.

## Straight to Parquet

```python
from kaos_cleaner import clean_csv_to_parquet

rows = clean_csv_to_parquet("events_2024.csv", "events_2024.parquet", impute="ffill")
print(f"wrote {rows:,} rows")
```

Then query the result lazily, for example with Polars:

```python
import polars as pl

pl.scan_parquet("events_2024.parquet").group_by("country").len().collect()
```

## As a stream of batches

`iter_clean_csv` returns a `pyarrow.RecordBatchReader`, which most Arrow tools
accept directly:

```python
from kaos_cleaner import iter_clean_csv

reader = iter_clean_csv("events_2024.csv", chunk_size=128 * 2**20)
for batch in reader:            # pyarrow.RecordBatch
    process(batch)
```

```python
import duckdb
duckdb.sql("SELECT country, count(*) FROM reader GROUP BY 1")
```

`chunk_size` is the approximate number of bytes of the file parsed per batch
(default 256 MB). Peak memory is a few times the chunk size.

## What changes when streaming

Streaming sees the file one piece at a time, which changes three things:

**Types are decided from the start of the file.** Column types and
conversions come from the first 20,000 rows. If a later value does not fit,
for example `"n/k"` in a numeric column or `"maybe"` in a yes/no column, it
becomes null and a warning is logged:

```text
WARNING:kaos_cleaner:3 values in `flag` did not fit Bool and became missing
```

If your file has a long, uniform start and messier data later, check the
logs (see [Logging](logging.md)).

**Duplicates are found across the whole file** by remembering a 16-byte
fingerprint of every distinct row. For billions of rows that adds up; pass
`dedupe=False` if memory matters more.

**Only look-ahead-free imputation**: `"zero"` and `"ffill"` work, with
forward fill carrying over between batches. `"mean"`, `"median"`, `"mode"`
and `"bfill"` need the whole file and raise an error; compute them afterwards
on the Parquet output instead.
