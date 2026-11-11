from importlib.metadata import PackageNotFoundError, version

try:
    __version__ = version("slides-to-video")
except PackageNotFoundError:
    __version__ = "0.0.0"
