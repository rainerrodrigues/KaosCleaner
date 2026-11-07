"""Python binding for libkaoscleaner, the compiled KaosCleaner Julia engine.

    from kaos_cleaner import clean_csv, process_dataset
    df = clean_csv("data.csv")            # -> polars.DataFrame
    table = process_dataset("data.csv")   # -> pyarrow.Table

The Julia runtime is looked up in this order:
1. $KAOSCLEANER_HOME, a kaos_binaries/ directory produced by build.jl;
2. kaos_binaries/ in the repository checkout this package lives in;
3. the runtime archive bundled in the wheel, unpacked once into a user cache
   directory (wheels are zip files and cannot hold the runtime's symlinks).
"""
import ctypes
import json
import os
import platform
import shutil
import sys
import tarfile
import tempfile
import threading
from pathlib import Path

__version__ = "0.1.0"
__all__ = ["clean_csv", "process_dataset"]

_PKG_DIR = Path(__file__).resolve().parent
_ARCHIVES = [_PKG_DIR / "runtime" / f"kaos_runtime.tar.{ext}" for ext in ("xz", "gz")]

_lib = None
_lock = threading.Lock()


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
    lib.process_dataset.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p]
    lib.process_dataset.restype = ctypes.c_int
    lib.kaos_last_error.argtypes = []
    lib.kaos_last_error.restype = ctypes.c_char_p

    # Boot the Julia runtime once, before any other call into the library.
    # kaos_init_julia (not init_julia) leaves this thread GC-safe, so calls and
    # Arrow release callbacks from other Python threads cannot deadlock.
    argv = (ctypes.c_char_p * 2)(b"kaoscleaner", None)
    lib.kaos_init_julia(1, argv)
    _lib = lib
    return lib


def process_dataset(path):
    """Load and clean a CSV file with KaosCleaner, returning a pyarrow Table."""
    import pyarrow as pa
    from pyarrow.cffi import ffi

    c_schema = ffi.new("struct ArrowSchema*")
    c_array = ffi.new("struct ArrowArray*")
    ptr_schema = int(ffi.cast("uintptr_t", c_schema))
    ptr_array = int(ffi.cast("uintptr_t", c_array))

    with _lock:
        lib = _load()
        if lib.process_dataset(os.fsencode(path), ptr_schema, ptr_array) != 0:
            raise RuntimeError(lib.kaos_last_error().decode("utf-8", errors="replace"))

    batch = pa.RecordBatch._import_from_c(ptr_array, ptr_schema)
    return pa.Table.from_batches([batch])


def clean_csv(path):
    """Load and clean a CSV file with KaosCleaner, returning a polars DataFrame."""
    import polars as pl

    return pl.from_arrow(process_dataset(path))
