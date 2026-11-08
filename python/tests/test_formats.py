"""Tests for the parsing options, clean_table and clean_file."""

import gzip
from datetime import date, datetime, timezone
from decimal import Decimal

import polars as pl
import pyarrow as pa
import pyarrow.feather as feather
import pyarrow.parquet as pq
import pytest
from kaos_cleaner import clean_csv, clean_file, clean_table

MESSY = {
    " Customer ID ": [1, 2, 2, None],
    "Spend (USD)": ["$1,200.50", "NA", "NA", None],
    "Active": ["yes", "no", "no", None],
}
CLEAN = {"customer_id": [1, 2], "spend_usd": [1200.5, None], "active": [True, False]}


# --- parsing options ---------------------------------------------------------


def test_european_dates_are_not_numbers(tmp_path):
    path = tmp_path / "umsatz.csv"
    path.write_text("Datum;Umsatz\n02.01.2024;1.234,50\n03.01.2024;980,00\n")
    df = clean_csv(path, delimiter=";", decimal=",", thousands=".")
    assert df["datum"].to_list() == [date(2024, 1, 2), date(2024, 1, 3)]
    assert df["umsatz"].to_list() == [1234.5, 980.0]


def test_european_file(tmp_path):
    path = tmp_path / "umsatz.csv"
    path.write_text("# exported 2024\nName;Betrag\nA;1.234,50\nB;7,25\n")
    df = clean_csv(path, delimiter=";", decimal=",", thousands=".", comment="#")
    assert df.to_dict(as_series=False) == {"name": ["A", "B"], "betrag": [1234.5, 7.25]}


def test_header_line_and_no_header(tmp_path):
    path = tmp_path / "report.csv"
    path.write_text("Quarterly report\n\nid,value\n1,2\n")
    assert clean_csv(path, header=3).columns == ["id", "value"]
    plain = tmp_path / "plain.csv"
    plain.write_text("1,a\n2,b\n")
    assert clean_csv(plain, header=0).columns == ["column1", "column2"]


@pytest.mark.parametrize(
    "options, message",
    [
        ({"delimiter": ";;"}, "single character"),
        ({"decimal": ",", "delimiter": ","}, "different characters"),
        ({"header": -1}, "line number"),
        ({"comment": ""}, "non-empty"),
    ],
)
def test_invalid_parsing_options(tmp_path, options, message):
    path = tmp_path / "x.csv"
    path.write_text("a\n1\n")
    with pytest.raises(RuntimeError, match=message):
        clean_csv(path, **options)


# --- clean_table -------------------------------------------------------------


def test_clean_table_pyarrow():
    table = pa.table(MESSY)
    out = clean_table(table)
    assert isinstance(out, pa.Table)
    assert out.to_pydict() == CLEAN


def test_clean_table_record_batch_and_slices():
    batch = pa.RecordBatch.from_pydict({"n": list(range(10)), "s": [f"v{i}" for i in range(10)]})
    out = clean_table(batch.slice(3, 4))
    assert isinstance(out, pa.RecordBatch)
    assert out.to_pydict() == {"n": [3, 4, 5, 6], "s": ["v3", "v4", "v5", "v6"]}
    chunked = pa.concat_tables([pa.table({"n": [1, 2]}), pa.table({"n": [3]})])
    assert clean_table(chunked).column("n").to_pylist() == [1, 2, 3]


def test_clean_table_polars():
    df = pl.DataFrame(MESSY).with_columns(pl.col("Active").cast(pl.Categorical))
    out = clean_table(df)
    assert isinstance(out, pl.DataFrame)
    assert out.to_dict(as_series=False) == CLEAN


def test_clean_table_pandas():
    pd = pytest.importorskip("pandas")
    out = clean_table(pd.DataFrame(MESSY))
    assert isinstance(out, pd.DataFrame)
    assert out["customer_id"].tolist() == [1, 2]
    assert out["active"].tolist() == [True, False]


def test_clean_table_converts_types():
    table = pa.table(
        {
            "when": pa.array([datetime(2024, 1, 1, 12, tzinfo=timezone.utc)], pa.timestamp("us", tz="Europe/Paris")),
            "price": pa.array([Decimal("1.25")], pa.decimal128(5, 2)),
            "day": pa.array([date(2024, 1, 2)], pa.date64()),
            "label": pa.array(["a"]).dictionary_encode(),
            "small": pa.array([1], pa.int8()),
            "nothing": pa.array([None], pa.null()),
        }
    )
    out = clean_table(table, rename=False).to_pydict()
    assert out["when"] == [datetime(2024, 1, 1, 12)]  # UTC, naive
    assert out["price"] == [1.25]
    assert out["day"] == [date(2024, 1, 2)]
    assert out["label"] == ["a"]
    assert out["small"] == [1]
    assert out["nothing"] == [None]


def test_clean_table_options_and_empty():
    out = clean_table(pa.table({"id": [1, 2, 3], "x": [1.0, None, 3.0]}), impute="mean")
    assert out.column("x").to_pylist() == [1.0, 2.0, 3.0]
    empty = clean_table(pa.table({"x": pa.array([], pa.int64())}))
    assert empty.num_rows == 0


def test_clean_table_errors():
    with pytest.raises(TypeError, match="parsing options"):
        clean_table(pa.table({"x": [1]}), delimiter=";")
    with pytest.raises(TypeError, match="pyarrow Table"):
        clean_table([1, 2, 3])
    with pytest.raises(RuntimeError, match="unsupported Arrow format"):
        clean_table(pa.table({"x": [[1, 2]]}))
    with pytest.raises(RuntimeError, match="unknown impute strategy"):
        clean_table(pa.table({"x": [1]}), impute="magic")


# --- clean_file --------------------------------------------------------------


def test_clean_file_text_formats(tmp_path):
    (tmp_path / "a.tsv").write_text("Name\tScore\nA\t1,5\nB\t2\n")
    assert clean_file(tmp_path / "a.tsv").columns == ["name", "score"]
    (tmp_path / "a.psv").write_text("Name|Score\nA|1\n")
    assert clean_file(tmp_path / "a.psv").columns == ["name", "score"]
    with gzip.open(tmp_path / "a.tsv.gz", "wt") as f:
        f.write("Name\tScore\nA\t1\n")
    assert clean_file(tmp_path / "a.tsv.gz").to_dict(as_series=False) == {"name": ["A"], "score": [1]}
    (tmp_path / "a.txt").write_text("a;b\n1;2\n")
    assert clean_file(tmp_path / "a.txt", delimiter=";").columns == ["a", "b"]


@pytest.mark.parametrize("ext", ["parquet", "feather", "arrow", "jsonl", "json"])
def test_clean_file_binary_and_json(tmp_path, ext):
    path = tmp_path / f"data.{ext}"
    table = pa.table(MESSY)
    if ext == "parquet":
        pq.write_table(table, path)
    elif ext in ("feather", "arrow"):
        feather.write_feather(table, path)
    elif ext == "jsonl":
        pl.from_arrow(table).write_ndjson(path)
    else:
        pl.from_arrow(table).write_json(path)
    df = clean_file(path)
    assert isinstance(df, pl.DataFrame)
    assert df.to_dict(as_series=False) == CLEAN


def test_clean_file_excel(tmp_path):
    pytest.importorskip("fastexcel")
    pytest.importorskip("xlsxwriter")
    path = tmp_path / "data.xlsx"
    pl.DataFrame(MESSY).write_excel(path)
    assert clean_file(path).to_dict(as_series=False) == CLEAN


def test_clean_file_errors(tmp_path):
    with pytest.raises(FileNotFoundError):
        clean_file(tmp_path / "missing.csv")
    (tmp_path / "x.docx").write_text("")
    with pytest.raises(ValueError, match="unsupported file type"):
        clean_file(tmp_path / "x.docx")
    pq.write_table(pa.table({"a": [1]}), tmp_path / "x.parquet")
    with pytest.raises(TypeError, match="delimited text"):
        clean_file(tmp_path / "x.parquet", delimiter=";")
