# 6. Files larger than memory

`clean_csv` reads the whole file into memory. For files bigger than your
RAM, or to keep memory flat on a small machine such as a robot's computer,
clean in chunks.

```python
import random
from pathlib import Path

import polars as pl
from kaos_cleaner import clean_csv_to_parquet, iter_clean_csv

random.seed(1)
with Path("events.csv").open("w") as f:
    f.write("Event ID,User,Value,When\n")
    for i in range(1_000_000):
        value = "NA" if i % 97 == 0 else f"{random.random() * 100:.2f}"
        f.write(f"{i},user_{i % 5000},{value},2024-05-{i % 28 + 1:02d}T12:00:00\n")
```

## Straight to Parquet

```python
rows = clean_csv_to_parquet("events.csv", "events.parquet", chunk_size=16 * 2**20)
print(rows, "rows written")
print(pl.scan_parquet("events.parquet").select(pl.len(), pl.col("value").mean()).collect())
```

```text
1000000 rows written
┌─────────┬───────────┐
│ len     ┆ value     │
│ ---     ┆ ---       │
│ u32     ┆ f64       │
╞═════════╪═══════════╡
│ 1000000 ┆ 50.016788 │
└─────────┴───────────┘
```

Memory follows `chunk_size` (16 MB of CSV per batch here; the default is
256 MB), not the file size.

## Batch by batch

To process each batch yourself, iterate:

```python
total = 0.0
for batch in iter_clean_csv("events.csv", chunk_size=16 * 2**20, impute={"value": "zero"}):
    total += pl.from_arrow(batch)["value"].sum()
print(round(total))
```

```text
49501115
```

Each `batch` is a `pyarrow.RecordBatch`, and all batches share one schema.

## What is different when streaming

- **Types** are decided from the first 20,000 rows. A later value that does
  not fit (text in a number column) becomes null, with a warning.
- **Duplicates** are found across the whole file, using 16 bytes of memory
  per distinct row. Pass `dedupe=False` for very large files where that
  matters.
- Only **imputation** that needs no look-ahead works: `zero` and `ffill`.
  Outliers and resampling need all the data, so they are not available.

More in [Large files](../large-files.md).
