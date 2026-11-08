"""Python binding for libkaoscleaner, the compiled KaosCleaner Julia engine.

    from kaos_cleaner import clean_csv, process_dataset
    df = clean_csv("data.csv")            # -> polars.DataFrame
    table = process_dataset("data.csv")   # -> pyarrow.Table

The engine ships inside the wheel and is unpacked into a user cache directory
on first use (see `_runtime`); set $KAOSCLEANER_HOME to a kaos_binaries/
directory to use another build.

CSV parsing uses one Julia thread per CPU core; set $KAOSCLEANER_THREADS
(e.g. "1" or "4") before the first call to change that.

The engine's messages (rows dropped, columns converted, values imputed, CSV
parse warnings) go to the standard `logging` logger "kaos_cleaner".
"""

from __future__ import annotations

import json
import logging
import os
from collections.abc import Mapping, Sequence
from typing import TYPE_CHECKING, Any, Union

from . import _runtime

if TYPE_CHECKING:
    import polars
    import pyarrow

PathLike = Union[str, "os.PathLike[str]"]

__version__ = "0.1.4"
__all__ = ["clean_csv", "process_dataset", "iter_clean_csv", "clean_csv_to_parquet"]

logger = logging.getLogger("kaos_cleaner")
logger.addHandler(logging.NullHandler())  # applications decide where logs go


def _emit_logs(lib):
    """Forward the engine's buffered log records to the "kaos_cleaner" logger."""
    for level, message in json.loads(lib.kaos_take_logs().decode("utf-8", errors="replace")):
        logger.log(_python_level(level), message)


def _python_level(julia_level: int) -> int:
    """Julia's log levels (Debug -1000, Info 0, Warn 1000, Error 2000) as Python's."""
    if julia_level < 0:
        return logging.DEBUG
    if julia_level < 1000:
        return logging.INFO
    if julia_level < 2000:
        return logging.WARNING
    return logging.ERROR


def _options_json(
    *,
    drop=None,
    keep=None,
    missing_values=None,
    rename=None,
    dedupe=None,
    drop_empty_rows=None,
    infer_types=None,
    datetime_formats=None,
    impute=None,
):
    """The options as the engine's JSON; explicit keywords, so typos raise TypeError."""
    options = dict(
        drop=drop,
        keep=keep,
        missing_values=missing_values,
        rename=rename,
        dedupe=dedupe,
        drop_empty_rows=drop_empty_rows,
        infer_types=infer_types,
        datetime_formats=datetime_formats,
        impute=impute,
    )
    return json.dumps({k: list(v) if isinstance(v, (tuple, set)) else v for k, v in options.items() if v is not None})


def _release(*structs):
    """Call the release callback of exported Arrow structs nobody imported."""
    from pyarrow.cffi import ffi

    for c in structs:
        if c.release != ffi.NULL:
            c.release(c)


def process_dataset(
    path: PathLike,
    *,
    drop: Sequence[str] | None = None,
    keep: Sequence[str] | None = None,
    missing_values: Sequence[str] | None = None,
    rename: bool | None = None,
    dedupe: bool | None = None,
    drop_empty_rows: bool | None = None,
    infer_types: bool | None = None,
    datetime_formats: Sequence[str] | None = None,
    impute: str | Mapping[str, str] | None = None,
) -> pyarrow.Table:
    """Load and clean a CSV file, returning a pyarrow Table.

    Every option defaults to the engine's behaviour shown in brackets.

    Args:
        path: Path to a delimited text file.
        drop: Column names to remove, as in the file or in snake_case.
        keep: If given, only these columns are kept (same naming rules).
        missing_values: Extra cell values to treat as missing, on top of
            "", NA, N/A, NaN, null, None and their lowercase forms.
        rename: Rename columns to unique snake_case [True].
        dedupe: Drop rows that repeat an earlier row [True].
        drop_empty_rows: Drop rows where every value is missing [True].
        infer_types: Convert text columns holding booleans (yes/no, T/F, ...),
            dates in common formats or numbers with currency signs and
            thousands separators [True]. Dates that read differently day-first
            and month-first (01/02/2024) stay text unless `datetime_formats`
            says which one applies.
        datetime_formats: Date formats to use, in Julia `DateFormat` syntax,
            e.g. ``["dd/mm/yyyy", "dd/mm/yyyy HH:MM"]``.
        impute: Fill missing values. One strategy for all suitable columns, or
            a ``{column: strategy}`` dict. Strategies: "mean", "median",
            "zero" (numeric columns), "mode", "ffill", "bfill" (any column).
            Column names here are the cleaned (snake_case) ones.

    Returns:
        pyarrow.Table: The cleaned data.

    Raises:
        RuntimeError: The file is missing or unreadable, or an option is
            invalid; the message is the engine's.
    """
    import pyarrow as pa
    from pyarrow.cffi import ffi

    options = _options_json(
        drop=drop,
        keep=keep,
        missing_values=missing_values,
        rename=rename,
        dedupe=dedupe,
        drop_empty_rows=drop_empty_rows,
        infer_types=infer_types,
        datetime_formats=datetime_formats,
        impute=impute,
    )
    c_schema = ffi.new("struct ArrowSchema*")
    c_array = ffi.new("struct ArrowArray*")
    ptr_schema = int(ffi.cast("uintptr_t", c_schema))
    ptr_array = int(ffi.cast("uintptr_t", c_array))

    with _runtime.lock:
        lib = _runtime.load()
        status = lib.process_dataset_with_options(os.fsencode(path), options.encode(), ptr_schema, ptr_array)
        _emit_logs(lib)
        if status != 0:
            raise RuntimeError(lib.kaos_last_error().decode("utf-8", errors="replace"))

    try:
        batch = pa.RecordBatch._import_from_c(ptr_array, ptr_schema)
    except BaseException:
        _release(c_array, c_schema)  # otherwise the engine's buffers would leak
        raise
    return pa.Table.from_batches([batch])


def clean_csv(path: PathLike, **options: Any) -> polars.DataFrame:
    """Load and clean a CSV file, returning a polars DataFrame.

    Takes the same keyword options as `process_dataset`.

    Example:
        >>> clean_csv("sales.csv", drop=["internal_id"], impute={"price": "median"})
    """
    import polars as pl

    df = pl.from_arrow(process_dataset(path, **options))
    assert isinstance(df, pl.DataFrame)  # a Table always converts to a DataFrame
    return df


DEFAULT_CHUNK_SIZE = 256 * 2**20


def iter_clean_csv(
    path: PathLike, *, chunk_size: int = DEFAULT_CHUNK_SIZE, **options: Any
) -> pyarrow.RecordBatchReader:
    """Clean a CSV file of any size in chunks, as a stream of record batches.

    Memory use follows `chunk_size` rather than the file size, so files larger
    than RAM work. Batches are parsed and cleaned as you pull them.

    Streaming differs from `process_dataset` in three ways:

    - Column types and conversions are decided from the first 20,000 rows.
      Later values that do not fit (text in a numeric column, a date in
      another format) become missing, with a warning on the "kaos_cleaner"
      logger.
    - `dedupe` works across the whole file by remembering a 16-byte
      fingerprint per distinct row; pass ``dedupe=False`` for very large
      files where that memory matters.
    - `impute` supports only "zero" and "ffill", which need no look-ahead.

    Args:
        path: Path to a delimited text file.
        chunk_size: Approximate bytes of the file parsed per batch.
        **options: The keyword options of `process_dataset`.

    Returns:
        pyarrow.RecordBatchReader: Iterate it for `pyarrow.RecordBatch`
        objects, or pass it to anything that reads Arrow streams.

    Raises:
        RuntimeError: The file is missing or unreadable, an option is
            invalid, or a batch fails to parse.
    """
    import pyarrow as pa
    from pyarrow.cffi import ffi

    options_json = _options_json(**options)
    c_stream = ffi.new("struct ArrowArrayStream*")
    ptr_stream = int(ffi.cast("uintptr_t", c_stream))
    with _runtime.lock:
        lib = _runtime.load()
        status = lib.kaos_open_stream(os.fsencode(path), options_json.encode(), int(chunk_size), ptr_stream)
        _emit_logs(lib)
        if status != 0:
            raise RuntimeError(lib.kaos_last_error().decode("utf-8", errors="replace"))
        try:
            source = pa.RecordBatchReader._import_from_c(ptr_stream)
        except BaseException:
            _release(c_stream)
            raise

    def batches():
        while True:
            with _runtime.lock:  # one engine call at a time; logs belong to this batch
                try:
                    batch = source.read_next_batch()
                except StopIteration:
                    return
                except pa.ArrowException as e:  # the engine's message, from get_last_error
                    raise RuntimeError(str(e)) from e
                finally:
                    _emit_logs(lib)
            yield batch

    return pa.RecordBatchReader.from_batches(source.schema, batches())


def clean_csv_to_parquet(
    path: PathLike, out_path: PathLike, *, chunk_size: int = DEFAULT_CHUNK_SIZE, **options: Any
) -> int:
    """Clean a CSV file of any size into a Parquet file, chunk by chunk.

    Memory use follows `chunk_size` rather than the file size. Behaves like
    `iter_clean_csv`, including its streaming limits.

    Args:
        path: Path to a delimited text file.
        out_path: Parquet file to write (overwritten if it exists).
        chunk_size: Approximate bytes of the file parsed per batch.
        **options: The keyword options of `process_dataset`.

    Returns:
        int: The number of rows written.
    """
    import pyarrow.parquet as pq

    reader = iter_clean_csv(path, chunk_size=chunk_size, **options)
    rows = 0
    with pq.ParquetWriter(out_path, reader.schema) as writer:
        for batch in reader:
            writer.write_batch(batch)
            rows += batch.num_rows
    return rows
