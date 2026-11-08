import os
import platform
import re

from setuptools import setup
from setuptools.command.bdist_wheel import bdist_wheel


class PlatformWheel(bdist_wheel):
    """The wheel bundles a native runtime: tag it for this OS/CPU, any Python 3."""

    def finalize_options(self):
        super().finalize_options()
        self.root_is_pure = False

    def get_tag(self):
        _, _, plat = super().get_tag()
        mac = re.fullmatch(r"macosx_(\d+)_(\d+)_(\w+)", plat)
        if mac:
            major, minor, arch = int(mac[1]), int(mac[2]), mac[3]
            # python.org builds report universal2, but the runtime is single-arch
            if arch == "universal2":
                arch = platform.machine()
            # Apple silicon starts at macOS 11; pip rejects e.g. macosx_10_13_arm64
            if arch == "arm64" and major < 11:
                major, minor = 11, 0
            plat = f"macosx_{major}_{minor}_{arch}"
        # scripts/build_wheel.py sets a manylinux tag derived from the runtime
        return "py3", "none", os.environ.get("KAOS_WHEEL_PLAT") or plat


setup(cmdclass={"bdist_wheel": PlatformWheel})
