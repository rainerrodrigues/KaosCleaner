"""Package kaos_binaries/ (from `julia build.jl`) into a platform wheel in dist/.

    python -m pip install build
    python scripts/build_wheel.py
"""
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
    library = BINARIES / _library_relpath()
    if not library.exists():
        sys.exit(f"{library} not found; run `julia build.jl` first")

    # A tarball keeps the runtime's symlinks, which a wheel (zip) would duplicate
    shutil.rmtree(RUNTIME, ignore_errors=True)
    RUNTIME.mkdir(parents=True)
    with tarfile.open(RUNTIME / "kaos_runtime.tar.gz", "w:gz", compresslevel=6) as tar:
        for child in sorted(BINARIES.iterdir()):
            tar.add(child, arcname=child.name)

    shutil.rmtree(PACKAGE / "build", ignore_errors=True)
    subprocess.run([sys.executable, "-m", "build", "--wheel", "--outdir", str(ROOT / "dist"), str(PACKAGE)],
                   check=True)


if __name__ == "__main__":
    main()
