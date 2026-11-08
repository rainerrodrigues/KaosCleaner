# 1. Clean your first file

A small order export with the usual problems: padded names, a header with
spaces and units, dates in day/month order, amounts with currency signs, a
duplicate row, an empty row, and `N/A`/`NA` markers.

## The file

```python
from pathlib import Path

import polars as pl
from kaos_cleaner import clean_csv

Path("orders.csv").write_text(
    " Order ID ,Customer Name,Order Date,Amount (USD),Paid,Notes\n"
    "1001,  Alice Smith ,13/01/2024,\"$1,250.00\",Yes,\n"
    "1002,Bob Jones,14/01/2024,$80.50,no,rush\n"
    "1002,Bob Jones,14/01/2024,$80.50,no,rush\n"
    ",,,,,\n"
    "1003,carol white,15/01/2024,N/A,Y,NA\n"
    "1004,Dan Brown,16/01/2024,$42.00,N,\n"
)
print(pl.read_csv("orders.csv", infer_schema=False))
```

Read as plain text, everything is a string:

```text
┌────────────┬────────────────┬────────────┬──────────────┬──────┬───────┐
│  Order ID  ┆ Customer Name  ┆ Order Date ┆ Amount (USD) ┆ Paid ┆ Notes │
│ ---        ┆ ---            ┆ ---        ┆ ---          ┆ ---  ┆ ---   │
│ str        ┆ str            ┆ str        ┆ str          ┆ str  ┆ str   │
╞════════════╪════════════════╪════════════╪══════════════╪══════╪═══════╡
│ 1001       ┆   Alice Smith  ┆ 13/01/2024 ┆ $1,250.00    ┆ Yes  ┆ null  │
│ 1002       ┆ Bob Jones      ┆ 14/01/2024 ┆ $80.50       ┆ no   ┆ rush  │
│ 1002       ┆ Bob Jones      ┆ 14/01/2024 ┆ $80.50       ┆ no   ┆ rush  │
│ null       ┆ null           ┆ null       ┆ null         ┆ null ┆ null  │
│ 1003       ┆ carol white    ┆ 15/01/2024 ┆ N/A          ┆ Y    ┆ NA    │
│ 1004       ┆ Dan Brown      ┆ 16/01/2024 ┆ $42.00       ┆ N    ┆ null  │
└────────────┴────────────────┴────────────┴──────────────┴──────┴───────┘
```

## Clean it

Turn on logging first, so you can see what the engine does:

```python
import logging

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
df = clean_csv("orders.csv")
print(df)
```

```text
INFO Converted column `order_date` from text to Date
INFO Converted column `amount_usd` from text to Float64
INFO Converted column `paid` from text to Bool
INFO Dropped 1 empty row
INFO Dropped 1 duplicate row
┌──────────┬───────────────┬────────────┬────────────┬───────┬───────┐
│ order_id ┆ customer_name ┆ order_date ┆ amount_usd ┆ paid  ┆ notes │
│ ---      ┆ ---           ┆ ---        ┆ ---        ┆ ---   ┆ ---   │
│ i64      ┆ str           ┆ date       ┆ f64        ┆ bool  ┆ str   │
╞══════════╪═══════════════╪════════════╪════════════╪═══════╪═══════╡
│ 1001     ┆ Alice Smith   ┆ 2024-01-13 ┆ 1250.0     ┆ true  ┆ null  │
│ 1002     ┆ Bob Jones     ┆ 2024-01-14 ┆ 80.5       ┆ false ┆ rush  │
│ 1003     ┆ carol white   ┆ 2024-01-15 ┆ null       ┆ true  ┆ null  │
│ 1004     ┆ Dan Brown     ┆ 2024-01-16 ┆ 42.0       ┆ false ┆ null  │
└──────────┴───────────────┴────────────┴────────────┴───────┴───────┘
```

What happened:

- **Names** became `snake_case`: `" Amount (USD)"` → `amount_usd`.
- **Whitespace** around `Alice Smith` is gone.
- **Dates** were read day-first. That was safe because `13/01` can only be
  day-first. A column like `01/02/2024` would stay text unless you pass
  `datetime_formats=["dd/mm/yyyy"]` ([why](../options.md#type-inference)).
- **Amounts** lost the `$` and the thousands separator. **Paid** became a
  boolean from `Yes`/`no`/`Y`/`N`.
- **`N/A` and `NA`** became nulls. The **duplicate** and the **empty row** were
  dropped.

## Tune it

The notes column is not needed, and the missing amount should be filled.
Imputation uses the cleaned column names:

```python
df = clean_csv("orders.csv", drop=["Notes"], impute={"amount_usd": "median"})
print(df)
```

```text
INFO Imputed 1 missing value in `amount_usd` (median)
┌──────────┬───────────────┬────────────┬────────────┬───────┐
│ order_id ┆ customer_name ┆ order_date ┆ amount_usd ┆ paid  │
│ ---      ┆ ---           ┆ ---        ┆ ---        ┆ ---   │
│ i64      ┆ str           ┆ date       ┆ f64        ┆ bool  │
╞══════════╪═══════════════╪════════════╪════════════╪═══════╡
│ 1001     ┆ Alice Smith   ┆ 2024-01-13 ┆ 1250.0     ┆ true  │
│ 1002     ┆ Bob Jones     ┆ 2024-01-14 ┆ 80.5       ┆ false │
│ 1003     ┆ carol white   ┆ 2024-01-15 ┆ 80.5       ┆ true  │
│ 1004     ┆ Dan Brown     ┆ 2024-01-16 ┆ 42.0       ┆ false │
└──────────┴───────────────┴────────────┴────────────┴───────┘
```

Columns can be named as in the file (`"Notes"`) or in snake_case (`"notes"`).
Every option is listed in [Cleaning options](../options.md).

## Save it

The result is an ordinary polars DataFrame:

```python
df.write_parquet("orders.parquet")
```

Use `process_dataset` instead of `clean_csv` to get a `pyarrow.Table`.

**Next:** [Odd formats](formats.md)
