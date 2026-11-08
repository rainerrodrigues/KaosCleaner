# File formats

The engine parses delimited text itself. Other formats are loaded with
pyarrow or polars and then cleaned in memory with the same rules.

## One function for any file

`clean_file` picks the reader from the extension and returns a
`polars.DataFrame`:

```python
from kaos_cleaner import clean_file

df = clean_file("orders.tsv")
df = clean_file("orders.parquet", impute="median")
df = clean_file("export.xlsx", drop=["notes"])
```

| Extension | Read by | Notes |
|---|---|---|
| `.csv`, `.txt`, `.dat` | engine | delimiter detected unless given |
| `.tsv`, `.tab` | engine | tab-separated |
| `.psv` | engine | pipe-separated |
| any of the above + `.gz` | engine | gzip is decompressed transparently |
| `.parquet`, `.pq` | pyarrow | |
| `.arrow`, `.feather`, `.ipc` | pyarrow | Arrow IPC file / Feather v2 |
| `.jsonl`, `.ndjson` | pyarrow | one JSON object per line |
| `.json` | polars | an array of records |
| `.xlsx`, `.xlsm`, `.xls`, `.ods` | polars | first sheet; needs `pip install "kaos-cleaner[excel]"` |

Text files accept the [parsing options](options.md#parsing-options)
(`delimiter`, `decimal`, `thousands`, `comment`, `header`); for the other
formats they raise a `TypeError`, since those files carry their own types.

`clean_csv`, `process_dataset` and the streaming functions read every text
format too, `.gz` included; only `clean_file` looks at the extension, so
with them pass `delimiter="\t"` yourself if detection picks the wrong one.

## Data already in memory

`clean_table` cleans a pyarrow `Table` or `RecordBatch`, a polars
`DataFrame` or a pandas `DataFrame`, and returns the same kind:

```python
import pandas as pd
from kaos_cleaner import clean_table

df = clean_table(pd.read_sql("select * from orders", conn), impute={"amount": "median"})
```

It runs the whole pipeline: snake_case names, text-column type inference,
missing markers, empty and duplicate rows, imputation. Columns are copied
into the engine and back through the Arrow C Data Interface.

Column types the engine does not read natively are converted first:

| Input type | Becomes |
|---|---|
| dictionary / categorical | its values |
| `string_view` | string |
| timestamp with a time zone | timestamp in UTC, without a zone |
| decimal, float16 | float64 |
| time, duration | text |

Nested columns (lists, structs, maps) and binary columns are not supported
and raise a `RuntimeError` naming the column.
