"""Package kaos_binaries/ (from `julia build.jl`) into a platform wheel in dist/.

    python -m pip install build
    python scripts/build_wheel.py [--gzip]

The runtime is xz-compressed (~40% smaller than gzip, but takes minutes to
pack); --gzip packs in seconds for quick local test wheels.
"""
import argparse
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
from kaos_cleaner import _library_relpath  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--gzip", action="store_true", help="fast gzip packing instead of xz")
    args = parser.parse_args()

    library = BINARIES / _library_relpath()
    if not library.exists():
        sys.exit(f"{library} not found; run `julia build.jl` first")

    # A tarball keeps the runtime's symlinks, which a wheel (zip) would duplicate
    shutil.rmtree(RUNTIME, ignore_errors=True)
    RUNTIME.mkdir(parents=True)
    if args.gzip:
        archive = tarfile.open(RUNTIME / "kaos_runtime.tar.gz", "w:gz", compresslevel=6)
    else:
        archive = tarfile.open(RUNTIME / "kaos_runtime.tar.xz", "w:xz", preset=6)
    with archive as tar:
        for child in sorted(BINARIES.iterdir()):
            tar.add(child, arcname=child.name)

    shutil.rmtree(PACKAGE / "build", ignore_errors=True)
    subprocess.run([sys.executable, "-m", "build", "--wheel", "--outdir", str(ROOT / "dist"), str(PACKAGE)],
                   check=True)


if __name__ == "__main__":
    main()
