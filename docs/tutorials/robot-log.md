# 3. A robot's sensor log

A mobile robot records a 200 Hz IMU and 50 Hz wheel odometry, both stamped
in nanoseconds since 1970 as ROS does. The IMU log has the usual faults:
timing jitter, three dropped samples, two glitches that read 25 g, and one
message logged twice. This tutorial cleans it and fuses both sensors on one
50 Hz time base.

## Make the logs

```python
import math
import random
from pathlib import Path

import polars as pl
from kaos_cleaner import clean_csv

random.seed(7)
t0 = 1_700_000_000_000_000_000  # ns since 1970
lines = ["Stamp (ns),Accel X,Accel Y,Gyro Z,Status"]
for i in range(200):                       # 200 Hz IMU, 1 second
    if i in (40, 41, 120):                 # dropped samples
        continue
    t = t0 + i * 5_000_000 + random.randint(-200_000, 200_000)   # jitter
    ax = math.sin(i / 20) + random.gauss(0, 0.02)
    if i in (75, 150):                     # sensor glitches
        ax = 25.0
    lines.append(f"{t},{ax:.4f},{random.gauss(0, 0.02):.4f},{0.1 + random.gauss(0, 0.005):.4f},"
                 f"{'OK' if i < 160 else 'WARN'}")
lines.append(lines[10])                    # a repeated message
Path("imu.csv").write_text("\n".join(lines) + "\n")

odom = ["stamp,x_m,v_mps"] + [f"{t0 + i * 20_000_000 + 1_000_000},{i * 0.02:.3f},1.0" for i in range(50)]
Path("odom.csv").write_text("\n".join(odom) + "\n")
```

## Clean the IMU

```python
imu = clean_csv(
    "imu.csv",
    epoch={"stamp_ns": "ns"},              # integer nanoseconds -> timestamps, exactly
    time_column="stamp_ns",                # the time base for the steps below
    outliers={"accel_x": "hampel"},        # glitches -> missing
    impute={"accel_x": "interpolate"},     # missing -> interpolated in time
)
print(imu.select("stamp_ns", "accel_x", "status").slice(73, 5))
```

```text
┌───────────────────────────────┬───────────┬────────┐
│ stamp_ns                      ┆ accel_x   ┆ status │
│ ---                           ┆ ---       ┆ ---    │
│ datetime[ns]                  ┆ f64       ┆ str    │
╞═══════════════════════════════╪═══════════╪════════╡
│ 2023-11-14 22:13:20.374945184 ┆ -0.584297 ┆ OK     │
│ 2023-11-14 22:13:20.380037070 ┆ -0.6431   ┆ OK     │
│ 2023-11-14 22:13:20.385121141 ┆ -0.6619   ┆ OK     │
│ 2023-11-14 22:13:20.389904544 ┆ -0.6955   ┆ OK     │
│ 2023-11-14 22:13:20.394929842 ┆ -0.7279   ┆ OK     │
└───────────────────────────────┴───────────┴────────┘
```

The first row is where the 25 g glitch was. The hampel filter compared it
with the median of its 7 neighbours, marked it as an outlier, and
interpolation filled it from the samples on either side, weighted by their
timestamps. Each step:

- `epoch={"stamp_ns": "ns"}` turned the integer column into timestamps with
  every nanosecond kept (the name is the cleaned one: `"Stamp (ns)"` →
  `stamp_ns`).
- The repeated message was dropped as a duplicate.
- `"hampel"` follows the signal, so the sine wave itself is not flagged. A
  global method like `"zscore"` would also catch 25 g here, but it fails on
  signals that drift.
- With `time_column`, interpolation weights by time, so the jitter does not
  bend the filled values.

## Fuse with odometry

The IMU ticks every ~5 ms with jitter, and odometry every 20 ms at a 1 ms
offset. Resample both to 20 ms. Grid times are multiples of the period, so
the two tables line up exactly:

```python
imu_20ms = clean_csv("imu.csv", epoch={"stamp_ns": "ns"}, time_column="stamp_ns",
                     outliers={"accel_x": "hampel"}, resample="20ms", resample_method="mean")
odom_20ms = clean_csv("odom.csv", epoch={"stamp": "ns"}, time_column="stamp", resample="20ms")
fused = imu_20ms.join(odom_20ms.rename({"stamp": "stamp_ns"}), on="stamp_ns")
print(fused.select("stamp_ns", "accel_x", "gyro_z", "x_m", "status").head(5))
```

```text
┌─────────────────────────┬──────────┬──────────┬───────┬────────┐
│ stamp_ns                ┆ accel_x  ┆ gyro_z   ┆ x_m   ┆ status │
│ ---                     ┆ ---      ┆ ---      ┆ ---   ┆ ---    │
│ datetime[ns]            ┆ f64      ┆ f64      ┆ f64   ┆ str    │
╞═════════════════════════╪══════════╪══════════╪═══════╪════════╡
│ 2023-11-14 22:13:20.020 ┆ 0.323625 ┆ 0.1031   ┆ 0.019 ┆ OK     │
│ 2023-11-14 22:13:20.040 ┆ 0.48965  ┆ 0.0998   ┆ 0.039 ┆ OK     │
│ 2023-11-14 22:13:20.060 ┆ 0.660925 ┆ 0.101275 ┆ 0.059 ┆ OK     │
│ 2023-11-14 22:13:20.080 ┆ 0.7915   ┆ 0.1022   ┆ 0.079 ┆ OK     │
│ 2023-11-14 22:13:20.100 ┆ 0.878525 ┆ 0.1013   ┆ 0.099 ┆ OK     │
└─────────────────────────┴──────────┴──────────┴───────┴────────┘
```

- The IMU used `"mean"`, which averages the four readings in each 20 ms
  period. That is the right choice when going to a lower rate, because it
  smooths noise instead of picking one sample.
- Odometry used the default `"linear"`, which interpolates the position at
  each grid time, correcting its 1 ms offset.
- `status` is text, so it takes the last value in each period.

## Where next

- [Sensor and robot data](../sensor-data.md) explains every method and
  option in detail.
- To clean the robot's data as it arrives rather than from a log, see
  [Live data](live-data.md).

**Next:** [Live data](live-data.md)
