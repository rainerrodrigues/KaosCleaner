# Recipes

Short answers to common tasks. Every snippet uses only kaos-cleaner and the
libraries it already depends on unless noted.

## Get a pandas DataFrame

```python
from kaos_cleaner import process_dataset

df = process_dataset("data.csv").to_pandas()
```

Use `to_pandas(types_mapper=pd.ArrowDtype)` to keep Arrow types (nullable
integers and booleans) instead of NumPy ones.

## Semicolon, tab or pipe separated files

The delimiter is detected automatically, so `clean_csv("export.tsv")` and
semicolon-separated European exports work as they are. Decimal commas
(`12,5`) are not converted to numbers; those columns stay text.

## European dates

`31/01/2024` is unambiguous and converted automatically. Columns where every
day is 12 or less (`01/02/2024`) could be either convention and stay text
until you say which:

```python
df = clean_csv("orders.csv", datetime_formats=["dd/mm/yyyy", "dd/mm/yyyy HH:MM"])
```

## Keep everything as text

To load a file without any type conversion of text columns (numbers are still
parsed as numbers):

```python
df = clean_csv("raw.csv", infer_types=False)
```

Pass `rename=False` as well to keep the original column names, and
`dedupe=False, drop_empty_rows=False` to keep every row.

## Choose columns

```python
df = clean_csv("wide.csv", keep=["Order ID", "amount", "region"])
df = clean_csv("wide.csv", drop=["internal_notes", "Debug Flag"])
```

Names may be given as they appear in the file or in their snake_case form.
A name that matches no column raises an error rather than being ignored.

## Fill gaps per column

```python
df = clean_csv(
    "sensors.csv",
    impute={"temperature": "ffill", "humidity": "median", "status": "mode"},
)
```

## Clean a folder of files into one Parquet file

```python
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq
from kaos_cleaner import process_dataset

files = sorted(Path("exports").glob("*.csv"))
first = process_dataset(files[0])
with pq.ParquetWriter("all.parquet", first.schema) as writer:
    writer.write_table(first)
    for path in files[1:]:
        writer.write_table(process_dataset(path).cast(first.schema))
```

`cast` makes later files match the first file's column types; it raises if a
file has different columns. Memory is released after each file.

## Stream a huge file into DuckDB

With [DuckDB](https://duckdb.org) installed (`pip install duckdb`):

```python
import duckdb
from kaos_cleaner import iter_clean_csv

reader = iter_clean_csv("events.csv")
duckdb.sql("CREATE TABLE events AS SELECT * FROM reader")
```

## Write the engine's log to a file

```python
import logging

handler = logging.FileHandler("cleaning.log")
handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
logging.getLogger("kaos_cleaner").addHandler(handler)
logging.getLogger("kaos_cleaner").setLevel(logging.INFO)
```

## Fail on suspicious files

Parse warnings (ragged rows) arrive as `WARNING` records. To turn them into
errors in a pipeline:

```python
import logging

class FailOnWarning(logging.Handler):
    def emit(self, record):
        if record.levelno >= logging.WARNING:
            raise RuntimeError(f"suspicious input: {record.getMessage()}")

logging.getLogger("kaos_cleaner").addHandler(FailOnWarning())
```

## Use fewer CPU cores

```python
import os
os.environ["KAOSCLEANER_THREADS"] = "2"   # before the first call

from kaos_cleaner import clean_csv
```
