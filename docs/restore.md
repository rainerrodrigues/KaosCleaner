# Undo the cleaning

Cleaning changes data in ways that cannot be reversed from the result alone.
Whitespace is trimmed, `"$1,250.00"` becomes `1250.0`, `" Spend (USD)"`
becomes `spend_usd`, and empty and duplicate rows are gone. To get back to
the original, kaos-cleaner records where every row came from and reads
those rows again from the source, exactly as they were.

## Track rows with `source_row`

Pass `source_row=True` to any cleaning function. The result gets a first
column, `source_row`, with each row's position among the source's data rows
(1 = the first row after the header):

```python
from kaos_cleaner import clean_csv, restore

df = clean_csv("orders.csv", source_row=True)
```

```text
source_row  customer_id  spend_usd  active
1           1            1250.0     true
4           2            null       false     ← row 2 was a duplicate, row 3 empty
5           3            7.0        true
```

The numbers survive filtering, sorting and joins in your own code, so you
can always tell which original row a value came from. Streaming
(`iter_clean_csv`, `clean_csv_to_parquet`) numbers rows across the whole
file too.

## Get the original rows back

```python
original = restore(df, "orders.csv")                  # the rows of df, as in the file
removed  = restore(df, "orders.csv", rows="dropped")  # what cleaning removed
whole    = restore(None, "orders.csv", rows="all")    # the entire file, untouched
```

| `rows=` | Returns |
|---|---|
| `"kept"` (default) | the original rows of `df`, in `df`'s order |
| `"dropped"` | the rows cleaning removed (empty or duplicate), in file order |
| `"all"` | the whole source |

For text files the result has the original column names and every value as
the exact text in the file: untrimmed, with `NA` and empty cells as they
were, nothing converted. Other formats (Parquet, JSON, Excel, ...) are read
again with their own types.

`restore` also takes the original table instead of a path, for data cleaned
with `clean_table`:

```python
df = clean_table(original_df, source_row=True)
restore(df, original_df)            # same type as original_df
```

!!! note "Use the same source and parsing options"
    `restore` counts rows the way the cleaning did, so pass the same file
    and the same parsing options (`delimiter`, `header`, `comment`, ...).
    If the file changed in between, the positions point at different rows.
    A position beyond the end of the source raises a `ValueError`.

## Seeing what changed

Put the cleaned and original values side by side:

```python
import polars as pl

df = clean_csv("orders.csv", source_row=True)
side_by_side = pl.concat([df, restore(df, "orders.csv").select(pl.all().name.prefix("raw "))], how="horizontal")
```

## In C and Julia

The same options are available to every caller: `"source_row": true` adds
the column, and `"raw": true` reads a file as it is (every column as
untrimmed text, no missing markers, no cleaning steps), which is what
`restore` uses. `raw` reads the whole file and is not available for streams.
