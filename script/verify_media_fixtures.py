#!/usr/bin/env python3
"""Exercise the shipped native core through its CLI and independent FFmpeg tools."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import sys
import tempfile

from qa_tools import require_fixtures, require_tool

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Tests" / "Fixtures"
REMOVABLE = {"title", "artist", "album_artist", "album", "product", "comment", "description", "synopsis", "genre", "date", "copyright", "com.apple.quicktime.title", "com.apple.quicktime.album"}
SAVED_ALBUM_EXPECTATIONS = {
    "tagged.mp4": {"album": "Album MP4 saved"},
    "keyed-mdta.mp4": {"album": "Album MDTA saved", "com.apple.quicktime.album": "Album QuickTime key saved"},
    "rotation-multitrack.mov": {"album": "Album MOV saved"},
    # FFprobe calls the RIFF IPRD album/product field "product".
    "info.avi": {"product": "Album AVI saved"},
    "vlc-saved-album.mp4": {"album": "VLC saved Album"},
}

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def command(args):
    return subprocess.run(list(map(str, args)), text=True, capture_output=True)

def probe(path, packets=False):
    args = [require_tool("ffprobe"), "-v", "error", "-show_streams", "-show_format", "-show_chapters", "-show_data_hash", "sha256"]
    if packets:
        args += ["-show_packets"]
    p = command(args + ["-of", "json", path])
    assert p.returncode == 0, p.stderr
    return json.loads(p.stdout)

def properties(data):
    data = json.loads(json.dumps(data))
    # Only descriptive tags are permitted to differ. Stream headers, dispositions,
    # side data, extradata hashes, timing, packet data hashes, and chapters remain.
    fmt = data.get("format", {})
    fmt.pop("filename", None)
    for item in [fmt, *data.get("streams", [])]:
        if "tags" in item:
            item["tags"] = {k: v for k, v in item["tags"].items() if k.lower() not in REMOVABLE and not (k == "JUNK" and v == "")}
            if not item["tags"]:
                del item["tags"]
    return data

def decoded(path):
    p = command([require_tool("ffmpeg"), "-v", "error", "-i", path, "-map", "0:v?", "-map", "0:a?", "-f", "framemd5", "-"])
    assert p.returncode == 0, p.stderr
    return p.stdout

def first_video_frame(path):
    p = command([require_tool("ffprobe"), "-v", "error", "-select_streams", "v:0", "-read_intervals", "%+#1", "-show_frames", "-of", "json", path])
    assert p.returncode == 0, p.stderr
    return json.loads(p.stdout)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=Path, default=ROOT / ".build" / "debug" / "strippr-cli")
    parser.add_argument("--sample", type=Path)
    args = parser.parse_args()
    require_fixtures("tagged.mp4", "keyed-mdta.mp4", "rotation-multitrack.mov", "fragmented.mp4", "hdr10.mp4", "info.avi", "artwork.mp4", "large-comment.mp4", "readonly.mkv", "readonly.mpg", "no-descriptive-tags.mp4")
    (ROOT / "artifacts").mkdir(parents=True, exist_ok=True)
    cli = args.cli.resolve()
    assert cli.is_file(), f"Build CLI first: {cli}"
    before = {p: sha(p) for p in FIXTURES.rglob("*") if p.is_file()}
    results = []

    def run_cli(operation, path, *options):
        p = command([cli, operation, *options, "--", path])
        lines = [json.loads(line) for line in p.stdout.splitlines() if line.startswith("{")]
        assert len(lines) == 1, f"Expected one result: {p.stdout}\n{p.stderr}"
        return p.returncode, lines[0]

    def record(name, body):
        try:
            detail = body()
            results.append({"case": name, "passed": True, **(detail or {})})
        except Exception as error:
            results.append({"case": name, "passed": False, "error": str(error)})

    with tempfile.TemporaryDirectory(prefix="strippr-integration-") as temp:
        output = Path(temp) / "cleaned"
        output.mkdir()

        def supported(path):
            source_hash = sha(path)
            # Prove Album was actually persisted before invoking STRiPPR. A test
            # that merely allows an absent album field cannot catch this regression.
            source_probe = probe(path, True)
            source_tags = source_probe.get("format", {}).get("tags", {})
            expected_albums = SAVED_ALBUM_EXPECTATIONS.get(path.name, {})
            for key, value in expected_albums.items():
                assert source_tags.get(key) == value, f"Fixture Album was not saved: {key}={value}; actual={source_tags.get(key)!r}"
                assert value.encode() in path.read_bytes(), f"Saved Album bytes missing: {key}"
            rc, scan = run_cli("scan", path)
            assert rc == 0 and scan["canClean"] and scan["removableTagCount"] > 0, scan
            for key, value in expected_albums.items():
                assert any(tag["removable"] and tag["value"] == value for tag in scan["tags"]), f"Saved Album not marked removable: {key}"
            rc, cleaned = run_cli("clean", path, "--output", output)
            assert rc == 0 and cleaned["status"] == "verified", cleaned
            target = Path(cleaned["output"])
            original, changed = path.read_bytes(), target.read_bytes()
            assert len(original) == len(changed), "Container byte length changed"
            ranges = [(edit["offset"], edit["offset"] + edit["length"]) for edit in scan["edits"]]
            for offset, (a, b) in enumerate(zip(original, changed)):
                assert a == b or any(start <= offset < end for start, end in ranges), f"Unapproved byte modified at {offset}"
            output_probe = probe(target, True)
            assert properties(source_probe) == properties(output_probe), "Playback/stream/packet/structural properties changed"
            assert first_video_frame(path) == first_video_frame(target), "First decoded frame properties or HDR side data changed"
            target_tags = output_probe.get("format", {}).get("tags", {})
            for key, value in expected_albums.items():
                assert key not in target_tags and value.encode() not in changed, f"Saved Album retained: {key}"
            for key, value in source_tags.items():
                if key.lower() in REMOVABLE:
                    assert key not in target_tags, f"Descriptive tag retained: {key}"
                if key.lower() in {"encoder", "software"}:
                    assert target_tags.get(key) == value, f"Encoder information changed: {key}"
            assert decoded(path) == decoded(target), "Decoded audio/video frame checksums changed"
            assert sha(path) == source_hash, "Source changed"
            rc, again = run_cli("scan", target)
            assert rc == 0 and again["removableTagCount"] == 0, again
            # Repeated runs create another result and never overwrite an existing copy.
            first_hash = sha(target)
            rc, second = run_cli("clean", path, "--output", output)
            assert rc == 0 and second["output"] != str(target), second
            assert sha(target) == first_hash, "Collision overwrote prior result"
            return {"bytesVerified": len(original), "streams": len(source_probe["streams"]), "packets": len(source_probe.get("packets", [])), "tagsRemoved": cleaned["removedTagCount"], "payloadHashesIdentical": True, "decodedFrameChecksumsIdentical": True, "firstFramePropertiesAndHDRSideDataIdentical": True, "sourceSHA256": source_hash, "savedAlbumFieldsVerifiedBeforeScanAndRemoved": expected_albums}

        for name in ["tagged.mp4", "keyed-mdta.mp4", "rotation-multitrack.mov", "fragmented.mp4", "hdr10.mp4", "info.avi", "artwork.mp4", "large-comment.mp4"]:
            record(name, lambda name=name: supported(FIXTURES / name))
        if (FIXTURES / "vlc-saved-album.mp4").exists():
            record("vlc-saved-album.mp4", lambda: supported(FIXTURES / "vlc-saved-album.mp4"))
        if args.sample:
            record("supplied-sample", lambda: supported(args.sample.resolve()))

        def readonly(name):
            path = FIXTURES / name
            rc, scan = run_cli("scan", path)
            assert rc == 0 and not scan["canClean"], scan
            if name != "no-descriptive-tags.mp4":
                assert scan["warnings"], scan
            rc, clean = run_cli("clean", path, "--output", output)
            assert rc != 0 and clean["status"] == "failed", clean
            return {"warning": scan["warnings"], "refusedUnsafeCleaning": True}
        for name in ["readonly.mkv", "readonly.mpg", "no-descriptive-tags.mp4"]:
            record(name, lambda name=name: readonly(name))

        def invalid(name):
            rc, data = run_cli("scan", FIXTURES / name)
            assert rc != 0 and data["status"] == "failed", data
            return {"error": data["error"]}
        for name in ["empty.mp4", "truncated.mp4", "not-video.mp4", "invalid-atom-size.mp4", "missing.mp4"]:
            record(name, lambda name=name: invalid(name))

        def cancellation():
            cancel_output = Path(temp) / "cancel"
            cancel_output.mkdir()
            for threshold in [0.01, 0.5, 0.9, 0.99]:
                rc, data = run_cli("clean", FIXTURES / "large-comment.mp4", "--output", cancel_output, "--cancel-after-progress", threshold)
                assert rc == 130 and data["status"] == "cancelled", {"threshold": threshold, **data}
                assert not list(cancel_output.iterdir()), f"Cancelled clean left files: {list(cancel_output.iterdir())}"
            return {"thresholds": [0.01, 0.5, 0.9, 0.99], "temporaryFilesRemoved": True}
        record("cancellation", cancellation)

        def invalid_output():
            file_output = Path(temp) / "not-a-directory"
            file_output.write_text("sentinel")
            rc, data = run_cli("clean", FIXTURES / "tagged.mp4", "--output", file_output)
            assert rc != 0 and data["status"] == "failed", data
            assert file_output.read_text() == "sentinel"
            return {"error": data["error"], "existingFileUnchanged": True}
        record("invalid-output", invalid_output)

        for relative in ["nested/Björk 🌙/same name.mp4", "nested/other/same name.mp4"]:
            record(relative, lambda relative=relative: supported(FIXTURES / relative))

    record("all-fixture-sources-unchanged", lambda: {"sourceFiles": len(before)} if all(sha(p) == h for p, h in before.items()) else (_ for _ in ()).throw(AssertionError("Fixture source changed")))
    report = {"passed": all(r["passed"] for r in results), "cases": len(results), "results": results, "verification": "Independent FFprobe full stream/packet hashes and properties; FFmpeg decoded audio/video frame checksums; byte differences restricted to scanned edit ranges; source SHA256; cancellation and collision safety."}
    target = ROOT / "artifacts" / "media-verification.json"
    target.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"Report: {target}")
    return 0 if report["passed"] else 1

if __name__ == "__main__":
    sys.exit(main())
