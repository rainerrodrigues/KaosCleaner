# 2. Odd formats

Real files are often not plain comma-separated CSV with dot decimals. This
tutorial reads a European sales report, a tab-separated file and a Parquet
file, and cleans a pandas DataFrame that is already in memory.

```python
from pathlib import Path

import pandas as pd
import polars as pl
from kaos_cleaner import clean_csv, clean_file, clean_table
```

## A European report

A point-of-sale export: a title line, a comment, semicolons between fields,
decimal commas, dots as thousands separators and `dd.mm.yyyy` dates.

```python
Path("umsatz.csv").write_text(
    "Umsatzbericht 2024\n"
    "# exportiert aus dem Kassensystem\n"
    "Filiale;Datum;Umsatz;Kunden\n"
    "Köln;02.01.2024;1.234,50;87\n"
    "Bonn;02.01.2024;980,00;61\n"
    "Köln;03.01.2024;1.410,75;95\n"
)
df = clean_csv("umsatz.csv", delimiter=";", decimal=",", thousands=".", comment="#", header=2)
print(df)
```

```text
┌─────────┬────────────┬─────────┬────────┐
│ filiale ┆ datum      ┆ umsatz  ┆ kunden │
│ ---     ┆ ---        ┆ ---     ┆ ---    │
│ str     ┆ date       ┆ f64     ┆ i64    │
╞═════════╪════════════╪═════════╪════════╡
│ Köln    ┆ 2024-01-02 ┆ 1234.5  ┆ 87     │
│ Bonn    ┆ 2024-01-02 ┆ 980.0   ┆ 61     │
│ Köln    ┆ 2024-01-03 ┆ 1410.75 ┆ 95     │
└─────────┴────────────┴─────────┴────────┘
```

- `header=2` skips the title line. The header is the second line, because
  comment lines don't count.
- `comment="#"` skips the export note.
- `decimal=","` and `thousands="."` read `1.234,50` as 1234.5. Numbers with
  thousands marks need proper groups of three digits, so `02.01.2024` is not
  mistaken for the number 2012024: it stays a date, read as `dd.mm.yyyy`.

## Other file types

`clean_file` picks the reader from the extension. A `.tsv` file is read with
tabs; no `delimiter` needed:

```python
Path("readings.tsv").write_text("Station\tTemp °C\tRain mm\nA\t21.5\t0\nB\t19.0\t\nC\t22.1\t3.2\n")
print(clean_file("readings.tsv"))
```

```text
┌─────────┬────────┬─────────┐
│ station ┆ temp_c ┆ rain_mm │
│ ---     ┆ ---    ┆ ---     │
│ str     ┆ f64    ┆ f64     │
╞═════════╪════════╪═════════╡
│ A       ┆ 21.5   ┆ 0.0     │
│ B       ┆ 19.0   ┆ null    │
│ C       ┆ 22.1   ┆ 3.2     │
└─────────┴────────┴─────────┘
```

Parquet, Arrow, JSON and Excel files are loaded and then get the same
cleaning: names, whitespace, text that holds numbers, and duplicates.

```python
pl.DataFrame({"Product Name": [" Widget ", "Gadget", "Widget "],
              "Price": ["$9.99", "$24.50", "$9.99"]}).write_parquet("products.parquet")
print(clean_file("products.parquet"))
```

```text
┌──────────────┬───────┐
│ product_name ┆ price │
│ ---          ┆ ---   │
│ str          ┆ f64   │
╞══════════════╪═══════╡
│ Widget       ┆ 9.99  │
│ Gadget       ┆ 24.5  │
└──────────────┴───────┘
```

The two widgets became duplicates once their padding was trimmed, and the
second one was dropped. Every supported extension is listed in
[File formats](../file-formats.md). Excel files need
`pip install "kaos-cleaner[excel]"`.

## Data already in memory

`clean_table` takes a pandas or polars DataFrame, or a pyarrow table, and
returns the same kind:

```python
sales = pd.DataFrame({"Region": ["North", "South", None], "Units": [10, None, None], "Rep": ["Ann", "Raj", None]})
print(clean_table(sales, impute={"units": "zero"}))
```

```text
  region  units  rep
0  North   10.0  Ann
1  South    0.0  Raj
```

The all-empty third row was dropped before imputing, so only Raj's missing
units became 0.

**Next:** [A robot's sensor log](robot-log.md)
