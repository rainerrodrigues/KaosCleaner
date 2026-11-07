"""Python binding for libkaoscleaner, the compiled KaosCleaner Julia engine.

    from kaos_cleaner import clean_csv, process_dataset
    df = clean_csv("data.csv")            # -> polars.DataFrame
    table = process_dataset("data.csv")   # -> pyarrow.Table

The Julia runtime is looked up in this order:
1. $KAOSCLEANER_HOME, a kaos_binaries/ directory produced by build.jl;
2. kaos_binaries/ in the repository checkout this package lives in;
3. the runtime archive bundled in the wheel, unpacked once into a user cache
   directory (wheels are zip files and cannot hold the runtime's symlinks).

CSV parsing uses one Julia thread per CPU core; set $KAOSCLEANER_THREADS
(e.g. "1" or "4") before the first call to change that.

The engine's messages (rows dropped, columns converted, values imputed, CSV
parse warnings) go to the standard `logging` logger "kaos_cleaner".
"""
from __future__ import annotations

import ctypes
import json
import logging
import os
import platform
import shutil
import sys
import tarfile
import tempfile
import threading
from pathlib import Path
from typing import TYPE_CHECKING, Any, Mapping, Sequence, Union

if TYPE_CHECKING:
    import polars
    import pyarrow

PathLike = Union[str, "os.PathLike[str]"]

__version__ = "0.1.2"
__all__ = ["clean_csv", "process_dataset", "iter_clean_csv", "clean_csv_to_parquet"]

_PKG_DIR = Path(__file__).resolve().parent
_ARCHIVES = [_PKG_DIR / "runtime" / f"kaos_runtime.tar.{ext}" for ext in ("xz", "gz")]

_lib = None
_lock = threading.Lock()

logger = logging.getLogger("kaos_cleaner")
logger.addHandler(logging.NullHandler())  # applications decide where logs go


def _library_relpath() -> Path:
    system = platform.system()
    if system == "Linux":
        return Path("lib") / "libkaoscleaner.so"
    if system == "Darwin":
        return Path("lib") / "libkaoscleaner.dylib"
    if system == "Windows":
        return Path("bin") / "libkaoscleaner.dll"
    raise OSError(f"Unsupported operating system: {system}")


def _cache_root() -> Path:
    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local"
    elif sys.platform == "darwin":
        base = Path.home() / "Library" / "Caches"
    else:
        base = os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache"
    return Path(base) / "kaos_cleaner"


# The marker file lists every unpacked file's size. Checking it on each load
# catches a runtime left truncated by a crash or power loss mid-unpack, which
# would otherwise make Julia die with a bus error while mapping its image.
_MARKER = ".complete"


def _runtime_intact(target: Path) -> bool:
    try:
        sizes = json.loads((target / _MARKER).read_text())
        return all(os.path.getsize(target / rel) == size for rel, size in sizes.items())
    except (OSError, ValueError):
        return False


def _fsync(path: Path):
    if sys.platform == "win32":  # fsync needs a writable handle there
        return
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _unpack_runtime(archive: Path) -> Path:
    target = _cache_root() / f"{__version__}-{archive.stat().st_size}"
    if _runtime_intact(target):
        return target
    shutil.rmtree(target, ignore_errors=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(dir=target.parent, prefix=".unpack-"))
    try:
        with tarfile.open(archive) as tar:
            if hasattr(tarfile, "data_filter"):
                tar.extractall(tmp, filter="data")
            else:
                tar.extractall(tmp)
            sizes = {m.name: m.size for m in tar.getmembers() if m.isfile()}
        # Flush the data before the marker, so the marker never outlives it
        for rel in sizes:
            _fsync(tmp / rel)
        (tmp / _MARKER).write_text(json.dumps(sizes))
        _fsync(tmp / _MARKER)
        try:
            os.replace(tmp, target)
        except OSError:
            if not _runtime_intact(target):  # lost a race to another process
                raise
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return target


def _runtime_dir() -> Path:
    home = os.environ.get("KAOSCLEANER_HOME")
    if home:
        return Path(home)
    checkout = _PKG_DIR.parent.parent
    if (checkout / "build.jl").exists() and (checkout / "kaos_binaries").exists():
        return checkout / "kaos_binaries"
    archive = next((a for a in _ARCHIVES if a.exists()), None)
    if archive is not None:
        return _unpack_runtime(archive)
    raise OSError("KaosCleaner runtime not found; set KAOSCLEANER_HOME to a kaos_binaries directory")


def _load():
    global _lib
    if _lib is not None:
        return _lib
    lib_path = _runtime_dir() / _library_relpath()
    if not lib_path.exists():
        raise OSError(f"{lib_path} does not exist; build it with `julia build.jl`")
    if sys.platform == "win32":
        os.add_dll_directory(str(lib_path.parent))  # the Julia DLLs sit next to it

    lib = ctypes.CDLL(str(lib_path), mode=ctypes.RTLD_GLOBAL)
    lib.kaos_init_julia.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_char_p)]
    lib.kaos_init_julia.restype = None
    lib.process_dataset_with_options.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p]
    lib.process_dataset_with_options.restype = ctypes.c_int
    lib.kaos_last_error.argtypes = []
    lib.kaos_last_error.restype = ctypes.c_char_p
    lib.kaos_take_logs.argtypes = []
    lib.kaos_take_logs.restype = ctypes.c_char_p
    lib.kaos_open_stream.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int64, ctypes.c_void_p]
    lib.kaos_open_stream.restype = ctypes.c_int

    # Boot the Julia runtime once, before any other call into the library.
    # kaos_init_julia (not init_julia) leaves this thread GC-safe, so calls and
    # Arrow release callbacks from other Python threads cannot deadlock.
    threads = os.environ.get("KAOSCLEANER_THREADS", "auto")
    argv = (ctypes.c_char_p * 3)(b"kaoscleaner", f"--threads={threads}".encode(), None)
    lib.kaos_init_julia(2, argv)
    _lib = lib
    return lib


def _emit_logs(lib):
    """Forward the engine's buffered log records to the "kaos_cleaner" logger."""
    for level, message in json.loads(lib.kaos_take_logs().decode("utf-8", errors="replace")):
        # Julia levels: Debug -1000, Info 0, Warn 1000, Error 2000
        py_level = (logging.DEBUG if level < 0 else logging.INFO if level < 1000
                    else logging.WARNING if level < 2000 else logging.ERROR)
        logger.log(py_level, message)


def _options_json(*, drop=None, keep=None, missing_values=None, rename=None, dedupe=None,
                  drop_empty_rows=None, infer_types=None, datetime_formats=None, impute=None):
    """The options as the engine's JSON; explicit keywords, so typos raise TypeError."""
    options = dict(drop=drop, keep=keep, missing_values=missing_values, rename=rename, dedupe=dedupe,
                   drop_empty_rows=drop_empty_rows, infer_types=infer_types,
                   datetime_formats=datetime_formats, impute=impute)
    return json.dumps({k: list(v) if isinstance(v, (tuple, set)) else v
                       for k, v in options.items() if v is not None})


def process_dataset(path: PathLike, *, drop: Sequence[str] | None = None,
                    keep: Sequence[str] | None = None, missing_values: Sequence[str] | None = None,
                    rename: bool | None = None, dedupe: bool | None = None,
                    drop_empty_rows: bool | None = None, infer_types: bool | None = None,
                    datetime_formats: Sequence[str] | None = None,
                    impute: str | Mapping[str, str] | None = None) -> pyarrow.Table:
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

    options = _options_json(drop=drop, keep=keep, missing_values=missing_values, rename=rename,
                            dedupe=dedupe, drop_empty_rows=drop_empty_rows, infer_types=infer_types,
                            datetime_formats=datetime_formats, impute=impute)
    c_schema = ffi.new("struct ArrowSchema*")
    c_array = ffi.new("struct ArrowArray*")
    ptr_schema = int(ffi.cast("uintptr_t", c_schema))
    ptr_array = int(ffi.cast("uintptr_t", c_array))

    with _lock:
        lib = _load()
        status = lib.process_dataset_with_options(os.fsencode(path), options.encode(), ptr_schema, ptr_array)
        _emit_logs(lib)
        if status != 0:
            raise RuntimeError(lib.kaos_last_error().decode("utf-8", errors="replace"))

    batch = pa.RecordBatch._import_from_c(ptr_array, ptr_schema)
    return pa.Table.from_batches([batch])


def clean_csv(path: PathLike, **options: Any) -> polars.DataFrame:
    """Load and clean a CSV file, returning a polars DataFrame.

    Takes the same keyword options as `process_dataset`.

    Example:
        >>> clean_csv("sales.csv", drop=["internal_id"], impute={"price": "median"})
    """
    import polars as pl

    return pl.from_arrow(process_dataset(path, **options))


DEFAULT_CHUNK_SIZE = 256 * 2**20


def iter_clean_csv(path: PathLike, *, chunk_size: int = DEFAULT_CHUNK_SIZE,
                   **options: Any) -> pyarrow.RecordBatchReader:
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
    with _lock:
        lib = _load()
        status = lib.kaos_open_stream(os.fsencode(path), options_json.encode(), int(chunk_size), ptr_stream)
        _emit_logs(lib)
        if status != 0:
            raise RuntimeError(lib.kaos_last_error().decode("utf-8", errors="replace"))
        source = pa.RecordBatchReader._import_from_c(ptr_stream)

    def batches():
        while True:
            with _lock:  # one engine call at a time; logs belong to this batch
                try:
                    batch = source.read_next_batch()
                except StopIteration:
                    return
                finally:
                    _emit_logs(lib)
            yield batch

    return pa.RecordBatchReader.from_batches(source.schema, batches())


def clean_csv_to_parquet(path: PathLike, out_path: PathLike, *, chunk_size: int = DEFAULT_CHUNK_SIZE,
                         **options: Any) -> int:
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
