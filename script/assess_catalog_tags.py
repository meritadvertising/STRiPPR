#!/usr/bin/env python3
"""Validate finite catalog-tag removal on generated copies; no user-media writes."""
from pathlib import Path
import hashlib
import json
import struct
import subprocess

from qa_tools import require_fixtures, require_tool

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "artifacts" / "Metadata QA"
DEST.mkdir(parents=True, exist_ok=True)
SOURCE = DEST / "catalog-fields.mp4"
TARGET = DEST / "catalog-candidates-neutralized-demonstration.mp4"
FFMPEG = require_tool("ffmpeg")
FFPROBE = require_tool("ffprobe")
require_fixtures("tagged.mp4")
FIELDS = {"track": "3/12", "disc": "2/4", "compilation": "1", "gapless_playback": "1", "lyrics": "QA plain lyrics", "grouping": "QA group", "composer": "QA composer", "show": "QA series", "season_number": "2", "episode_sort": "4", "network": "QA network", "episode_id": "S02E04", "hd_video": "1", "media_type": "10"}
CANDIDATES = {"tvnn": "network", "tves": "episode_sort", "tvsn": "season_number", "trkn": "track", "disk": "disc", "cpil": "compilation"}
arguments = [FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", str(ROOT / "Tests" / "Fixtures" / "tagged.mp4"), "-map", "0", "-c", "copy"]
for key, value in FIELDS.items():
    arguments += ["-metadata", f"{key}={value}"]
subprocess.run(arguments + [str(SOURCE)], check=True)
original = SOURCE.read_bytes()

def sha(data):
    return hashlib.sha256(data).hexdigest()

def metadata_atoms(start, end, path=""):
    result = []
    offset = start
    while offset < end:
        assert end - offset >= 8
        size, kind = struct.unpack_from(">I4s", original, offset)
        header = 8
        if size == 1:
            size, header = struct.unpack_from(">Q", original, offset + 8)[0], 16
        elif size == 0:
            size = end - offset
        assert header <= size <= end - offset
        nodepath = path + "/" + kind.decode("latin-1")
        node = {"path": nodepath, "type": kind.decode("latin-1"), "offset": offset, "length": size, "headerLength": header}
        result.append(node)
        if kind in {b"moov", b"trak", b"mdia", b"minf", b"stbl", b"udta", b"ilst"}:
            result += metadata_atoms(offset + header, offset + size, nodepath)
        elif kind == b"meta":
            flags = 4 if original[offset + header:offset + header + 4] == b"\0" * 4 else 0
            result += metadata_atoms(offset + header + flags, offset + size, nodepath)
        offset += size
    assert offset == end
    return result

tree = metadata_atoms(0, len(original))
edits = [x for x in tree if x["path"].startswith("/moov/udta/meta/ilst/") and x["type"] in CANDIDATES]
assert {x["type"] for x in edits} == CANDIDATES.keys()
changed = bytearray(original)
for edit in edits:
    start, size, header = edit["offset"], edit["length"], edit["headerLength"]
    changed[start + 4:start + 8] = b"free"
    changed[start + header:start + size] = b"\0" * (size - header)
TARGET.write_bytes(changed)

def probe(path):
    p = subprocess.run([FFPROBE, "-v", "error", "-show_streams", "-show_format", "-show_chapters", "-show_packets", "-show_data_hash", "sha256", "-of", "json", str(path)], capture_output=True, text=True, check=True)
    return json.loads(p.stdout)

def decoded(path):
    return subprocess.run([FFMPEG, "-v", "error", "-i", str(path), "-map", "0:v?", "-map", "0:a?", "-f", "framemd5", "-"], capture_output=True, text=True, check=True).stdout

before, after = probe(SOURCE), probe(TARGET)
before_tags, after_tags = before["format"]["tags"], after["format"]["tags"]
for name in CANDIDATES.values():
    assert before_tags[name] == FIELDS[name] and name not in after_tags
assert before["streams"] == after["streams"], "Stream or codec configuration properties changed"
assert before["packets"] == after["packets"], "Packet payload, count, order or timestamps changed"
assert before["chapters"] == after["chapters"], "Chapter properties changed"
assert decoded(SOURCE) == decoded(TARGET), "Decoded video/audio frame checksums changed"
expected_tags = {k: v for k, v in before_tags.items() if k not in CANDIDATES.values()}
assert expected_tags == after_tags, "Unapproved tags changed"
for atom in tree:
    if atom["path"] in {"/moov/trak", "/mdat"}:
        start, end = atom["offset"], atom["offset"] + atom["length"]
        assert original[start:end] == changed[start:end]
assert SOURCE.read_bytes() == original
report = {
    "passed": True, "source": str(SOURCE), "copy": str(TARGET), "sourceSHA256": sha(original), "sourceUnchanged": True,
    "operation": "Experiment: equal-size free replacement of six catalog-only ilst metadata atoms, before production support.",
    "candidateAtomNamesToFFprobeTags": CANDIDATES, "edits": edits,
    "tagsBefore": before_tags, "tagsAfter": after_tags,
    "streamsBeforeAndAfter": len(before["streams"]), "packetsBeforeAndAfter": len(before["packets"]),
    "allStreamPropertiesAndCodecExtradataHashesIdentical": True, "allPacketPropertiesAndPayloadHashesIdentical": True,
    "decodedFrameChecksumsIdentical": True, "nativeTrackAndMdatBytesIdentical": True,
    "playbackRelatedTagsExplicitlyPreserved": {key: after_tags[key] for key in ["gapless_playback", "media_type", "hd_video", "encoder"]},
    "constraint": "Empirical validation applies to these native ilst catalog fields and generated fixtures; unknown namespaces, artwork streams and timing/loudness/gapless data remain protected."
}
report_path = ROOT / "artifacts" / "catalog-tag-assessment.json"
report_path.write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
