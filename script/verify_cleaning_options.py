#!/usr/bin/env python3
"""Verify cleaning choices exclusively on temporary copies of generated fixtures."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile

from verify_media_fixtures import probe, properties, decoded, first_video_frame
from qa_tools import require_fixtures

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Tests" / "Fixtures"
ENCODER_FIELDS = {"encoder", "software", "encoded_by", "encoding_tool", "com.apple.quicktime.software"}
FORMATS = ["tagged.mp4", "rotation-multitrack.mov", "info.avi", "hdr10.mp4", "artwork.mp4"]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def playback_properties(data):
    value = properties(data)
    for item in [value.get("format", {}), *value.get("streams", [])]:
        if "tags" in item:
            item["tags"] = {k: v for k, v in item["tags"].items() if k.lower() not in ENCODER_FIELDS}
            if not item["tags"]:
                del item["tags"]
    return value

def packet_encoder_markers(blob, data):
    result = []
    for marker in [b"x264", b"x265", b"Lavc"]:
        start = 0
        while (offset := blob.find(marker, start)) >= 0:
            for index, packet in enumerate(data.get("packets", [])):
                if "pos" in packet and int(packet["pos"]) <= offset < int(packet["pos"]) + int(packet["size"]):
                    result.append({"marker": marker.decode(), "byteOffset": offset, "packetIndex": index, "streamIndex": packet["stream_index"]})
                    break
            start = offset + len(marker)
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=Path, default=ROOT / ".build" / "debug" / "strippr-cli")
    args = parser.parse_args()
    require_fixtures(*FORMATS, "large-comment.mp4", "no-descriptive-tags.mp4")
    (ROOT / "artifacts").mkdir(parents=True, exist_ok=True)
    cli = args.cli.resolve()
    assert cli.is_file(), f"Build the updated CLI first: {cli}"
    originals = {p: sha(p) for p in FIXTURES.rglob("*") if p.is_file()}
    results = []

    def invoke(operation, source, *flags, record=True):
        p = subprocess.run([str(cli), operation, *map(str, flags), "--", str(source)], text=True, capture_output=True)
        records = [json.loads(line) for line in p.stdout.splitlines() if line.startswith("{")]
        if record:
            assert len(records) == 1, {"exit": p.returncode, "stdout": p.stdout, "stderr": p.stderr}
        return p.returncode, records[0] if records else {"error": p.stderr.strip()}

    def record(name, body):
        try:
            detail = body()
            results.append({"case": name, "passed": True, **(detail or {})})
        except Exception as error:
            results.append({"case": name, "passed": False, "error": str(error)})

    with tempfile.TemporaryDirectory(prefix="strippr-options-") as temporary:
        temporary = Path(temporary)

        def clean_variant(name, keep_encoder, replace_original):
            case_dir = temporary / f"{name}-encoder-{keep_encoder}-replace-{replace_original}"
            case_dir.mkdir()
            source = case_dir / name
            shutil.copyfile(FIXTURES / name, source)
            source.chmod(0o640)
            before = source.read_bytes()
            source_hash = sha(source)
            source_probe = probe(source, True)
            before_tags = source_probe.get("format", {}).get("tags", {})
            source_encoders = {k: v for k, v in before_tags.items() if k.lower() in ENCODER_FIELDS}
            assert source_encoders, f"Fixture has no container encoder fields: {name}"
            flags = [] if keep_encoder else ["--remove-encoder-info"]
            rc, scan = invoke("scan", source, *flags)
            assert rc == 0 and scan["canClean"], scan
            if not keep_encoder:
                assert any(tag["removable"] and ("encoder" in tag["key"].lower() or tag["key"] == "ISFT") for tag in scan["tags"]), scan
                assert any("bitstream" in warning.lower() for warning in scan.get("warnings", [])), "Encoder-off scan did not disclose retained codec-bitstream identifiers"
            if replace_original:
                flags += ["--replace-original", "--confirm-replacement"]
            rc, result = invoke("clean", source, *flags)
            assert rc == 0 and result["status"] == "verified", result
            output = Path(result["output"])
            assert result["didReplaceOriginal"] is replace_original, result
            assert result["keepEncoderInfo"] is keep_encoder, result
            if not keep_encoder:
                assert any("bitstream" in warning.lower() for warning in result.get("warnings", [])), "Encoder-off result did not disclose retained codec-bitstream identifiers"
            assert (output.resolve() == source.resolve()) is replace_original
            if replace_original:
                assert sorted(p.name for p in case_dir.iterdir()) == [source.name], "Replacement left an extra output/temporary file"
                assert source.stat().st_mode & 0o777 == 0o640, "Replacement changed POSIX permissions"
            else:
                assert sha(source) == source_hash, "Default clean changed original"
            after = output.read_bytes()
            assert len(before) == len(after), "Container byte length changed"
            ranges = [(edit["offset"], edit["offset"] + edit["length"]) for edit in scan["edits"]]
            for offset, (a, b) in enumerate(zip(before, after)):
                assert a == b or any(lo <= offset < hi for lo, hi in ranges), f"Unapproved byte modified at {offset}"
            output_probe = probe(output, True)
            assert playback_properties(source_probe) == playback_properties(output_probe), "Stream/packet/codec/timing/playback properties changed"
            assert first_video_frame(source if not replace_original else FIXTURES / name) == first_video_frame(output), "Decoded frame/HDR properties changed"
            assert decoded(FIXTURES / name) == decoded(output), "Decoded audio/video checksums changed"
            after_tags = output_probe.get("format", {}).get("tags", {})
            for key, value in source_encoders.items():
                assert (after_tags.get(key) == value) if keep_encoder else (key not in after_tags), f"Container encoder choice was not honored: {key}"
            markers = packet_encoder_markers(before, source_probe)
            for marker in markers:
                offset, literal = marker["byteOffset"], marker["marker"].encode()
                assert after[offset:offset + len(literal)] == literal, "Codec-bitstream encoder marker changed"
            return {"format": name, "keepEncoderInfo": keep_encoder, "replaceOriginal": replace_original,
                    "containerEncoderFieldsBefore": source_encoders, "containerEncoderFieldsAfter": {k: v for k, v in after_tags.items() if k.lower() in ENCODER_FIELDS},
                    "bytesVerified": len(before), "streams": len(source_probe["streams"]), "packets": len(source_probe.get("packets", [])),
                    "codecBitstreamEncoderMarkersRetained": markers, "codecExtradataAndPacketPayloadHashesIdentical": True,
                    "decodedChecksumsAndPlaybackPropertiesIdentical": True, "outsideApprovedEditsIdentical": True,
                    "originalPreserved": not replace_original, "samePathVerifiedReplacement": replace_original,
                    "warnings": result.get("warnings", [])}

        for name in FORMATS:
            for keep_encoder, replace_original in [(True, False), (False, False), (True, True), (False, True)]:
                record(f"{name}: encoder={'keep' if keep_encoder else 'remove'} original={'replace' if replace_original else 'keep'}", lambda n=name, k=keep_encoder, r=replace_original: clean_variant(n, k, r))

        def cancellation(threshold):
            directory = temporary / f"cancel-{threshold}"
            directory.mkdir()
            source = directory / "large-comment.mp4"
            shutil.copyfile(FIXTURES / source.name, source)
            before_hash, before_inode = sha(source), source.stat().st_ino
            rc, result = invoke("clean", source, "--remove-encoder-info", "--replace-original", "--confirm-replacement", "--cancel-after-progress", threshold)
            assert rc == 130 and result["status"] == "cancelled", result
            assert source.is_file() and sha(source) == before_hash and source.stat().st_ino == before_inode, "Cancellation lost or changed original"
            assert sorted(p.name for p in directory.iterdir()) == [source.name], "Cancellation left temporary files"
            return {"threshold": threshold, "originalBytesAndInodePreserved": True, "temporaryFilesRemoved": True}
        for threshold in [0.01, 0.5, 0.9, 0.99]:
            record(f"replace cancellation at {threshold}", lambda t=threshold: cancellation(t))

        def rejected_options(flags, label):
            directory = temporary / label
            directory.mkdir()
            source = directory / "tagged.mp4"
            shutil.copyfile(FIXTURES / source.name, source)
            before_hash = sha(source)
            output = directory / "custom-output"
            output.mkdir()
            expanded_flags = [str(output) if flag == "OUTPUT" else flag for flag in flags]
            rc, result = invoke("clean", source, *expanded_flags, record=False)
            assert rc != 0, result
            assert sha(source) == before_hash and not list(output.iterdir()), "Rejected options changed media"
            assert sorted(p.name for p in directory.iterdir()) == ["custom-output", source.name]
            return {"rejectedBeforeMutation": True, "error": result.get("error")}
        record("replacement requires explicit confirmation", lambda: rejected_options(["--replace-original"], "unconfirmed"))
        record("replacement rejects alternate destination", lambda: rejected_options(["--replace-original", "--confirm-replacement", "--output", "OUTPUT"], "destination-conflict"))

        def read_only_failure():
            directory = temporary / "readonly-source"
            directory.mkdir()
            source = directory / "tagged.mp4"
            shutil.copyfile(FIXTURES / source.name, source)
            source.chmod(0o444)
            before_hash = sha(source)
            try:
                rc, result = invoke("clean", source, "--replace-original", "--confirm-replacement")
                assert rc != 0 and result["status"] == "failed", result
                assert sha(source) == before_hash and sorted(p.name for p in directory.iterdir()) == [source.name]
                return {"readOnlyOriginalPreserved": True, "error": result["error"]}
            finally:
                source.chmod(0o644)
        record("replacement refuses read-only original", read_only_failure)

        def linked_source(kind):
            directory = temporary / f"{kind}-source"
            directory.mkdir()
            real = directory / "real.mp4"
            source = directory / "linked.mp4"
            shutil.copyfile(FIXTURES / "tagged.mp4", real)
            if kind == "symlink":
                source.symlink_to(real)
            else:
                os.link(real, source)
            before_hash, before_inode = sha(real), real.stat().st_ino
            rc, result = invoke("clean", source, "--replace-original", "--confirm-replacement")
            assert rc != 0 and result["status"] == "failed", result
            assert sha(real) == before_hash and real.stat().st_ino == before_inode and sha(source) == before_hash
            assert len(list(directory.iterdir())) == 2
            return {"linkedOriginalPreserved": True, "error": result["error"]}
        record("replacement refuses symbolic links", lambda: linked_source("symlink"))
        record("replacement refuses multiply linked files", lambda: linked_source("hardlink"))

        def unwritable_directory():
            directory = temporary / "unwritable-directory"
            directory.mkdir()
            source = directory / "tagged.mp4"
            shutil.copyfile(FIXTURES / source.name, source)
            before_hash = sha(source)
            directory.chmod(0o500)
            try:
                rc, result = invoke("clean", source, "--replace-original", "--confirm-replacement")
                assert rc != 0 and result["status"] == "failed", result
                assert source.is_file() and sha(source) == before_hash and len(list(directory.iterdir())) == 1
                return {"originalPreservedWhenTemporaryCreationFails": True, "error": result["error"]}
            finally:
                directory.chmod(0o700)
        record("replacement handles unwritable source directory", unwritable_directory)

        def encoder_only():
            directory = temporary / "encoder-only"
            directory.mkdir()
            source = directory / "no-descriptive-tags.mp4"
            shutil.copyfile(FIXTURES / source.name, source)
            rc, default = invoke("scan", source)
            assert rc == 0 and not default["canClean"], default
            rc, removed = invoke("clean", source, "--remove-encoder-info")
            assert rc == 0 and removed["status"] == "verified", removed
            assert "encoder" not in probe(Path(removed["output"])).get("format", {}).get("tags", {})
            return {"defaultPreservesEncoderOnlyFile": True, "encoderOffCreatesVerifiedCopy": True}
        record("encoder-only file honors choice", encoder_only)

    record("all original fixtures unchanged", lambda: {"sourceFiles": len(originals)} if all(sha(p) == h for p, h in originals.items()) else (_ for _ in ()).throw(AssertionError("Fixture original changed")))
    report = {"passed": all(item["passed"] for item in results), "cases": len(results), "results": results,
              "scope": "All mutations occurred inside a TemporaryDirectory populated from generated fixture copies. No source media or fixture originals were modified.",
              "encoderLimitation": "Encoder OFF removes supported container encoder/software tags only. Compressed codec-bitstream encoder identifiers, codec configuration and playback data remain byte-identical; no bitstream rewriting or reencoding."}
    target = ROOT / "artifacts" / "cleaning-options-verification.json"
    target.write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1

if __name__ == "__main__":
    raise SystemExit(main())
