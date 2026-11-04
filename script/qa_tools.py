"""Portable dependencies for optional, generated-media QA scripts."""
from functools import lru_cache
from pathlib import Path
import os
import shutil

ROOT = Path(__file__).resolve().parents[1]


@lru_cache(maxsize=None)
def require_tool(name):
    """Resolve an executable using FFMPEG/FFPROBE overrides, then PATH."""
    variable = name.upper()
    requested = os.environ.get(variable) or name
    resolved = shutil.which(os.path.expanduser(requested))
    if not resolved:
        raise SystemExit(f"Required tool '{name}' was not found. Install it on PATH or set {variable} to its executable path.")
    return resolved


def require_fixtures(*names):
    directory = ROOT / "Tests" / "Fixtures"
    missing = [name for name in names if not (directory / name).is_file()]
    if missing:
        raise SystemExit("Generated QA fixtures are missing: " + ", ".join(missing) +
                         ". Run: python3 script/generate_test_fixtures.py")
    return directory


def vlc_macos_directory():
    directory = Path(os.environ.get("VLC_MACOS_PATH", "/Applications/VLC.app/Contents/MacOS")).expanduser()
    if not (directory / "lib" / "libvlc.dylib").is_file():
        raise SystemExit("VLC for macOS is required for this optional check. Install VLC or set VLC_MACOS_PATH to its Contents/MacOS directory.")
    return directory
