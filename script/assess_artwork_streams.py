#!/usr/bin/env python3
"""Demonstrate cover-art stream effects on disposable synthetic fixtures only."""
from pathlib import Path
import hashlib
import json
import struct
import subprocess

from qa_tools import require_fixtures, require_tool

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Tests" / "Fixtures" / "artwork.mp4"
require_fixtures("artwork.mp4")
DEST = ROOT / "artifacts" / "Artwork QA"
DEST.mkdir(parents=True, exist_ok=True)
TARGET = DEST / "covr-neutralized-demonstration.mp4"
original = SOURCE.read_bytes()

def sha(data):
    return hashlib.sha256(data).hexdigest()

def atoms(blob, start=0, end=None, path=""):
    end = len(blob) if end is None else end
    result = []
    offset = start
    while offset < end:
        assert end - offset >= 8, f"Truncated atom at {offset}"
        size, kind = struct.unpack_from(">I4s", blob, offset)
        header = 8
        if size == 1:
            size = struct.unpack_from(">Q", blob, offset + 8)[0]
            header = 16
        elif size == 0:
            size = end - offset
        assert header <= size <= end - offset
        node_path = path + "/" + kind.decode("latin-1")
        node = {"path": node_path, "type": kind.decode("latin-1"), "offset": offset, "length": size, "headerLength": header}
        result.append(node)
        if kind in {b"moov", b"trak", b"mdia", b"minf", b"stbl", b"udta", b"ilst"}:
            result.extend(atoms(blob, offset + header, offset + size, node_path))
        elif kind == b"meta":
            flags = 4 if blob[offset + header:offset + header + 4] == b"\0" * 4 else 0
            result.extend(atoms(blob, offset + header + flags, offset + size, node_path))
        offset += size
    assert offset == end
    return result

tree = atoms(original)
covers = [x for x in tree if x["path"].endswith("/udta/meta/ilst/covr")]
assert len(covers) == 1, covers
cover = covers[0]
changed = bytearray(original)
start, size, header = cover["offset"], cover["length"], cover["headerLength"]
changed[start + 4:start + 8] = b"free"
changed[start + header:start + size] = b"\0" * (size - header)
TARGET.write_bytes(changed)

def probe(path):
    p = subprocess.run([require_tool("ffprobe"), "-v", "error", "-show_streams", "-show_format", "-show_packets", "-show_data_hash", "sha256", "-of", "json", str(path)], capture_output=True, text=True, check=True)
    return json.loads(p.stdout)

before, after = probe(SOURCE), probe(TARGET)
before_cover = [s for s in before["streams"] if s.get("disposition", {}).get("attached_pic") == 1]
after_cover = [s for s in after["streams"] if s.get("disposition", {}).get("attached_pic") == 1]
assert len(before_cover) == 1 and not after_cover
native_tracks = [x for x in tree if x["path"] == "/moov/trak"]
real_indexes = {s["index"] for s in before["streams"] if s.get("disposition", {}).get("attached_pic") != 1}
before_packets = [p for p in before["packets"] if p["stream_index"] in real_indexes]
after_packets = [p for p in after["packets"] if p["stream_index"] in real_indexes]
assert before_packets == after_packets, "Underlying track packet data/properties unexpectedly changed"
assert [s for s in before["streams"] if s["index"] in real_indexes] == after["streams"]
for track in native_tracks:
    lo, hi = track["offset"], track["offset"] + track["length"]
    assert original[lo:hi] == changed[lo:hi], "A real track atom changed"
mdats = [x for x in tree if x["path"] == "/mdat"]
for mdat in mdats:
    lo, hi = mdat["offset"], mdat["offset"] + mdat["length"]
    assert original[lo:hi] == changed[lo:hi], "mdat bytes changed"
assert SOURCE.read_bytes() == original, "Synthetic source changed"

def summary(s):
    return {k: s[k] for k in ["index", "codec_name", "codec_type", "id", "width", "height", "extradata_hash", "disposition"] if k in s}

report = {
    "source": str(SOURCE), "demonstrationCopy": str(TARGET),
    "sourceSHA256": sha(original), "copySHA256": sha(changed), "sourceUnchanged": True,
    "operation": "Experiment only: replace covr atom with equal-length free atom and zero payload. Production STRiPPR retains covr.",
    "covrAtom": cover,
    "nativeTrakAtomsBeforeAndAfter": len(native_tracks),
    "nativeTrakAtomHashes": [sha(original[x["offset"]:x["offset"] + x["length"]]) for x in native_tracks],
    "ffprobeStreamsBefore": [summary(s) for s in before["streams"]],
    "ffprobeStreamsAfter": [summary(s) for s in after["streams"]],
    "ffprobeStreamCountBefore": len(before["streams"]), "ffprobeStreamCountAfter": len(after["streams"]),
    "attachedPictureStreamsBefore": len(before_cover), "attachedPictureStreamsAfter": len(after_cover),
    "genuineTrackPacketCount": len(before_packets), "genuineTrackPacketsAndPropertiesIdentical": True,
    "allMdatBytesIdentical": True, "allNativeTrackAtomBytesIdentical": True,
    "conclusion": "covr is stored outside native trak atoms, but FFprobe exposes it as an attached-picture video stream. Neutralization removes that exposed stream (4 to 3 here), violating an unqualified preserve-all-streams requirement. Retain covr unless the user expressly authorizes removal of attached artwork streams.",
    "codecPacketConstraints": [
        "Preserve every genuine video/audio/subtitle/data stream, disposition, codec configuration and extradata hash.",
        "Preserve packet count, order, stream identity, PTS/DTS/duration, flags, size, byte position and compressed payload hash.",
        "Preserve display matrix, color/HDR metadata, sample tables, timing/edit lists, audio priming/gapless and loudness metadata that affects playback.",
        "Byte-identical native track and mdat regions prove fixed-size cover metadata neutralization does not reencode genuine tracks, but cannot prove all exposed streams are preserved when a cover stream disappears."
    ]
}
output = ROOT / "artifacts" / "artwork-stream-assessment.json"
output.write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
