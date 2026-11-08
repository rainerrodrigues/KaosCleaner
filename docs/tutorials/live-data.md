# 4. Live data

On the robot, readings arrive in small batches from a message queue or a
ROS topic. Cleaning each batch with `clean_table` would forget everything
between calls: a gap at the start of a batch could not be forward-filled, a
message repeated across two batches would not be caught, and a batch whose
values happen to look different could come back with different column types.
A `LiveCleaner` keeps that state.

```python
import polars as pl
from kaos_cleaner import LiveCleaner

def feed():
    """Batches as they might arrive from a message queue."""
    yield pl.DataFrame({"Stamp": [1_000, 2_000, 3_000], "Battery %": [98.0, None, 97.5], "Mode": ["auto"] * 3})
    yield pl.DataFrame({"Stamp": [3_000, 4_000, 5_000], "Battery %": [97.5, None, 96.9],
                        "Mode": ["auto", "manual", "manual"]})
    yield pl.DataFrame({"Stamp": [6_000], "Battery %": [None], "Mode": ["manual"]})

with LiveCleaner(epoch={"stamp": "ms"}, impute={"battery": "ffill"}, source_row=True) as cleaner:
    for batch in feed():
        print(cleaner.clean(batch))
```

```text
┌────────────┬─────────────────────┬─────────┬──────┐
│ source_row ┆ stamp               ┆ battery ┆ mode │
│ ---        ┆ ---                 ┆ ---     ┆ ---  │
│ i64        ┆ datetime[ns]        ┆ f64     ┆ str  │
╞════════════╪═════════════════════╪═════════╪══════╡
│ 1          ┆ 1970-01-01 00:00:01 ┆ 98.0    ┆ auto │
│ 2          ┆ 1970-01-01 00:00:02 ┆ 98.0    ┆ auto │
│ 3          ┆ 1970-01-01 00:00:03 ┆ 97.5    ┆ auto │
└────────────┴─────────────────────┴─────────┴──────┘
┌────────────┬─────────────────────┬─────────┬────────┐
│ source_row ┆ stamp               ┆ battery ┆ mode   │
│ ---        ┆ ---                 ┆ ---     ┆ ---    │
│ i64        ┆ datetime[ns]        ┆ f64     ┆ str    │
╞════════════╪═════════════════════╪═════════╪════════╡
│ 5          ┆ 1970-01-01 00:00:04 ┆ 97.5    ┆ manual │
│ 6          ┆ 1970-01-01 00:00:05 ┆ 96.9    ┆ manual │
└────────────┴─────────────────────┴─────────┴────────┘
┌────────────┬─────────────────────┬─────────┬────────┐
│ source_row ┆ stamp               ┆ battery ┆ mode   │
│ ---        ┆ ---                 ┆ ---     ┆ ---    │
│ i64        ┆ datetime[ns]        ┆ f64     ┆ str    │
╞════════════╪═════════════════════╪═════════╪════════╡
│ 7          ┆ 1970-01-01 00:00:06 ┆ 96.9    ┆ manual │
└────────────┴─────────────────────┴─────────┴────────┘
```

Across the three batches:

- **Batch 2 repeated** the last message of batch 1 (row 4). It was dropped
  because the session remembers every row it has seen.
- **The missing battery values** at rows 5 and 7 were filled from the
  previous reading, even across batch boundaries.
- **`source_row`** counts rows over the whole feed, so the gap at 4 shows
  exactly which message was dropped.
- **Types are fixed by the first batch.** If a later batch sent
  `"Battery %": "low"`, that value would become null with a warning, and the
  column would stay `f64`. Downstream code always sees the same schema.

## Rules

- Use `with` or call `close()`, so the session's memory is freed.
- Every batch needs the same columns as the first one.
- Options that need all the data are not available in a session: `outliers`,
  `resample`, and the `mean`/`median`/`mode`/`bfill`/`interpolate`
  strategies. Collect a window of batches and use `clean_table` for those.
- The duplicate check stores 16 bytes per distinct row. For a feed that runs
  for days with mostly unique rows, pass `dedupe=False` or start a new
  session periodically.

**Next:** [Audit and undo](audit-undo.md)
