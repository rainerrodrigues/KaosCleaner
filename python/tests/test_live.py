"""Tests for LiveCleaner: state kept between batches."""

import pandas as pd
import polars as pl
import pyarrow as pa
import pytest
from kaos_cleaner import LiveCleaner


def test_types_dedupe_ffill_and_rows_carry_over():
    with LiveCleaner(source_row=True, impute={"v": "ffill"}) as cleaner:
        b1 = cleaner.clean(pl.DataFrame({" ID ": [1, 2], "V": [1.5, None], "On": ["yes", "no"]}))
        assert b1.columns == ["source_row", "id", "v", "on"] and b1.schema["on"] == pl.Boolean
        b2 = cleaner.clean(pl.DataFrame({" ID ": [2, 3, 2], "V": [None, 4.0, None], "On": ["no", "maybe", "no"]}))
        assert b2["source_row"].to_list() == [4]
        assert b2["on"].to_list() == [None] and b2.schema["on"] == pl.Boolean  # same schema as batch 1
        b3 = cleaner.clean(pl.DataFrame({" ID ": [9], "V": [None], "On": ["yes"]}))
        assert b3["v"].to_list() == [4.0]


def test_same_kind_back():
    with LiveCleaner() as cleaner:
        assert isinstance(cleaner.clean(pa.record_batch({"a": [1]})), pa.RecordBatch)
        assert isinstance(cleaner.clean(pa.table({"a": [2]})), pa.Table)
        assert isinstance(cleaner.clean(pd.DataFrame({"a": [3]})), pd.DataFrame)


def test_errors_and_close():
    with pytest.raises(RuntimeError, match="needs the whole data"):
        LiveCleaner(impute="median")
    with pytest.raises(RuntimeError, match="not available in a live session"):
        LiveCleaner(outliers="mad")
    with pytest.raises(TypeError, match="apply to files only"):
        LiveCleaner(delimiter=";")
    cleaner = LiveCleaner()
    cleaner.clean(pl.DataFrame({"a": [1]}))
    with pytest.raises(RuntimeError, match="columns"):
        cleaner.clean(pl.DataFrame({"b": [1]}))
    cleaner.close()
    cleaner.close()
    with pytest.raises(RuntimeError, match="closed"):
        cleaner.clean(pl.DataFrame({"a": [1]}))
