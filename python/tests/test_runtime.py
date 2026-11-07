"""Tests for finding, unpacking and loading the engine (kaos_cleaner._runtime)."""
import os

import kaos_cleaner
from kaos_cleaner import _runtime


def test_old_runtimes_are_pruned(tmp_path):
    keep = tmp_path / "0.1.3-100"
    old = tmp_path / "0.1.2-90"
    unrelated = tmp_path / "notes"
    unpacking = tmp_path / ".unpack-abc"  # another process mid-unpack
    for d in (keep, old, unrelated, unpacking):
        d.mkdir()

    _runtime._prune_old_runtimes(keep)

    assert keep.exists() and unrelated.exists() and unpacking.exists()
    assert not old.exists()


def test_unimported_results_are_released(valid_csv):
    """If importing into pyarrow fails, the engine's buffers must still be freed."""
    from pyarrow.cffi import ffi

    c_schema = ffi.new("struct ArrowSchema*")
    c_array = ffi.new("struct ArrowArray*")
    with _runtime.lock:
        lib = _runtime.load()
        status = lib.process_dataset_with_options(os.fsencode(valid_csv), b"",
                                                  int(ffi.cast("uintptr_t", c_schema)),
                                                  int(ffi.cast("uintptr_t", c_array)))
        kaos_cleaner._emit_logs(lib)
    assert status == 0 and c_array.release != ffi.NULL

    kaos_cleaner._release(c_array, c_schema)

    assert c_array.release == ffi.NULL and c_schema.release == ffi.NULL
