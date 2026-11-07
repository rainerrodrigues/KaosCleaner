"""Tests for the Python <-> Julia bridge.

A bad pointer at the C boundary segfaults the whole interpreter, and a
threading bug deadlocks it, so the hostile-input and thread tests run in a
child process with a timeout: a crash or hang then shows up as one failed
test with the child's fault trace, instead of killing or stalling pytest.
"""
import json
import os
import subprocess
import sys
from datetime import datetime

import polars as pl
import pyarrow as pa
import pytest

import kaos_cleaner
from kaos_cleaner import clean_csv, process_dataset


def test_data_integrity(valid_csv):
    df = clean_csv(valid_csv)

    assert isinstance(df, pl.DataFrame)
    assert df.shape == (10_000, 3)
    assert df.columns == ["id", "sensor_readings", "timestamp"]
    assert df.schema == {"id": pl.Int64, "sensor_readings": pl.Float64, "timestamp": pl.Datetime("ms")}
    assert df["id"].to_list() == list(range(10_000))
    assert (df["sensor_readings"] == df["id"] * 0.5).all()
    assert df["timestamp"].unique().to_list() == [datetime(2026, 11, 7, 11, 20)]


def test_arrow_output_is_valid(valid_csv):
    table = process_dataset(valid_csv)

    assert isinstance(table, pa.Table)
    table.validate(full=True)
    assert not table.schema.field("id").nullable  # no missings -> exported non-nullable


def test_cleaning_rules(messy_csv):
    df = clean_csv(messy_csv)

    assert df.columns == ["customer_id", "full_name", "spend_usd", "active"]
    assert df.height == 3  # duplicate and all-empty rows dropped
    assert df["customer_id"].to_list() == [1, 2, 3]
    assert df["full_name"].to_list() == ["Alice", "Bob", None]
    assert df["spend_usd"].to_list() == [12.5, None, None]
    assert df["active"].to_list() == [True, False, None]


def test_missing_file_raises():
    with pytest.raises(RuntimeError, match="file not found"):
        clean_csv("does_not_exist.csv")


def test_directory_raises(tmp_path):
    with pytest.raises(RuntimeError, match="file not found"):
        clean_csv(str(tmp_path))


def test_error_does_not_poison_later_calls(valid_csv):
    with pytest.raises(RuntimeError):
        clean_csv("does_not_exist.csv")
    assert clean_csv(valid_csv).height == 10_000


_CHILD = """
import json, sys
import polars as pl
from kaos_cleaner import process_dataset
try:
    table = process_dataset(sys.argv[1])
    table.validate(full=True)
    df = pl.from_arrow(table)
    cells = [v for col in df.columns if df[col].dtype == pl.String for v in df[col].to_list() if v]
    print(json.dumps({"ok": True, "shape": list(df.shape), "cells": cells[:5]}))
except RuntimeError as e:
    print(json.dumps({"ok": False, "error": str(e)}))
"""


def _run_isolated(path):
    pkg_parent = os.path.dirname(os.path.dirname(os.path.abspath(kaos_cleaner.__file__)))
    env = dict(os.environ, PYTHONPATH=pkg_parent)
    return subprocess.run([sys.executable, "-X", "faulthandler", "-c", _CHILD, path],
                          capture_output=True, text=True, env=env, timeout=300)


def test_hostile_input_never_crashes(hostile_csv):
    """Malformed files must come back as a valid table or a RuntimeError."""
    name, path = hostile_csv
    child = _run_isolated(path)

    assert child.returncode == 0, f"{name}: child died ({child.returncode})\n{child.stderr[-3000:]}"
    result = json.loads(child.stdout.strip().splitlines()[-1])
    if name == "invalid_utf8":
        # each invalid byte becomes U+FFFD instead of being passed through
        assert result["ok"] and any("�bad" in cell for cell in result["cells"])


def test_tables_survive_later_calls(valid_csv, messy_csv):
    """Exported buffers must stay valid until their table is dropped."""
    held = [process_dataset(valid_csv), process_dataset(messy_csv)]
    for _ in range(20):
        process_dataset(valid_csv)

    held[0].validate(full=True)
    held[1].validate(full=True)
    assert held[0].column("id").to_pylist() == list(range(10_000))
    assert held[1].column("full_name").to_pylist() == ["Alice", "Bob", None]


_THREADS_CHILD = """
import sys
from concurrent.futures import ThreadPoolExecutor
from kaos_cleaner import clean_csv, process_dataset

valid, messy = sys.argv[1], sys.argv[2]
clean_csv(valid)  # initialize the runtime on the main thread, like most programs
with ThreadPoolExecutor(max_workers=8) as pool:
    heights = list(pool.map(lambda p: clean_csv(p).height, [valid, messy] * 16))
    assert heights == [10_000, 3] * 16, heights
    # Tables created here but freed on worker threads: the Arrow release
    # callbacks then run on threads Julia has never seen.
    tables = [process_dataset(valid) for _ in range(8)]
    list(pool.map(lambda t: t.num_rows, tables))
    for f in [pool.submit(tables.pop) for _ in range(8)]:
        f.result()
print("ok")
"""


def test_concurrent_calls(valid_csv, messy_csv):
    """Calls and releases from many threads must not deadlock the runtime.

    Runs in a child process with a timeout: a deadlock then fails this test
    instead of hanging the whole suite.
    """
    pkg_parent = os.path.dirname(os.path.dirname(os.path.abspath(kaos_cleaner.__file__)))
    try:
        child = subprocess.run([sys.executable, "-X", "faulthandler", "-c", _THREADS_CHILD, valid_csv, messy_csv],
                               capture_output=True, text=True, timeout=180,
                               env=dict(os.environ, PYTHONPATH=pkg_parent))
    except subprocess.TimeoutExpired:
        pytest.fail("threads deadlocked: no result within 180s")
    assert child.returncode == 0 and child.stdout.strip() == "ok", child.stderr[-3000:]


def _rss_mb():
    with open("/proc/self/status") as f:
        for line in f:
            if line.startswith("VmRSS:"):
                return int(line.split()[1]) / 1024
    raise RuntimeError("VmRSS not found")


@pytest.mark.skipif(not sys.platform.startswith("linux"), reason="reads /proc")
def test_memory_stays_flat(valid_csv):
    """Repeated calls must not grow memory: release callbacks free each table."""
    for _ in range(20):  # warm up: runtime load, JIT, allocator pools
        clean_csv(valid_csv)
    baseline = _rss_mb()

    for _ in range(300):
        df = clean_csv(valid_csv)
        assert df.height == 10_000
        del df  # last reference gone: Arrow release callbacks fire now

    growth = _rss_mb() - baseline
    assert growth < 50, f"RSS grew by {growth:.1f} MB over 300 calls"


# --- options, logging and streaming -----------------------------------------

def test_options_reach_the_engine(messy_csv):
    df = clean_csv(messy_csv, drop=["Customer ID"], impute={"spend_usd": "zero"}, dedupe=False)

    assert df.columns == ["full_name", "spend_usd", "active"]
    # duplicate Bob kept; the all-empty row and, without its id, row 3 are dropped
    assert df["full_name"].to_list() == ["Alice", "Bob", "Bob"]
    assert df["spend_usd"].null_count() == 0


def test_type_inference_from_python(tmp_path):
    path = tmp_path / "typed.csv"
    path.write_text("Paid,Amount,Day\nYes,\"$1,200.50\",13/01/2024\nno,€3,02/02/2024\n")
    df = clean_csv(str(path))

    assert df.schema == {"paid": pl.Boolean, "amount": pl.Float64, "day": pl.Date}


def test_option_typo_is_a_type_error(valid_csv):
    with pytest.raises(TypeError):
        clean_csv(valid_csv, dorp=["id"])
    with pytest.raises(TypeError):
        kaos_cleaner.iter_clean_csv(valid_csv, dorp=["id"])


def test_invalid_option_value_raises(valid_csv):
    with pytest.raises(RuntimeError, match="unknown impute strategy"):
        clean_csv(valid_csv, impute="avg")
    with pytest.raises(RuntimeError, match="no column named"):
        clean_csv(valid_csv, drop=["nope"])


def test_engine_logs_reach_python_logging(messy_csv, caplog):
    with caplog.at_level("INFO", logger="kaos_cleaner"):
        clean_csv(messy_csv)
    messages = [r.getMessage() for r in caplog.records if r.name == "kaos_cleaner"]
    assert "Dropped 1 empty row" in messages
    assert "Dropped 1 duplicate row" in messages


def test_streaming_matches_in_memory(valid_csv):
    reader = kaos_cleaner.iter_clean_csv(valid_csv, chunk_size=16 * 1024)
    batches = list(reader)

    assert len(batches) > 1  # really chunked
    streamed = pl.from_arrow(pa.Table.from_batches(batches))
    assert streamed.equals(clean_csv(valid_csv))


def test_streaming_to_parquet(valid_csv, tmp_path):
    out = tmp_path / "out.parquet"
    rows = kaos_cleaner.clean_csv_to_parquet(valid_csv, str(out), chunk_size=16 * 1024)

    assert rows == 10_000
    assert pl.read_parquet(out)["id"].to_list() == list(range(10_000))


def test_streaming_with_default_chunk_size(valid_csv, tmp_path):
    """The whole file fits one default-sized chunk: must work, not fail to split."""
    out = tmp_path / "default.parquet"
    assert kaos_cleaner.clean_csv_to_parquet(valid_csv, str(out)) == 10_000
    assert sum(b.num_rows for b in kaos_cleaner.iter_clean_csv(valid_csv)) == 10_000


def test_streaming_counts_values_that_do_not_fit(tmp_path, caplog):
    """Values after the 20,000-row sample that misfit become null, all counted."""
    path = tmp_path / "misfit.csv"
    rows = "".join(f"{i if i <= 20_000 else f'{i}.5'},x{i}\n" for i in range(1, 20_501))
    path.write_text("n,label\n" + rows)
    with caplog.at_level("WARNING", logger="kaos_cleaner"):
        table = pa.Table.from_batches(list(kaos_cleaner.iter_clean_csv(str(path))))

    assert table.num_rows == 20_500
    assert table.column("n").null_count == 500
    assert any("500 values in `n` did not fit Int64" in r.getMessage() for r in caplog.records)


def test_streaming_rejects_whole_file_imputation(valid_csv):
    with pytest.raises(RuntimeError, match="needs the whole file"):
        kaos_cleaner.iter_clean_csv(valid_csv, impute="median")


def test_abandoned_stream_is_released(valid_csv):
    reader = kaos_cleaner.iter_clean_csv(valid_csv, chunk_size=16 * 1024)
    next(iter(reader))
    del reader  # dropping a half-read stream must free it without crashing
    assert clean_csv(valid_csv).height == 10_000
