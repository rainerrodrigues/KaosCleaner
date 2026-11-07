# Cleaning options

Every function takes the same keyword options. Unknown options raise a
`TypeError` in Python; invalid values raise a `RuntimeError` naming the
problem.

| Option | Default | Effect |
|---|---|---|
| `drop` | none | Column names to remove |
| `keep` | all | If given, only these columns are kept |
| `missing_values` | none | Extra cell values to treat as missing |
| `rename` | `True` | Rename columns to unique `snake_case` |
| `dedupe` | `True` | Drop rows that repeat an earlier row |
| `drop_empty_rows` | `True` | Drop rows where every value is missing |
| `infer_types` | `True` | Convert text columns holding booleans, dates or formatted numbers |
| `datetime_formats` | none | Date formats to use, e.g. `["dd/mm/yyyy"]` |
| `impute` | none | Fill missing values (strategy, or `{column: strategy}`) |

## The pipeline

Steps run in this order:

1. **Parse** with the missing-value markers, trimming unquoted cells.
2. **Rename** columns to snake_case (`rename`).
3. **Select** columns (`keep`, then `drop`). Names may be given as in the file
   (`"Internal ID"`) or in snake_case (`"internal_id"`); an unknown name is an
   error rather than silently ignored.
4. **Clean text**: trim whitespace, turn missing markers into nulls, replace
   invalid UTF-8 with `�`.
5. **Infer types** (`infer_types`).
6. **Drop empty rows** (`drop_empty_rows`).
7. **Drop duplicate rows** (`dedupe`), comparing every column; `null` equals `null`.
8. **Impute** (`impute`).
9. Columns without remaining nulls are marked non-nullable.

## Missing values

These are always treated as missing: the empty string, `NA`, `N/A`, `n/a`,
`na`, `NaN`, `nan`, `null`, `NULL`, `None`, `none`. Add your own with
`missing_values=["-", "?"]`.

## Type inference

Numbers, ISO dates (`2024-01-31`) and timestamps (`2024-01-31T10:30:00`) are
recognised while parsing. Text columns are then converted when **every**
non-missing value fits one of these rules; otherwise the column stays text.

**Booleans**: `true/false`, `t/f`, `yes/no`, `y/n`, `1/0`, in any case.

**Formatted numbers**: a currency sign (`$ € £ ¥`) and/or thousands
separators: `$1,250.00`, `€12`, `3,400`. Columns become integers when no value
has a decimal point, floats otherwise. Percentages and decimal commas
(`12,5`) are left as text, because they cannot be read unambiguously.

**Dates** in these formats, with or without a time:

| Format | Example |
|---|---|
| `yyyy-mm-dd HH:MM:SS`, `yyyy-mm-dd HH:MM` | `2024-01-31 10:30` |
| `yyyy/mm/dd` | `2024/01/31` |
| `dd/mm/yyyy`, `mm/dd/yyyy` | `31/01/2024`, `01/31/2024` |
| `dd.mm.yyyy`, `dd-mm-yyyy` | `31.01.2024` |
| `dd u yyyy`, `u dd, yyyy` | `31 Jan 2024`, `Jan 31, 2024` |
| `dd U yyyy`, `U dd, yyyy` | `31 January 2024` |

!!! warning "Day-first or month-first?"
    A column like `01/02/2024, 03/04/2024` reads as valid dates both
    day-first and month-first. kaos-cleaner will not guess: such columns stay
    text. Say which one you mean:

    ```python
    clean_csv("data.csv", datetime_formats=["dd/mm/yyyy"])
    ```

    When you pass `datetime_formats`, only those formats are tried, first
    match wins. The syntax is Julia's
    [`DateFormat`](https://docs.julialang.org/en/v1/stdlib/Dates/#Dates.DateFormat):
    `yyyy` year, `mm` month, `dd` day, `HH:MM:SS` time, `u`/`U` month name.

Turn inference off with `infer_types=False` to keep text columns as text.

## Imputation

| Strategy | Fills with | Columns |
|---|---|---|
| `"mean"` | the column mean | numeric |
| `"median"` | the column median | numeric |
| `"zero"` | `0` | numeric |
| `"mode"` | the most frequent value | any |
| `"ffill"` | the previous non-missing value | any |
| `"bfill"` | the next non-missing value | any |

A single strategy applies to every column it suits, so `impute="median"`
fills numeric columns and leaves text alone. A dict applies strategies per
column (cleaned names) and raises an error if one does not suit its column:

```python
clean_csv("data.csv", impute={"price": "median", "city": "mode", "reading": "ffill"})
```

Values before the first (`ffill`) or after the last (`bfill`) non-missing
value stay missing. Integer columns filled with a mean or median become
floats.
