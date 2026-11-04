#!/usr/bin/env python3
"""Read-only verification of the native GUI's 500-source/eight-copy QA run."""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import hashlib
import json
import subprocess

from verify_media_fixtures import probe, properties, decoded, first_video_frame

ROOT = Path(__file__).resolve().parents[1]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=Path, default=ROOT / ".build" / "debug" / "strippr-cli")
    parser.add_argument("--manifest", type=Path, default=ROOT / "artifacts" / "large-batch-qa-manifest.json")
    parser.add_argument("--outputs", type=Path, default=ROOT / "artifacts" / "Large Batch Cleaned Copies")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    assert len(manifest["files"]) == 500
    expected = [item for item in manifest["files"] if item["expectedRemovable"]]
    assert len(expected) == 8
    source_checks = []
    for item in manifest["files"]:
        path = Path(item["path"])
        actual = sha(path)
        source_checks.append({"id": item["id"], "relativePath": item["relativePath"], "sha256": actual, "matchesManifest": actual == item["sha256"]})
    expected_names = {Path(item["path"]).stem + ".stripped.mp4" for item in expected}
    actual_outputs = sorted(path for path in args.outputs.iterdir() if path.is_file() and path.suffix.lower() == ".mp4")
    actual_names = {path.name for path in actual_outputs}
    results = []

    def scan(path):
        p = subprocess.run([str(args.cli.resolve()), "scan", "--", str(path)], capture_output=True, text=True)
        assert p.returncode == 0, p.stderr or p.stdout
        data = json.loads(p.stdout)
        assert data["status"] == "scanned" and data["keepEncoderInfo"] is True
        return data

    for item in expected:
        source = Path(item["path"])
        output = args.outputs / (source.stem + ".stripped.mp4")
        result = {"id": item["id"], "source": str(source), "output": str(output)}
        try:
            assert output.is_file(), "Expected GUI output is missing"
            original, cleaned = source.read_bytes(), output.read_bytes()
            assert len(original) == len(cleaned), "File length changed"
            source_scan, output_scan = scan(source), scan(output)
            assert source_scan["removableTagCount"] == item["expectedRemovableTagCount"]
            assert not output_scan["canClean"] and output_scan["removableTagCount"] == 0, "Supported removable tag remains"
            source_encoders = [tag for tag in source_scan["tags"] if tag["key"].startswith("Encoder /")]
            output_encoders = [tag for tag in output_scan["tags"] if tag["key"].startswith("Encoder /")]
            assert source_encoders and [(x["key"], x["value"], x["removable"]) for x in source_encoders] == [(x["key"], x["value"], x["removable"]) for x in output_encoders], "Encoder information changed"
            edits = [(edit["offset"], edit["offset"] + edit["length"]) for edit in source_scan["edits"]]
            changed_bytes = 0
            for offset, (before, after) in enumerate(zip(original, cleaned)):
                if before != after:
                    assert any(start <= offset < end for start, end in edits), f"Unapproved byte change at {offset}"
                    changed_bytes += 1
            source_probe, output_probe = probe(source, True), probe(output, True)
            assert properties(source_probe) == properties(output_probe), "Stream, packet payload, timing, codec configuration, or playback properties changed"
            assert first_video_frame(source) == first_video_frame(output), "Decoded frame metadata changed"
            assert decoded(source) == decoded(output), "Decoded audio/video frame checksums changed"
            assert sha(source) == item["sha256"], "Original source changed"
            result.update({"passed": True, "sourceSHA256": item["sha256"], "outputSHA256": sha(output),
                           "bytesVerified": len(original), "changedBytesInsideApprovedMetadataOnly": changed_bytes,
                           "supportedRemovableTagsAfter": output_scan["removableTagCount"], "tagsRemoved": source_scan["removableTagCount"],
                           "retainedEncoderFields": [{"key": tag["key"], "value": tag["value"]} for tag in output_encoders],
                           "streams": len(source_probe["streams"]), "packets": len(source_probe.get("packets", [])),
                           "allPacketPayloadHashesAndPropertiesIdentical": True,
                           "streamCodecExtradataTimingAndPlaybackPropertiesIdentical": True,
                           "decodedAudioVideoChecksumsIdentical": True, "originalPreserved": True})
        except Exception as error:
            result.update({"passed": False, "error": str(error)})
        results.append(result)

    sources_unchanged_after = all(sha(Path(item["path"])) == item["sha256"] for item in manifest["files"])
    report = {"capturedUTC": datetime.now(timezone.utc).isoformat(),
              "passed": all(item["matchesManifest"] for item in source_checks) and sources_unchanged_after and actual_names == expected_names and all(item["passed"] for item in results),
              "operation": "Read-only independent verification of GUI-produced outputs; CLI scan and FFmpeg/FFprobe reads only",
              "sourceManifest": str(args.manifest.resolve()), "outputDirectory": str(args.outputs.resolve()),
              "sourceVideosChecked": len(source_checks), "sourceHashesMatchingManifest": sum(item["matchesManifest"] for item in source_checks),
              "all500SourcesUnchangedAfterVerification": sources_unchanged_after,
              "expectedOutputs": len(expected_names), "actualVideoOutputs": len(actual_names), "outputNamesMatchExactly": actual_names == expected_names,
              "unexpectedOutputNames": sorted(actual_names - expected_names), "missingOutputNames": sorted(expected_names - actual_names),
              "outputsWithZeroRemovableTagsAndRetainedEncoder": sum(item.get("passed", False) for item in results),
              "guiOutputResults": results, "sourceHashChecks": source_checks,
              "limitation": "This artifact validates the files produced by the GUI run. UI observations, selection/filter behavior, and responsiveness are documented separately by the parent agent."}
    path = ROOT / "artifacts" / "gui-large-batch-verification.json"
    path.write_text(json.dumps(report, indent=2))
    print(json.dumps({key: value for key, value in report.items() if key not in {"sourceHashChecks", "guiOutputResults"}}, indent=2))
    return 0 if report["passed"] else 1

if __name__ == "__main__":
    raise SystemExit(main())
