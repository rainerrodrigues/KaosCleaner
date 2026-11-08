# 5. Audit and undo

Cleaning changes values: `"N/A"` becomes null and then a mean, `" 68 "`
becomes `68.0`, and duplicate and empty rows disappear. When someone asks
"where did this number come from?", or you need the original back, record
each row's origin with `source_row` and use `restore`.

```python
from pathlib import Path

import polars as pl
from kaos_cleaner import clean_csv, restore

Path("patients.csv").write_text(
    "Patient ID,Weight (kg),Visit\n"
    " P-001 ,72.5,2024-03-01\n"
    "P-002,N/A,2024-03-02\n"
    "P-002,N/A,2024-03-02\n"
    ",,\n"
    "P-003, 68 ,2024-03-04\n"
)
df = clean_csv("patients.csv", source_row=True, impute={"weight_kg": "mean"})
print(df)
```

```text
┌────────────┬────────────┬───────────┬────────────┐
│ source_row ┆ patient_id ┆ weight_kg ┆ visit      │
│ ---        ┆ ---        ┆ ---       ┆ ---        │
│ i64        ┆ str        ┆ f64       ┆ date       │
╞════════════╪════════════╪═══════════╪════════════╡
│ 1          ┆ P-001      ┆ 72.5      ┆ 2024-03-01 │
│ 2          ┆ P-002      ┆ 70.25     ┆ 2024-03-02 │
│ 5          ┆ P-003      ┆ 68.0      ┆ 2024-03-04 │
└────────────┴────────────┴───────────┴────────────┘
```

`source_row` is each row's position among the file's data rows. Rows 3 (a
duplicate) and 4 (empty) were dropped.

## The original rows

```python
print(restore(df, "patients.csv"))
```

```text
┌────────────┬─────────────┬────────────┐
│ Patient ID ┆ Weight (kg) ┆ Visit      │
│ ---        ┆ ---         ┆ ---        │
│ str        ┆ str         ┆ str        │
╞════════════╪═════════════╪════════════╡
│  P-001     ┆ 72.5        ┆ 2024-03-01 │
│ P-002      ┆ N/A         ┆ 2024-03-02 │
│ P-003      ┆  68         ┆ 2024-03-04 │
└────────────┴─────────────┴────────────┘
```

These are exactly the bytes in the file: the original header, padding,
`N/A` and all.

## What was removed

```python
print(restore(df, "patients.csv", rows="dropped"))
```

```text
┌────────────┬─────────────┬────────────┐
│ Patient ID ┆ Weight (kg) ┆ Visit      │
│ ---        ┆ ---         ┆ ---        │
│ str        ┆ str         ┆ str        │
╞════════════╪═════════════╪════════════╡
│ P-002      ┆ N/A         ┆ 2024-03-02 │
│            ┆             ┆            │
└────────────┴─────────────┴────────────┘
```

## Before and after, side by side

```python
raw = restore(df, "patients.csv").select(pl.all().name.prefix("raw: "))
print(pl.concat([df.select("source_row", "weight_kg"), raw.select("raw: Weight (kg)")], how="horizontal"))
```

```text
┌────────────┬───────────┬──────────────────┐
│ source_row ┆ weight_kg ┆ raw: Weight (kg) │
│ ---        ┆ ---       ┆ ---              │
│ i64        ┆ f64       ┆ str              │
╞════════════╪═══════════╪══════════════════╡
│ 1          ┆ 72.5      ┆ 72.5             │
│ 2          ┆ 70.25     ┆ N/A              │
│ 5          ┆ 68.0      ┆  68              │
└────────────┴───────────┴──────────────────┘
```

The `70.25` is visibly an imputed value: the file said `N/A`. Keep
`source_row` in data you hand on, and this check stays possible later.
`restore` works on filtered or sorted results too, and returns rows in the
order of the data you pass. See [Undo the cleaning](../restore.md) for the
details.

**Next:** [Files larger than memory](large-files.md)
