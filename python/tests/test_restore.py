"""Tests for source_row and restore (undoing the cleaning)."""

import polars as pl
import pyarrow as pa
import pyarrow.parquet as pq
import pytest
from kaos_cleaner import clean_csv, clean_file, clean_table, iter_clean_csv, restore

MESSY = ' Customer ID ,Spend (USD),Active\n 1 ,"$1,250.00",yes\n 1 ,"$1,250.00",yes\n,,\n2,NA,no\n3, 7 ,Y\n'


@pytest.fixture
def messy(tmp_path):
    path = tmp_path / "orders.csv"
    path.write_text(MESSY)
    return path


def test_source_row(messy):
    df = clean_csv(messy, source_row=True)
    assert df.columns == ["source_row", "customer_id", "spend_usd", "active"]
    assert df["source_row"].to_list() == [1, 4, 5]  # row 2 duplicates row 1, row 3 is empty
    assert "source_row" not in clean_csv(messy).columns


def test_restore_kept_rows(messy):
    df = clean_csv(messy, source_row=True)
    original = restore(df, messy)
    assert original.columns == [" Customer ID ", "Spend (USD)", "Active"]
    assert original.to_dict(as_series=False) == {
        " Customer ID ": [" 1 ", "2", "3"],
        "Spend (USD)": ["$1,250.00", "NA", " 7 "],
        "Active": ["yes", "no", "Y"],
    }


def test_restore_follows_the_cleaned_order(messy):
    df = clean_csv(messy, source_row=True).sort("source_row", descending=True)
    assert restore(df, messy)[" Customer ID "].to_list() == ["3", "2", " 1 "]


def test_restore_dropped_and_all(messy):
    df = clean_csv(messy, source_row=True)
    dropped = restore(df, messy, rows="dropped")
    assert dropped.to_dict(as_series=False) == {
        " Customer ID ": [" 1 ", ""],
        "Spend (USD)": ["$1,250.00", ""],
        "Active": ["yes", ""],
    }
    assert restore(None, messy, rows="all").height == 5


def test_restore_with_parsing_options(tmp_path):
    path = tmp_path / "eu.txt"
    path.write_text("Report\nName;Betrag\nA;1.234,50\nA;1.234,50\nB;7,25\n")
    options = {"delimiter": ";", "decimal": ",", "thousands": ".", "header": 2}
    df = clean_csv(path, source_row=True, **options)
    assert df["betrag"].to_list() == [1234.5, 7.25]
    assert restore(df, path, **options)["Betrag"].to_list() == ["1.234,50", "7,25"]


def test_restore_tsv_via_clean_file(tmp_path):
    path = tmp_path / "x.tsv"
    path.write_text("A\tB\n x \t1\n x \t1\n")
    df = clean_file(path, source_row=True)
    assert restore(df, path, rows="all").to_dict(as_series=False) == {"A": [" x ", " x "], "B": ["1", "1"]}


def test_restore_streamed(tmp_path):
    path = tmp_path / "big.csv"
    ids = [0 if i % 10 == 9 else i for i in range(2000)]  # every 10th row repeats the first
    path.write_text("id,v\n" + "".join(f"{i},{i * 2}\n" for i in ids))
    batches = list(iter_clean_csv(path, chunk_size=4096, source_row=True))
    assert len(batches) > 1
    streamed = pl.from_arrow(pa.Table.from_batches(batches))
    kept = [i for i in range(2000) if i % 10 != 9]
    assert streamed["source_row"].to_list() == [i + 1 for i in kept]  # repeats dropped across chunks
    assert restore(streamed, path)["id"].to_list() == [str(i) for i in kept]


def test_restore_tables():
    source = pl.DataFrame({"name": [" a ", " a ", None, "b"], "n": ["1", "1", None, "2"]})
    df = clean_table(source, source_row=True)
    assert df["source_row"].to_list() == [1, 4]
    back = restore(df, source)
    assert isinstance(back, pl.DataFrame) and back.equals(source[[0, 3]])
    assert restore(df, source, rows="dropped").equals(source[[1, 2]])
    arrow = source.to_arrow()
    assert restore(clean_table(arrow, source_row=True), arrow).equals(arrow.take([0, 3]))


def test_restore_parquet(tmp_path):
    path = tmp_path / "x.parquet"
    pq.write_table(pa.table({"A": ["x", "x", "y"]}), path)
    df = clean_file(path, source_row=True)
    assert restore(df, path).to_dict(as_series=False) == {"A": ["x", "y"]}


def test_restore_errors(messy, tmp_path):
    with pytest.raises(ValueError, match="source_row=True"):
        restore(clean_csv(messy), messy)
    df = clean_csv(messy, source_row=True)
    with pytest.raises(ValueError, match="rows must be"):
        restore(df, messy, rows="some")
    short = tmp_path / "short.csv"
    short.write_text("a\n1\n")
    with pytest.raises(ValueError, match="outside 1..1"):
        restore(df, short)
    with pytest.raises(TypeError, match="apply to files only"):
        restore(df, df, delimiter=";")
    with pytest.raises(TypeError, match="unexpected keyword"):
        restore(df, messy, drop=["x"])
    with pytest.raises(RuntimeError, match="already has a column named `source_row`"):
        clean_table(pl.DataFrame({"source_row": [1]}), source_row=True)
