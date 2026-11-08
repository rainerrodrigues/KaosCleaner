# Sensor and robot data

Logs from robots, IMUs, lidar drivers and data loggers have their own kinds
of mess: timestamps with micro- or nanoseconds, times stored as numbers
since 1970, and dropped samples. kaos-cleaner handles all three.

## Nanosecond timestamps

Timestamps with more than millisecond precision keep every digit and come
back as `timestamp[ns]` (polars `Datetime("ns")`):

```text
t,accel
2024-01-01T10:00:00.000100,1.0
2024-01-01T10:00:00.000200,1.1
2024-01-01 10:00:00.000300123,1.3
```

A text column is converted when every value is an ISO 8601 date and time
(`T` or a space between them, up to nine fraction digits, optional `Z`) and
at least one value has a fraction of a second. Timestamps at whole seconds
or milliseconds are still read as before (`timestamp[ms]`).

Tables passed to `clean_table` keep their precision too: polars'
default microsecond datetimes and pyarrow `timestamp[us]`/`timestamp[ns]`
come back as `timestamp[ns]`.

## Times stored as numbers

ROS stamps, `time.time()` logs and many data loggers store time as a number
since 1970. Name those columns and their unit with `epoch`:

```python
df = clean_csv("imu.csv", epoch={"stamp": "ns", "wall_time": "s"})
```

Units are `"s"`, `"ms"`, `"us"` and `"ns"`. Integers convert exactly. A
float column of seconds (`1700000000.123456`) resolves to about 0.25 µs, the
limit of a 64-bit float at present-day values; log nanoseconds as integers
when every digit matters. Use the cleaned column names (`"Stamp (ns)"` →
`"stamp_ns"`). Values out of range become missing, with a warning.

## Outliers

Spikes from a glitching sensor (a lidar return of 50 m in a 1 m corridor)
can be turned into missing values, which `impute` can then fill:

```python
df = clean_csv("range.csv", outliers={"range_m": "hampel"}, impute={"range_m": "interpolate"})
```

| Method | A value is an outlier when it is | Good for |
|---|---|---|
| `"hampel"` | more than 3 scaled MADs from the median of the 7 values around it | sensor spikes on a signal that drifts or moves |
| `"mad"` | more than 3.5 on the modified z-score, `0.6745 |x − median| / MAD` | a stable signal; robust to the outliers themselves |
| `"iqr"` | more than 1.5 IQRs below the first or above the third quartile | skewed distributions |
| `"zscore"` | more than 3 standard deviations from the mean | roughly normal data without huge outliers |

`outlier_threshold` replaces the number, and `outlier_window` sets the
hampel window (odd, at least 3 rows). A single method (`outliers="mad"`)
applies to every numeric column except the `time_column`. With a
`time_column`, the hampel window takes neighbours in time order.

## Dropped samples

`impute="interpolate"` fills gaps in numeric columns on the straight line
between the neighbouring values:

```python
df = clean_csv("imu.csv", impute={"accel_x": "interpolate", "gyro_z": "interpolate"})
```

| accel_x before | after |
|---|---|
| null | null |
| 1.0 | 1.0 |
| null | 2.0 |
| 3.0 | 3.0 |
| null | null |

Without a `time_column` it works by row position, which assumes samples are
evenly spaced (a fixed rate). Name the time column and gaps are weighted by
time instead, so irregular samples interpolate correctly, even when rows are
out of time order:

```python
df = clean_csv("gps.csv", epoch={"stamp": "ns"}, time_column="stamp", impute={"lat": "interpolate"})
```
 Values before the first and after the last reading stay missing, since
there is nothing to interpolate between; combine with another strategy in
your own code if you need them filled. Interpolation needs the whole column,
so it is not available when streaming; there, `ffill` carries the last value
forward.

## Resampling to a fixed rate

Sensors rarely tick in step: an IMU at 200 Hz, odometry at 50 Hz, a GPS at
an uneven 1 Hz. `resample` puts a table on a fixed time grid:

```python
imu = clean_csv("imu.csv", epoch={"stamp": "ns"}, time_column="stamp", resample="20ms")
odom = clean_csv("odom.csv", epoch={"stamp": "ns"}, time_column="stamp", resample="20ms")
fused = imu.join(odom, on="stamp")   # grid times are multiples of 20 ms, so they line up
```

| `resample_method=` | Each row holds |
|---|---|
| `"linear"` (default) | the value at the grid time, interpolated between the readings around it (numeric columns), or the latest reading at or before it (other columns); only grid times within the data |
| `"mean"` | the mean of the readings in the period starting at the grid time (`last` for non-numeric columns) |
| `"last"` | the last reading in the period |

Use `"linear"` to align or upsample, and `"mean"` to downsample a fast
sensor without aliasing spikes. Periods without readings give rows with
missing values, so the grid stays regular. Periods are a whole number with
a unit: `ns`, `us`, `ms`, `s`, `min`, `h`. The time column becomes
`timestamp[ns]`. Resampling makes new rows, so it cannot be combined with
`source_row`, and it needs the whole data (not available when streaming).

Steps run in this order: parsing and type inference, epoch conversion,
empty and duplicate rows, outliers, imputation, resampling.

## Live data

For data that arrives in pieces, a `LiveCleaner` keeps state between
batches. Column types are decided by the first batch, so every batch has the
same schema. Duplicates are found across batches, `ffill` carries the last
value over, and `source_row` counts rows across the feed:

```python
from kaos_cleaner import LiveCleaner

with LiveCleaner(epoch={"stamp": "ns"}, impute="ffill") as cleaner:
    for batch in sensor_feed():          # pyarrow, polars or pandas tables
        publish(cleaner.clean(batch))    # the same type back
```

Outliers, resampling and the strategies that need all the data (`mean`,
`median`, `mode`, `bfill`, `interpolate`) are not available in a live
session. Run them on a window of collected batches with `clean_table`
instead.

## On the robot

Wheels exist for Linux aarch64 (NVIDIA Jetson, Raspberry Pi OS 64-bit), so
the same code runs on the robot and on your workstation. The first import
unpacks the runtime (about 500 MB) once. Each process starts the engine once,
which takes under a second after that; keep one long-running process
rather than starting a new one per file.
