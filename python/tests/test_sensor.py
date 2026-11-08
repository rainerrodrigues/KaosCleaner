"""Tests for sensor data: nanosecond timestamps, epoch columns and interpolation."""

from datetime import datetime

import polars as pl
import pyarrow as pa
import pytest
from kaos_cleaner import clean_csv, clean_table, iter_clean_csv

IMU = (
    "t,stamp_ns,stamp_s,accel\n"
    "2024-01-01T10:00:00.000100,1700000000000000001,1700000000.25,1.0\n"
    "2024-01-01T10:00:00.000200,1700000000000000002,1700000000.5,\n"
    "2024-01-01 10:00:00.000300,1700000000000000003,1700000000.75,\n"
    "2024-01-01T10:00:00.000400,1700000000000000004,1700000001,4.0\n"
)


def test_sub_millisecond_timestamps(tmp_path):
    path = tmp_path / "imu.csv"
    path.write_text(IMU)
    df = clean_csv(path, epoch={"stamp_ns": "ns", "stamp_s": "s"}, impute={"accel": "interpolate"})
    assert df.schema["t"] == pl.Datetime("ns")
    assert df["t"].diff().drop_nulls().dt.total_microseconds().to_list() == [100, 100, 100]
    assert df["stamp_ns"].dt.epoch("ns").to_list() == [1700000000000000001 + i for i in range(4)]
    assert df["stamp_s"][0] == datetime(2023, 11, 14, 22, 13, 20, 250000)
    assert df["accel"].to_list() == [1.0, 2.0, 3.0, 4.0]


def test_streaming_keeps_nanoseconds(tmp_path):
    path = tmp_path / "log.csv"
    path.write_text("t,v\n" + "".join(f"2024-01-01T10:00:00.{i:09d},{i}\n" for i in range(3000)))
    batches = list(iter_clean_csv(path, chunk_size=8192, epoch=None))
    assert len(batches) > 1
    table = pa.Table.from_batches(batches)
    assert table.schema.field("t").type == pa.timestamp("ns")
    assert pl.from_arrow(table)["t"].dt.nanosecond().to_list() == list(range(3000))


def test_clean_table_keeps_polars_microseconds():
    df = pl.DataFrame({"t": [datetime(2024, 1, 1, 0, 0, 0, 123456), datetime(2024, 1, 1, 0, 0, 0, 123457)]})
    out = clean_table(df)
    assert out["t"].dt.microsecond().to_list() == [123456, 123457]  # used to be cut to milliseconds


def test_interpolate_leaves_edges():
    out = clean_table(pl.DataFrame({"id": [1, 2, 3, 4, 5], "x": [None, 1.0, None, 3.0, None]}), impute="interpolate")
    assert out["x"].to_list() == [None, 1.0, 2.0, 3.0, None]


def test_outliers_then_interpolation(tmp_path):
    path = tmp_path / "range.csv"
    values = [1.0, 1.1, 0.9, 1.0, 50.0, 1.05, 0.95, 1.0, -40.0, 1.0]
    path.write_text("i,range_m\n" + "".join(f"{i},{v}\n" for i, v in enumerate(values)))
    df = clean_csv(path, outliers={"range_m": "hampel"}, outlier_window=5, impute={"range_m": "interpolate"})
    assert df["range_m"][4] == pytest.approx(1.025) and df["range_m"][8] == pytest.approx(1.0)
    assert df["i"].to_list() == list(range(10))


def test_resample_to_fixed_rate(tmp_path):
    path = tmp_path / "odom.csv"
    path.write_text("stamp,x,mode\n3000000,3,a\n12000000,12,b\n18000000,18,c\n41000000,41,d\n")
    df = clean_csv(path, epoch={"stamp": "ns"}, time_column="stamp", resample="10ms")
    assert df["stamp"].dt.epoch("ms").to_list() == [10, 20, 30, 40]
    assert df["x"].to_list() == pytest.approx([10.0, 20.0, 30.0, 40.0])
    assert df["mode"].to_list() == ["a", "c", "c", "c"]
    mean = clean_csv(path, epoch={"stamp": "ns"}, time_column="stamp", resample="10ms", resample_method="mean")
    assert mean["x"].to_list() == [3.0, 15.0, None, None, 41.0]


def test_time_weighted_interpolation():
    t = [datetime(2024, 1, 1, 0, 0, s) for s in (0, 1, 3, 4)]
    out = clean_table(pl.DataFrame({"t": t, "v": [0.0, None, None, 4.0]}), time_column="t", impute="interpolate")
    assert out["v"].to_list() == [0.0, 1.0, 3.0, 4.0]


def test_sensor_option_errors(tmp_path):
    path = tmp_path / "x.csv"
    path.write_text("t,v\n1,2\n")
    with pytest.raises(RuntimeError, match="resample needs time_column"):
        clean_csv(path, resample="1s")
    with pytest.raises(RuntimeError, match="invalid period"):
        clean_csv(path, time_column="t", resample="fast")
    with pytest.raises(RuntimeError, match="not available when streaming"):
        list(iter_clean_csv(path, outliers="mad"))
