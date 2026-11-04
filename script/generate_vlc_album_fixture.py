#!/usr/bin/env python3
"""Save Album using installed libVLC/TagLib, exclusively on a synthetic copy."""
from pathlib import Path
import ctypes
import json
import os
import shutil
import time

from qa_tools import require_fixtures, vlc_macos_directory

ROOT = Path(__file__).resolve().parents[1]
VLC = vlc_macos_directory()
require_fixtures("no-descriptive-tags.mp4")
(ROOT / "artifacts").mkdir(parents=True, exist_ok=True)
os.environ["VLC_PLUGIN_PATH"] = str(VLC / "plugins")
ctypes.CDLL(str(VLC / "lib" / "libvlccore.dylib"), mode=ctypes.RTLD_GLOBAL)
lib = ctypes.CDLL(str(VLC / "lib" / "libvlc.dylib"), mode=ctypes.RTLD_GLOBAL)

def signature(name, result, args):
    f = getattr(lib, name)
    f.restype, f.argtypes = result, args
    return f

pointer = ctypes.c_void_p
new = signature("libvlc_new", pointer, [ctypes.c_int, ctypes.POINTER(ctypes.c_char_p)])
release = signature("libvlc_release", None, [pointer])
media_new = signature("libvlc_media_new_path", pointer, [pointer, ctypes.c_char_p])
media_release = signature("libvlc_media_release", None, [pointer])
parse = signature("libvlc_media_parse_with_options", ctypes.c_int, [pointer, ctypes.c_int, ctypes.c_int])
status = signature("libvlc_media_get_parsed_status", ctypes.c_int, [pointer])
set_meta = signature("libvlc_media_set_meta", None, [pointer, ctypes.c_int, ctypes.c_char_p])
get_meta = signature("libvlc_media_get_meta", pointer, [pointer, ctypes.c_int])
save_meta = signature("libvlc_media_save_meta", ctypes.c_int, [pointer])
free = signature("libvlc_free", None, [pointer])
version = signature("libvlc_get_version", ctypes.c_char_p, [])

options = [b"--ignore-config", b"--no-plugins-cache", b"--quiet"]
argv = (ctypes.c_char_p * len(options))(*options)
instance = new(len(options), argv)
assert instance, "libVLC initialization failed"
source = ROOT / "Tests" / "Fixtures" / "no-descriptive-tags.mp4"
target = ROOT / "Tests" / "Fixtures" / "vlc-saved-album.mp4"
shutil.copyfile(source, target)
media = media_new(instance, os.fsencode(target))
assert media, "libVLC could not open fixture copy"
try:
    assert parse(media, 0, 3000) == 0, "libVLC parse request failed"
    deadline = time.monotonic() + 4
    while status(media) == 0 and time.monotonic() < deadline:
        time.sleep(0.02)
    assert status(media) == 4, f"libVLC parse status: {status(media)}"
    # Installed libvlc_media.h declares Album as enum value 4.
    set_meta(media, 4, b"VLC saved Album")
    result = save_meta(media)
    assert result == 1, "libVLC reported Album save failure"
    value = get_meta(media, 4)
    in_memory_album = ctypes.string_at(value).decode() if value else None
    if value:
        free(value)
    report = {"libVLCVersion": version().decode(), "writer": "libvlc_media_set_meta Album + libvlc_media_save_meta", "saved": result == 1, "inMemoryAlbum": in_memory_album, "fixture": str(target), "source": str(source)}
    (ROOT / "artifacts" / "vlc-album-writer.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
finally:
    media_release(media)
    release(instance)
