import platform

from setuptools import setup
from setuptools.command.bdist_wheel import bdist_wheel


class PlatformWheel(bdist_wheel):
    """The wheel bundles a native runtime: tag it for this OS/CPU, any Python 3."""

    def finalize_options(self):
        super().finalize_options()
        self.root_is_pure = False

    def get_tag(self):
        _, _, plat = super().get_tag()
        # python.org macOS builds report universal2, but the runtime is single-arch
        if plat.startswith("macosx") and plat.endswith("universal2"):
            plat = plat[: -len("universal2")] + platform.machine()
        return "py3", "none", plat


setup(cmdclass={"bdist_wheel": PlatformWheel})
