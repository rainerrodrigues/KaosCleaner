# Logging

The engine reports what it did through Python's standard `logging` module,
on the logger named `"kaos_cleaner"`:

```text
INFO:kaos_cleaner:Converted column `paid` from text to Bool
INFO:kaos_cleaner:Dropped 2 empty rows
INFO:kaos_cleaner:Dropped 2000 duplicate rows
INFO:kaos_cleaner:Imputed 17 missing values in `score` (median)
WARNING:kaos_cleaner:thread = 1 warning: only found 3 / 4 columns around data row: 12. Filling remaining columns with `missing`
```

Like any well-behaved library, kaos-cleaner does not configure logging
itself; nothing is shown until your application does. To see everything:

```python
import logging
logging.basicConfig(level=logging.INFO)
```

or only this library's messages, at warning level and up:

```python
logging.getLogger("kaos_cleaner").setLevel(logging.WARNING)
logging.getLogger("kaos_cleaner").addHandler(logging.StreamHandler())
```

| Level | What |
|---|---|
| `INFO` | Rows dropped, columns converted, values imputed |
| `WARNING` | Malformed rows found while parsing; values that did not fit a streaming column's type |

Messages for a call are delivered when that call (or, when streaming, that
batch) finishes, rather than while the engine works. This is deliberate:
calling into Python from the engine's parsing threads could deadlock the two
runtimes.
