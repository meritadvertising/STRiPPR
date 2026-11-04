#!/usr/bin/env python3
"""Fresh, local-only libVLC metadata reads. This script never sets or saves tags."""
from pathlib import Path
import argparse
import ctypes
import hashlib
import json
import os
import subprocess
import time

from qa_tools import require_tool, vlc_macos_directory

parser = argparse.ArgumentParser()
parser.add_argument("--report", type=Path)
parser.add_argument("files", type=Path, nargs="+")
args = parser.parse_args()
vlc = vlc_macos_directory()
os.environ["VLC_PLUGIN_PATH"] = str(vlc / "plugins")
ctypes.CDLL(str(vlc / "lib" / "libvlccore.dylib"), mode=ctypes.RTLD_GLOBAL)
lib = ctypes.CDLL(str(vlc / "lib" / "libvlc.dylib"), mode=ctypes.RTLD_GLOBAL)
pointer = ctypes.c_void_p

def signature(name, result, parameters):
    f = getattr(lib, name)
    f.restype, f.argtypes = result, parameters
    return f

new = signature("libvlc_new", pointer, [ctypes.c_int, ctypes.POINTER(ctypes.c_char_p)])
release = signature("libvlc_release", None, [pointer])
media_new = signature("libvlc_media_new_path", pointer, [pointer, ctypes.c_char_p])
media_release = signature("libvlc_media_release", None, [pointer])
parse = signature("libvlc_media_parse_with_options", ctypes.c_int, [pointer, ctypes.c_int, ctypes.c_int])
status = signature("libvlc_media_get_parsed_status", ctypes.c_int, [pointer])
get_meta = signature("libvlc_media_get_meta", pointer, [pointer, ctypes.c_int])
free = signature("libvlc_free", None, [pointer])
version = signature("libvlc_get_version", ctypes.c_char_p, [])

options = [b"--ignore-config", b"--no-plugins-cache", b"--quiet"]
argv = (ctypes.c_char_p * len(options))(*options)
instance = new(len(options), argv)
assert instance, "libVLC initialization failed"
records = []
try:
    for path in args.files:
        path = path.resolve()
        before = hashlib.sha256(path.read_bytes()).hexdigest()
        media = media_new(instance, os.fsencode(path))
        assert media, f"libVLC could not open {path}"
        try:
            assert parse(media, 0, 3000) == 0, f"libVLC parse request failed for {path}"
            deadline = time.monotonic() + 4
            while status(media) == 0 and time.monotonic() < deadline:
                time.sleep(0.02)
            assert status(media) == 4, f"libVLC parse status: {status(media)}"
            metadata = {}
            for name, code in {"Title": 0, "Artist": 1, "Album": 4, "EncodedBy": 14}.items():
                value = get_meta(media, code)
                metadata[name] = ctypes.string_at(value).decode() if value else None
                if value:
                    free(value)
            ff = subprocess.run([require_tool("ffprobe"), "-v", "error", "-show_entries", "format_tags", "-of", "json", str(path)], capture_output=True, text=True, check=True)
            assert hashlib.sha256(path.read_bytes()).hexdigest() == before, "Source changed during read-only inspection"
            records.append({"file": str(path), "sourceSHA256": before, "parseStatus": "done", "freshLibVLCMetadata": metadata, "ffprobeTags": json.loads(ff.stdout).get("format", {}).get("tags", {}), "unchanged": True})
        finally:
            media_release(media)
finally:
    release(instance)
report = {"libVLCVersion": version().decode(), "operation": "Fresh local parse, get_meta only; no setters or saves", "files": records}
text = json.dumps(report, indent=2)
if args.report:
    args.report.write_text(text)
print(text)
