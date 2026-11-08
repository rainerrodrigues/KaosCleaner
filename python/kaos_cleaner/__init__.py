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

import contextlib
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

__version__ = "0.6.0"
__all__ = [
    "clean_csv",
    "clean_file",
    "clean_table",
    "restore",
    "LiveCleaner",
    "process_dataset",
    "iter_clean_csv",
    "clean_csv_to_parquet",
]

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
    delimiter=None,
    decimal=None,
    thousands=None,
    comment=None,
    header=None,
    epoch=None,
    time_column=None,
    outliers=None,
    outlier_threshold=None,
    outlier_window=None,
    resample=None,
    resample_method=None,
    source_row=None,
    raw=None,
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
        delimiter=delimiter,
        decimal=decimal,
        thousands=thousands,
        comment=comment,
        header=header,
        epoch=epoch,
        time_column=time_column,
        outliers=outliers,
        outlier_threshold=outlier_threshold,
        outlier_window=outlier_window,
        resample=resample,
        resample_method=resample_method,
        source_row=source_row,
        raw=raw,
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
    delimiter: str | None = None,
    decimal: str | None = None,
    thousands: str | None = None,
    comment: str | None = None,
    header: int | None = None,
    epoch: Mapping[str, str] | None = None,
    time_column: str | None = None,
    outliers: str | Mapping[str, str] | None = None,
    outlier_threshold: float | None = None,
    outlier_window: int | None = None,
    resample: str | None = None,
    resample_method: str | None = None,
    source_row: bool | None = None,
) -> pyarrow.Table:
    """Load and clean a CSV file, returning a pyarrow Table.

    Reads any delimited text file (CSV, TSV, semicolon- or pipe-separated),
    also gzip-compressed (``data.csv.gz``).

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
            "zero", "interpolate" (numeric columns; "interpolate" fills gaps
            linearly by row position), "mode", "ffill", "bfill" (any column).
            Column names here are the cleaned (snake_case) ones.
        delimiter: Field separator, one character such as ``"\\t"``, ``";"``
            or ``"|"`` [detected from the file].
        decimal: Decimal mark in numbers, e.g. ``","`` for ``3,14`` ["."].
        thousands: Thousands separator inside numbers, e.g. ``"."`` together
            with ``decimal=","`` for ``1.234,50`` [none].
        comment: Skip lines starting with this text, e.g. ``"#"`` [none].
        header: Line number of the header row; lines above it are skipped.
            0 means the file has no header and columns are named
            ``column1``, ``column2``, ... [1].
        epoch: Numeric columns holding times since 1970, converted to
            nanosecond timestamps: ``{column: unit}`` with unit "s", "ms",
            "us" or "ns", e.g. ``{"stamp": "ns"}``. Cleaned column names.
        time_column: The column holding each row's time (cleaned name).
            With it, "interpolate" weights gaps by time instead of row
            position, and `resample` becomes available.
        outliers: Turn outliers in numeric columns into missing values (so
            `impute` can fill them): one method for all numeric columns or a
            ``{column: method}`` dict. Methods: "zscore", "iqr", "mad"
            (robust), "hampel" (rolling median; follows drifting signals).
        outlier_threshold: How far out a value must be; defaults per method:
            zscore 3, iqr 1.5, mad 3.5, hampel 3.
        outlier_window: Rows in the hampel window, odd and at least 3 [7].
        resample: Put the data on a fixed time grid with this period, e.g.
            ``"10ms"``, ``"1s"``, ``"5min"`` (units ns, us, ms, s, min, h).
            Needs `time_column`; grid times are multiples of the period.
        resample_method: "linear" (interpolate at grid times; latest value
            for non-numeric columns), "mean" or "last" (per period) ["linear"].
        source_row: Add a first column ``source_row`` holding each row's
            position among the file's data rows (1 = the first row after the
            header), so cleaned rows can be traced back with `restore`
            [False].

    Returns:
        pyarrow.Table: The cleaned data.

    Raises:
        RuntimeError: The file is missing or unreadable, or an option is
            invalid; the message is the engine's.
    """
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
        delimiter=delimiter,
        decimal=decimal,
        thousands=thousands,
        comment=comment,
        header=header,
        epoch=epoch,
        time_column=time_column,
        outliers=outliers,
        outlier_threshold=outlier_threshold,
        outlier_window=outlier_window,
        resample=resample,
        resample_method=resample_method,
        source_row=source_row,
    )
    return _run_file(path, options)


def _run_file(path: PathLike, options: str) -> pyarrow.Table:
    """Have the engine read and clean `path` with JSON `options`."""
    import pyarrow as pa
    from pyarrow.cffi import ffi

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


PARSER_OPTIONS = frozenset({"delimiter", "decimal", "thousands", "comment", "header"})


def _engine_type(arr: pyarrow.Array) -> pyarrow.Array:
    """Cast a column into a type the engine imports, keeping its values."""
    import pyarrow as pa
    import pyarrow.compute as pc

    t = arr.type
    if pa.types.is_dictionary(t):
        return _engine_type(arr.dictionary_decode())
    if pa.types.is_string_view(t):
        return pc.cast(arr, pa.large_string())
    if pa.types.is_timestamp(t) and t.tz is not None:
        return pc.cast(arr, pa.timestamp(t.unit))  # the same instants, as naive UTC
    if pa.types.is_decimal(t) or pa.types.is_float16(t):
        return pc.cast(arr, pa.float64())
    if pa.types.is_time(t) or pa.types.is_duration(t):
        return pc.cast(arr, pa.string())
    return arr


def _as_batch(data: Any) -> tuple[pyarrow.RecordBatch, str]:
    """The table as one record batch of engine types, and what kind it was."""
    import pyarrow as pa

    table, kind = _to_arrow(data, "clean_table")
    table = table.combine_chunks()
    columns = [_engine_type(col.chunk(0) if col.num_chunks else pa.array([], type=col.type)) for col in table.columns]
    return pa.RecordBatch.from_arrays(columns, names=table.column_names), kind


def _to_arrow(data: Any, caller: str) -> tuple[pyarrow.Table, str]:
    """A pyarrow/polars/pandas table as a pyarrow Table, and what kind it was."""
    import pyarrow as pa

    module = type(data).__module__.split(".")[0]
    if isinstance(data, pa.RecordBatch):
        kind, table = "batch", pa.Table.from_batches([data])
    elif isinstance(data, pa.Table):
        kind, table = "table", data
    elif module == "polars":
        kind, table = "polars", data.to_arrow()
    elif module == "pandas":
        kind, table = "pandas", pa.Table.from_pandas(data, preserve_index=False)
    else:
        raise TypeError(
            f"{caller} takes a pyarrow Table or RecordBatch, a polars DataFrame or a pandas DataFrame, "
            f"not {type(data).__name__}"
        )
    return table, kind


def _from_arrow(table: pyarrow.Table, kind: str) -> Any:
    """`table` converted back into the `kind` that `_to_arrow` reported."""
    import pyarrow as pa

    if kind == "polars":
        import polars as pl

        return pl.from_arrow(table)
    if kind == "pandas":
        return table.to_pandas()
    if kind == "batch":
        batches = table.combine_chunks().to_batches()
        if batches:
            return batches[0]
        return pa.RecordBatch.from_arrays([pa.array([], f.type) for f in table.schema], schema=table.schema)
    return table


def clean_table(data: Any, **options: Any) -> Any:
    """Clean a table that is already in memory.

    Accepts a pyarrow Table or RecordBatch, a polars DataFrame or a pandas
    DataFrame, and returns the cleaned data as the same kind of object. The
    cleaning is the same as for files: renaming, type inference on text
    columns, missing values, deduplication and imputation.

    Types the engine does not read natively are converted first:
    dictionary/categorical columns to their values, time-zone-aware
    timestamps to UTC, decimals to float64, times and durations to text.
    Nested types (lists, structs) and binary columns are not supported.

    Args:
        data: The table to clean.
        **options: The keyword options of `process_dataset`, except the
            parsing options (`delimiter`, `decimal`, `thousands`, `comment`,
            `header`), which only apply to files.

    Returns:
        The cleaned table, of the same type as `data`.

    Raises:
        TypeError: `data` is not a supported table type, or a parsing option
            was given.
        RuntimeError: An option is invalid or a column type is unsupported;
            the message is the engine's.

    Example:
        >>> clean_table(pl.read_parquet("orders.parquet"), impute="median")
    """
    import pyarrow as pa
    from pyarrow.cffi import ffi

    parsing = PARSER_OPTIONS.intersection(options)
    if parsing:
        raise TypeError(f"clean_table does not take the file parsing options {sorted(parsing)}")
    options_json = _options_json(**options)
    batch, kind = _as_batch(data)

    in_schema, in_array = ffi.new("struct ArrowSchema*"), ffi.new("struct ArrowArray*")
    out_schema, out_array = ffi.new("struct ArrowSchema*"), ffi.new("struct ArrowArray*")
    ptr = lambda c: int(ffi.cast("uintptr_t", c))  # noqa: E731
    batch._export_to_c(ptr(in_array), ptr(in_schema))
    try:
        with _runtime.lock:
            lib = _runtime.load()
            status = lib.kaos_clean_arrow(
                ptr(in_schema), ptr(in_array), options_json.encode(), ptr(out_schema), ptr(out_array)
            )
            _emit_logs(lib)
            if status != 0:
                raise RuntimeError(lib.kaos_last_error().decode("utf-8", errors="replace"))
    finally:
        _release(in_array, in_schema)  # the engine releases them; this covers a failed call

    try:
        result = pa.RecordBatch._import_from_c(ptr(out_array), ptr(out_schema))
    except BaseException:
        _release(out_array, out_schema)
        raise

    if kind == "batch":
        return result
    return _from_arrow(pa.Table.from_batches([result]), kind)


TEXT_EXTENSIONS = {".csv": None, ".txt": None, ".dat": None, ".tsv": "\t", ".tab": "\t", ".psv": "|"}
EXCEL_EXTENSIONS = (".xlsx", ".xlsm", ".xls", ".ods")


def clean_file(path: PathLike, **options: Any) -> polars.DataFrame:
    """Load and clean a file of any supported format, returning a polars DataFrame.

    The format follows the file extension:

    - Delimited text, read by the engine: ``.csv``, ``.tsv``/``.tab`` (tab),
      ``.psv`` (pipe), ``.txt``, ``.dat``, each also gzip-compressed
      (``.csv.gz``). The delimiter is detected unless given.
    - Parquet (``.parquet``, ``.pq``) and Arrow IPC/Feather (``.arrow``,
      ``.feather``, ``.ipc``), read with pyarrow.
    - JSON Lines (``.jsonl``, ``.ndjson``) with pyarrow and JSON arrays of
      records (``.json``) with polars.
    - Excel and OpenDocument spreadsheets (``.xlsx``, ``.xlsm``, ``.xls``,
      ``.ods``) with polars, which needs the optional ``fastexcel`` package;
      the first sheet is read.

    Files that are not text are loaded into memory and cleaned with
    `clean_table`, so the parsing options do not apply to them.

    Args:
        path: The file to clean.
        **options: The keyword options of `process_dataset`.

    Returns:
        polars.DataFrame: The cleaned data.

    Raises:
        FileNotFoundError: The file does not exist.
        ValueError: The extension is not one listed above.
        ImportError: A spreadsheet was given and ``fastexcel`` is missing.
        RuntimeError: The engine could not clean the data; the message is
            the engine's.
    """
    import polars as pl

    path, ext = _file_type(path)
    if ext in TEXT_EXTENSIONS:
        return clean_csv(path, **_text_options(ext, options))
    _reject_parsing(options, "apply to delimited text files only")
    options = {k: v for k, v in options.items() if k not in PARSER_OPTIONS}
    data = _read_table(path, ext)
    df = clean_table(data, **options)
    if not isinstance(df, pl.DataFrame):
        df = pl.from_arrow(df)
    assert isinstance(df, pl.DataFrame)
    return df


def _file_type(path: PathLike) -> tuple[str, str]:
    """The path as a string and its format extension (".csv" for "x.CSV.gz")."""
    path = os.fspath(path)
    if not os.path.isfile(path):
        raise FileNotFoundError(f"file not found: {path}")
    name = path.lower()
    gz = name.endswith(".gz")
    ext = os.path.splitext(name[:-3] if gz else name)[1]
    if gz and ext not in TEXT_EXTENSIONS:
        raise ValueError(f"gzip compression is supported for delimited text only, not {ext} files")
    return path, ext


def _text_options(ext: str, options: dict[str, Any]) -> dict[str, Any]:
    """`options` with the delimiter the extension implies (.tsv, .psv) unless one is given."""
    if TEXT_EXTENSIONS[ext] is not None and options.get("delimiter") is None:
        return {**options, "delimiter": TEXT_EXTENSIONS[ext]}
    return options


def _reject_parsing(options: Mapping[str, Any], why: str) -> None:
    parsing = PARSER_OPTIONS.intersection(k for k, v in options.items() if v is not None)
    if parsing:
        raise TypeError(f"the parsing options {sorted(parsing)} {why}")


def _read_table(path: str, ext: str) -> Any:
    """Read a file that is not delimited text, as a pyarrow Table or polars DataFrame."""
    import polars as pl

    if ext in (".parquet", ".pq"):
        import pyarrow.parquet as pq

        return pq.read_table(path)
    if ext in (".arrow", ".feather", ".ipc"):
        import pyarrow.feather as feather

        return feather.read_table(path)
    if ext in (".jsonl", ".ndjson"):
        import pyarrow.json as pj

        return pj.read_json(path)
    if ext == ".json":
        return pl.read_json(path)
    if ext in EXCEL_EXTENSIONS:
        try:
            return pl.read_excel(path)
        except ModuleNotFoundError as e:
            raise ImportError(
                'reading spreadsheets needs the fastexcel package: pip install "kaos-cleaner[excel]"'
            ) from e
    supported = sorted(
        [*TEXT_EXTENSIONS, ".parquet", ".pq", ".arrow", ".feather", ".ipc", ".jsonl", ".ndjson", ".json"]
        + list(EXCEL_EXTENSIONS)
    )
    raise ValueError(f"unsupported file type {ext or '(no extension)'!r}; supported: {', '.join(supported)}")


def _source_rows(cleaned: Any) -> list[int]:
    """The `source_row` column of a cleaned pyarrow, polars or pandas table."""
    table, _ = _to_arrow(cleaned, "restore")
    if "source_row" not in table.column_names:
        raise ValueError("the cleaned data has no source_row column; clean it with source_row=True")
    rows = table.column("source_row").to_pylist()
    if any(r is None for r in rows):
        raise ValueError("source_row has missing values; restore needs every row's source position")
    return rows


def restore(cleaned: Any, source: Any, *, rows: str = "kept", **parsing: Any) -> Any:
    """Undo the cleaning: get the original, untouched rows back.

    Cleaning trims text, converts types, renames columns and drops rows, and
    none of that can be reversed from the cleaned values alone ("$1,250.00"
    and "1250" both become 1250). So clean with ``source_row=True``, which
    records where each row came from, and `restore` reads those rows from
    the source exactly as they were: original column names, every value as
    the text in the file, nothing treated as missing.

    Args:
        cleaned: The cleaned data (pyarrow, polars or pandas), with its
            ``source_row`` column. Ignored when ``rows="all"``.
        source: What was cleaned: a file path (any format `clean_file`
            reads), or the original pyarrow, polars or pandas table.
        rows: Which original rows to return: "kept" (the rows of `cleaned`,
            in its order), "dropped" (the rows cleaning removed as empty or
            duplicate, in file order) or "all" (the whole source).
        **parsing: The parsing options (`delimiter`, `decimal`, `thousands`,
            `comment`, `header`) the file was cleaned with, so rows are
            counted the same way. Text files only.

    Returns:
        A polars DataFrame for a file source; the same type as `source` for
        a table. Text files come back with every column as text.

    Raises:
        ValueError: `cleaned` has no usable ``source_row`` column, its
            positions do not fit the source, or `rows` is unknown.
        TypeError: Parsing options were given for a source that is not a
            delimited text file, or a type is unsupported.

    Example:
        >>> df = clean_csv("orders.csv", source_row=True)
        >>> original = restore(df, "orders.csv")            # the same rows, as in the file
        >>> removed = restore(df, "orders.csv", rows="dropped")
    """
    import pyarrow as pa
    import pyarrow.compute as pc

    if rows not in ("kept", "dropped", "all"):
        raise ValueError(f'rows must be "kept", "dropped" or "all", not {rows!r}')
    unknown = set(parsing) - PARSER_OPTIONS
    if unknown:
        raise TypeError(f"restore got unexpected keyword arguments {sorted(unknown)}")
    positions = None if rows == "all" else [r - 1 for r in _source_rows(cleaned)]

    if isinstance(source, (str, os.PathLike)):
        path, ext = _file_type(source)
        kind = "polars"
        if ext in TEXT_EXTENSIONS:
            original = _run_file(path, _options_json(raw=True, **_text_options(ext, parsing)))
        else:
            _reject_parsing(parsing, "apply to delimited text files only")
            original, _ = _to_arrow(_read_table(path, ext), "restore")
    else:
        _reject_parsing(parsing, "apply to files only")
        original, kind = _to_arrow(source, "restore")

    if positions is not None:
        n = original.num_rows
        if any(not 0 <= p < n for p in positions):
            raise ValueError(
                f"source_row values outside 1..{n}: was the data cleaned from another source, "
                "or with other parsing options?"
            )
        if rows == "kept":
            original = original.take(pa.array(positions, pa.int64()))
        else:
            kept = pc.is_in(pa.array(range(n), pa.int64()), value_set=pa.array(positions, pa.int64()))
            original = original.filter(pc.invert(kept))
    return _from_arrow(original, kind)


class LiveCleaner:
    """Clean a live feed batch by batch, with state carried between batches.

    For data that arrives in pieces (a sensor topic, a message queue, a
    polling loop) and is cleaned as it comes. Unlike separate `clean_table`
    calls, a session remembers:

    - the column types the first batch decided, so every batch comes back
      with the same schema (values that do not fit become missing, with a
      warning on the "kaos_cleaner" logger);
    - every row seen, so ``dedupe`` drops repeats across batches;
    - the last value of each column, so ``impute="ffill"`` fills a gap at the
      start of a batch from the previous one;
    - the row count, so ``source_row`` numbers rows across the whole feed.

    Options are those of `clean_table`, except that ``impute`` is limited to
    "zero" and "ffill", and ``outliers`` and ``resample`` (which need all the
    data) are not available. Every output column is nullable.

    Example:
        >>> with LiveCleaner(impute="ffill", epoch={"stamp": "ns"}) as cleaner:
        ...     for msg_batch in feed:
        ...         publish(cleaner.clean(msg_batch))
    """

    def __init__(self, **options: Any) -> None:
        self._id = 0
        _reject_parsing(options, "apply to files only")
        options_json = _options_json(**options)
        with _runtime.lock:
            lib = _runtime.load()
            session = lib.kaos_session_open(options_json.encode())
            _emit_logs(lib)
            if session == 0:
                raise RuntimeError(lib.kaos_last_error().decode("utf-8", errors="replace"))
        self._id = session

    def clean(self, data: Any) -> Any:
        """Clean the next batch: a pyarrow Table or RecordBatch, or a polars or pandas DataFrame.

        Returns the cleaned batch as the same kind of object.
        """
        import pyarrow as pa
        from pyarrow.cffi import ffi

        if not self._id:
            raise RuntimeError("this LiveCleaner is closed")
        batch, kind = _as_batch(data)
        in_schema, in_array = ffi.new("struct ArrowSchema*"), ffi.new("struct ArrowArray*")
        out_schema, out_array = ffi.new("struct ArrowSchema*"), ffi.new("struct ArrowArray*")
        ptr = lambda c: int(ffi.cast("uintptr_t", c))  # noqa: E731
        batch._export_to_c(ptr(in_array), ptr(in_schema))
        try:
            with _runtime.lock:
                lib = _runtime.load()
                status = lib.kaos_session_clean(
                    self._id, ptr(in_schema), ptr(in_array), ptr(out_schema), ptr(out_array)
                )
                _emit_logs(lib)
                if status != 0:
                    raise RuntimeError(lib.kaos_last_error().decode("utf-8", errors="replace"))
        finally:
            _release(in_array, in_schema)
        try:
            result = pa.RecordBatch._import_from_c(ptr(out_array), ptr(out_schema))
        except BaseException:
            _release(out_array, out_schema)
            raise
        if kind == "batch":
            return result
        return _from_arrow(pa.Table.from_batches([result]), kind)

    def close(self) -> None:
        """Free the session's state; further `clean` calls raise. Safe to call twice."""
        if self._id:
            with _runtime.lock:
                _runtime.load().kaos_session_close(self._id)
            self._id = 0

    def __enter__(self) -> LiveCleaner:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def __del__(self) -> None:
        if self._id:  # at interpreter shutdown the runtime may already be gone
            with contextlib.suppress(Exception):
                self.close()
