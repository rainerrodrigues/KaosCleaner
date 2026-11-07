"""Package metadata checks that PyPI enforces only at upload time."""
import tomllib
from pathlib import Path

import pytest

PYPROJECT = Path(__file__).resolve().parent.parent / "pyproject.toml"


def test_classifiers_are_valid():
    """PyPI rejects the upload (400) for any classifier outside its official list."""
    trove = pytest.importorskip("trove_classifiers")
    classifiers = tomllib.loads(PYPROJECT.read_text())["project"]["classifiers"]
    invalid = [c for c in classifiers if c not in trove.classifiers]
    assert not invalid, f"not valid PyPI classifiers: {invalid}"
