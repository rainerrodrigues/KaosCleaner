"""Package kaos_binaries/ (from `julia build.jl`) into a platform wheel in dist/.

    python -m pip install build
    python scripts/build_wheel.py [--gzip]

The runtime is xz-compressed (~40% smaller than gzip, but takes minutes to
pack); --gzip packs in seconds for quick local test wheels.
"""

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BINARIES = ROOT / "kaos_binaries"
PACKAGE = ROOT / "python"
RUNTIME = PACKAGE / "kaos_cleaner" / "runtime"

sys.path.insert(0, str(PACKAGE))
from kaos_cleaner._runtime import library_relpath  # noqa: E402


def manylinux_tag():
    """manylinux tag for the newest glibc symbol version any bundled ELF file needs.

    PyPI rejects plain linux_* wheels. The Julia runtime brings its own
    libstdc++ etc., so glibc is the only system library it relies on.
    """
    newest = (2, 17)  # manylinux2014, the oldest tag pip still widely expects
    for path in BINARIES.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        with open(path, "rb") as f:
            if f.read(4) != b"\x7fELF":
                continue
        symbols = subprocess.run(["objdump", "-T", str(path)], capture_output=True, text=True, check=True).stdout
        for m in re.finditer(r"GLIBC_(\d+)\.(\d+)", symbols):
            newest = max(newest, (int(m[1]), int(m[2])))
    arch = platform.machine()
    if newest == (2, 17):
        return f"manylinux_2_17_{arch}.manylinux2014_{arch}"
    return f"manylinux_{newest[0]}_{newest[1]}_{arch}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--gzip", action="store_true", help="fast gzip packing instead of xz")
    args = parser.parse_args()

    library = BINARIES / library_relpath()
    if not library.exists():
        sys.exit(f"{library} not found; run `julia build.jl` first")

    # A tarball keeps the runtime's symlinks, which a wheel (zip) would duplicate
    shutil.rmtree(RUNTIME, ignore_errors=True)
    RUNTIME.mkdir(parents=True)
    if args.gzip:
        name, mode, options = "kaos_runtime.tar.gz", "w:gz", {"compresslevel": 6}
    else:
        name, mode, options = "kaos_runtime.tar.xz", "w:xz", {"preset": 6}
    with tarfile.open(RUNTIME / name, mode, **options) as tar:
        for child in sorted(BINARIES.iterdir()):
            tar.add(child, arcname=child.name)

    env = dict(os.environ)
    if sys.platform.startswith("linux"):
        env["KAOS_WHEEL_PLAT"] = manylinux_tag()

    # Wheels only: an sdist would make pip on other platforms install a
    # runtime built for the wrong OS.
    shutil.rmtree(PACKAGE / "build", ignore_errors=True)
    subprocess.run(
        [sys.executable, "-m", "build", "--wheel", "--outdir", str(ROOT / "dist"), str(PACKAGE)], check=True, env=env
    )


if __name__ == "__main__":
    main()
