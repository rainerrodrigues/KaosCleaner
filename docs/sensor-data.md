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

It works by row position, which assumes samples are evenly spaced (a fixed
rate). Values before the first and after the last reading stay missing, since
there is nothing to interpolate between; combine with another strategy in
your own code if you need them filled. Interpolation needs the whole column,
so it is not available when streaming; there, `ffill` carries the last value
forward.

## On the robot

Wheels exist for Linux aarch64 (NVIDIA Jetson, Raspberry Pi OS 64-bit), so
the same code runs on the robot and on your workstation. The first import
unpacks the runtime (about 500 MB) once. Each process starts the engine once,
which takes under a second after that; keep one long-running process
rather than starting a new one per file.
