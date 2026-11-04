#!/usr/bin/env python3
"""Create and scan 500 synthetic video copies for native queue/filter/sort QA."""
from pathlib import Path
from collections import Counter
import argparse
import hashlib
import json
import shutil
import subprocess
import unicodedata

from qa_tools import require_fixtures

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "artifacts" / "Large Batch QA"
MANIFEST = ROOT / "artifacts" / "large-batch-qa-manifest.json"
SCAN_REPORT = ROOT / "artifacts" / "large-batch-qa-scans.jsonl"
VERIFICATION = ROOT / "artifacts" / "large-batch-qa-verification.json"
REMOVABLE_IDS = {1, 37, 89, 173, 249, 333, 417, 500}
COLLECTIONS = [
    "Family", "Björk 🌙", "東京", "Café", "Résumé", "Travel", "Año 2026", "Studio", "Concerts", "Memories",
    "Winter", "Spring", "Summer", "Autumn", "Night Walks", "Ocean", "Mountains", "Friends", "Archive", "Finale",
]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run_scan(cli, paths):
    p = subprocess.run([str(cli), "scan", "--", *map(str, paths)], text=True, capture_output=True)
    assert p.returncode == 0, p.stderr or p.stdout
    records = [json.loads(line) for line in p.stdout.splitlines()]
    assert len(records) == len(paths), "CLI did not return one scan per file"
    return records, p.stdout

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=Path, default=ROOT / ".build" / "debug" / "strippr-cli")
    parser.add_argument("--verify-existing", action="store_true", help="Verify an existing untouched batch without copying or overwriting anything.")
    args = parser.parse_args()
    require_fixtures("tagged.mp4", "no-descriptive-tags.mp4")
    cli = args.cli.resolve()
    assert cli.is_file(), f"CLI is not built: {cli}"
    assert args.verify_existing or not DEST.exists() or not any(DEST.iterdir()), f"Refusing to overwrite an existing QA batch: {DEST}"
    dirty = ROOT / "Tests" / "Fixtures" / "tagged.mp4"
    clean = ROOT / "Tests" / "Fixtures" / "no-descriptive-tags.mp4"
    template_hashes = {str(path): sha(path) for path in [dirty, clean]}
    templates, _ = run_scan(cli, [dirty, clean])
    assert templates[0]["canClean"] and templates[0]["removableTagCount"] > 0
    assert not templates[1]["canClean"] and templates[1]["removableTagCount"] == 0
    for template in templates:
        assert template["keepEncoderInfo"] is True
        assert any(tag["key"].startswith("Encoder /") and not tag["removable"] for tag in template["tags"])
    DEST.mkdir(parents=True, exist_ok=True)
    files = []
    for index in range(1, 501):
        group = (index - 1) // 25
        slot = (index - 1) % 25 + 1
        directory = DEST / f"{group + 1:02d} {COLLECTIONS[group]}" / f"Session {1 + (slot - 1) // 5:02d}"
        directory.mkdir(parents=True, exist_ok=True)
        # Repeated basenames occur in separate directories; no path is duplicated.
        basename = "shared name.mp4" if slot == 1 else (f"Été clip {slot:02d} 🌙.mp4" if slot == 13 else f"Video {slot:02d}.mp4")
        path = directory / basename
        removable = index in REMOVABLE_IDS
        source = dirty if removable else clean
        if not args.verify_existing:
            shutil.copyfile(source, path)
        assert path.is_file() and sha(path) == template_hashes[str(source)]
        files.append({"id": f"video-{index:03d}", "path": str(path), "relativePath": str(path.relative_to(DEST)),
                      "sha256": sha(path), "bytes": path.stat().st_size,
                      "expectedRemovable": removable,
                      "expectedRemovableTagCount": templates[0]["removableTagCount"] if removable else 0})
    paths = [Path(item["path"]) for item in files]
    records, scan_text = run_scan(cli, paths)
    SCAN_REPORT.write_text(scan_text)
    canonical_path = lambda path: unicodedata.normalize("NFC", str(Path(path).resolve()))
    expected_by_path = {canonical_path(item["path"]): item for item in files}
    for scan in records:
        expected = expected_by_path[canonical_path(scan["path"])]
        assert scan["canClean"] is expected["expectedRemovable"], scan
        assert scan["removableTagCount"] == expected["expectedRemovableTagCount"], scan
        assert scan["keepEncoderInfo"] is True
        assert any(tag["key"].startswith("Encoder /") and not tag["removable"] for tag in scan["tags"])
        assert sha(Path(scan["path"])) == expected["sha256"], "Read-only scan changed a batch file"
    assert len(list(DEST.rglob("*.mp4"))) == 500
    assert sum(scan["canClean"] for scan in records) == 8
    assert sum(not scan["canClean"] for scan in records) == 492
    assert all(sha(Path(path)) == digest for path, digest in template_hashes.items()), "Synthetic source template changed"
    basenames = Counter(path.name for path in paths)
    manifest = {
        "purpose": "500-file native UI scan/filter/sort QA; generated from synthetic media only",
        "batchDirectory": str(DEST), "requiredOption": "Keep encoder info ON (default)",
        "totalVideos": 500, "expectedFilesWithRemovableTags": 8, "expectedFilesWithoutRemovableTags": 492,
        "expectedRemovableIDs": [item["id"] for item in files if item["expectedRemovable"]],
        "expectedRemovableRelativePaths": [item["relativePath"] for item in files if item["expectedRemovable"]],
        "templates": templates, "templateSHA256": template_hashes, "files": files,
    }
    MANIFEST.write_text(json.dumps(manifest, indent=2))
    summary = {
        "passed": True, "batchDirectory": str(DEST), "manifest": str(MANIFEST), "cliScans": str(SCAN_REPORT),
        "totalVideos": len(records), "filesWithRemovableTags": sum(scan["canClean"] for scan in records),
        "filesWithoutRemovableTags": sum(not scan["canClean"] for scan in records),
        "filesWithRetainedEncoder": sum(any(tag["key"].startswith("Encoder /") and not tag["removable"] for tag in scan["tags"]) for scan in records),
        "totalBytes": sum(item["bytes"] for item in files), "uniquePaths": len(set(map(str, paths))),
        "duplicateBasenameGroups": sum(count > 1 for count in basenames.values()),
        "allBatchHashesMatchValidTemplates": True, "sourceTemplatesUnchanged": True,
        "expectedRemovableIDs": manifest["expectedRemovableIDs"],
        "requiredOption": manifest["requiredOption"],
        "limitation": "These CLI scans verify fixture counts and metadata expectations. They do not measure native UI scan, rendering, filter, or sort performance."
    }
    VERIFICATION.write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))

if __name__ == "__main__":
    main()
