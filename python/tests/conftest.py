"""Fixtures for the kaos_cleaner bridge tests.

Tests run against an installed kaos-cleaner wheel when there is one (CI), and
otherwise against python/kaos_cleaner plus kaos_binaries/ in this checkout.
Test data is generated per test in tmp_path.
"""
import os
import random
import sys

import pytest

try:
    import kaos_cleaner  # noqa: F401
except ImportError:
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


@pytest.fixture
def valid_csv(tmp_path):
    """10,000 well-formed rows."""
    path = tmp_path / "valid_data.csv"
    with open(path, "w") as f:
        f.write("id,sensor_readings,timestamp\n")
        for i in range(10_000):
            f.write(f"{i},{i * 0.5},2026-11-07T11:20:00\n")
    return str(path)


@pytest.fixture
def messy_csv(tmp_path):
    """Padded headers and cells, missing markers, a duplicate and an empty row."""
    path = tmp_path / "messy.csv"
    path.write_text(
        " Customer ID ,Full Name,Spend (USD),Active\n"
        "1,  Alice ,12.5,true\n"
        "2,Bob,NA,false\n"
        "2,Bob,NA,false\n"
        ",,,\n"
        "3,N/A,null,\n"
    )
    return str(path)


def _hostile_inputs():
    rng = random.Random(7)
    wide_header = ",".join(f"c{i}" for i in range(1000))
    wide_row = ",".join(str(i) for i in range(1000))
    return {
        "ragged_rows": b"id,sensor_readings\n1,45.5\n2,NOT_A_FLOAT\n3,,,\n",
        "empty_file": b"",
        "header_only": b"a,b,c\n",
        "invalid_utf8": b"name,v\n\xff\xfebad,1\nok,2\n",
        "random_bytes": bytes(rng.getrandbits(8) for _ in range(5000)),
        "unterminated_quote": b'"a,b\n"unterminated,1\n',
        "thousand_columns": f"{wide_header}\n{wide_row}\n".encode(),
        "one_megabyte_cell": b"id,text\n1," + b"x" * 2**20 + b"\n",
    }


HOSTILE_INPUTS = sorted(_hostile_inputs())


@pytest.fixture(params=HOSTILE_INPUTS)
def hostile_csv(request, tmp_path):
    path = tmp_path / f"{request.param}.csv"
    path.write_bytes(_hostile_inputs()[request.param])
    return request.param, str(path)
