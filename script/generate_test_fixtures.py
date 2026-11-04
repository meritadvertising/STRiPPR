#!/usr/bin/env python3
"""Generate small, synthetic media. Never reads or edits user media."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import struct
import subprocess
import sys

from qa_tools import require_tool

parser = argparse.ArgumentParser()
parser.add_argument("--with-vlc-album", action="store_true", help="Use installed VLC to save Album on a synthetic MP4 copy.")
args = parser.parse_args()

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "Tests" / "Fixtures"
FFMPEG = require_tool("ffmpeg")
FFPROBE = require_tool("ffprobe")
DEST.mkdir(parents=True, exist_ok=True)
(ROOT / "artifacts").mkdir(parents=True, exist_ok=True)

def ffmpeg(*args):
    subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", *map(str, args)], check=True)

def probe(path):
    p = subprocess.run([FFPROBE, "-v", "error", "-show_format", "-show_streams", "-show_chapters", "-of", "json", str(path)], text=True, capture_output=True)
    return json.loads(p.stdout) if p.returncode == 0 else {"error": p.stderr.strip()}

sub = DEST / "captions.srt"
sub.write_text("1\n00:00:00,000 --> 00:00:00,800\nSTRiPPR payload integrity fixture\n", encoding="utf-8")
chapters = DEST / "chapters.ffmeta"
chapters.write_text(";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=Keep this chapter structure\n", encoding="utf-8")

base = DEST / "tagged.mp4"
ffmpeg("-f", "lavfi", "-i", "testsrc2=size=96x64:rate=12:duration=1", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1", "-i", sub, "-map", "0:v", "-map", "1:a", "-map", "2:s", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-c:a", "aac", "-c:s", "mov_text", "-metadata", "title=Fixture Title", "-metadata", "artist=Fixture Artist", "-metadata", "album=Album MP4 saved", "-metadata", "comment=Descriptive comment to remove", "-metadata:s:a:0", "language=eng", "-metadata:s:s:0", "language=eng", "-movflags", "+faststart", base)

# Explicitly different native metadata representation (numeric ilst keys).
ffmpeg("-i", base, "-map", "0", "-c", "copy", "-metadata", "title=Fixture Title", "-metadata", "artist=Fixture Artist", "-metadata", "album=Album MDTA saved", "-metadata", "com.apple.quicktime.album=Album QuickTime key saved", "-metadata", "com.apple.quicktime.title=Alternate title", "-movflags", "+use_metadata_tags", DEST / "keyed-mdta.mp4")

# Rotation is represented in a display matrix; preserve all four tracks and chapters.
ffmpeg("-display_rotation:v:0", "90", "-i", base, "-i", chapters, "-map", "0:v", "-map", "0:a", "-map", "0:a", "-map", "0:s", "-map_metadata", "0", "-map_chapters", "1", "-c", "copy", "-metadata:s:a:1", "language=fra", "-metadata", "title=Rotated color and captions", "-metadata", "album=Album MOV saved", DEST / "rotation-multitrack.mov")

# HDR transfer/color fields and mastering/CLL SEI are all essential payload properties.
ffmpeg("-f", "lavfi", "-i", "testsrc2=size=96x64:rate=12:duration=1", "-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p10le", "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc", "-x265-params", "log-level=error:pools=1:colorprim=9:transfer=16:colormatrix=9:hdr10=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400", "-tag:v", "hvc1", "-metadata", "title=HDR10 verification", DEST / "hdr10.mp4")

ffmpeg("-i", base, "-map", "0", "-c", "copy", "-metadata", "title=Fragmented payload", "-movflags", "+frag_keyframe+empty_moov", DEST / "fragmented.mp4")

# Attached picture remains a video stream; descriptive title is still removable.
cover = DEST / "cover.jpg"
ffmpeg("-f", "lavfi", "-i", "color=c=red:s=16x16", "-frames:v", "1", cover)
ffmpeg("-i", base, "-i", cover, "-map", "0", "-map", "1:v", "-c", "copy", "-disposition:v:1", "attached_pic", "-metadata", "title=Keep attached artwork stream", DEST / "artwork.mp4")

# The removable comment crosses the cleaner's 1 MiB streaming boundaries.
large_meta = DEST / "large-comment.ffmeta"
large_meta.write_text(";FFMETADATA1\ntitle=Boundary title\ncomment=" + "Boundary-safe descriptive metadata. " * 65000 + "\n", encoding="utf-8")
ffmpeg("-i", base, "-i", large_meta, "-map", "0", "-c", "copy", "-map_metadata", "1", DEST / "large-comment.mp4")
large_meta.unlink()
ffmpeg("-f", "lavfi", "-i", "testsrc2=size=96x64:rate=12:duration=1", "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=44100:duration=1", "-c:v", "mpeg4", "-c:a", "pcm_s16le", "-metadata", "title=Odd!", "-metadata", "artist=Artist", "-metadata", "album=Album AVI saved", "-metadata", "comment=An odd-sized INFO value", DEST / "info.avi")
ffmpeg("-i", base, "-map", "0:v", "-map", "0:a", "-c", "copy", "-metadata", "title=Matroska read-only title", "-metadata", "artist=Retained until a supported safe editor exists", DEST / "readonly.mkv")
ffmpeg("-f", "lavfi", "-i", "testsrc2=size=96x64:rate=25:duration=1", "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000:duration=1", "-c:v", "mpeg2video", "-c:a", "mp2", "-f", "mpeg", DEST / "readonly.mpg")

# No removable metadata: strip metadata in the fixture generator only, never app workflow.
ffmpeg("-i", base, "-map", "0", "-c", "copy", "-map_metadata", "-1", DEST / "no-descriptive-tags.mp4")

# Mutation tests have precise native structures, not random user-like bytes.
raw = base.read_bytes()
(DEST / "truncated.mp4").write_bytes(raw[:100])
(DEST / "invalid-atom-size.mp4").write_bytes(struct.pack(">I4s", 7, b"moov"))
(DEST / "empty.mp4").write_bytes(b"")
(DEST / "not-video.mp4").write_text("Not a media container\n", encoding="utf-8")

unicode_dir = DEST / "nested" / "Björk 🌙"
unicode_dir.mkdir(parents=True, exist_ok=True)
shutil.copyfile(base, unicode_dir / "same name.mp4")
(DEST / "nested" / "other").mkdir(exist_ok=True)
shutil.copyfile(base, DEST / "nested" / "other" / "same name.mp4")
link = DEST / "nested" / "cycle"
if not link.exists():
    link.symlink_to(DEST / "nested", target_is_directory=True)

if args.with_vlc_album:
    subprocess.run([sys.executable, str(ROOT / "script" / "generate_vlc_album_fixture.py")], check=True)

manifest = {}
for path in sorted(DEST.rglob("*")):
    if path.is_file() and path.suffix in {".mp4", ".mov", ".avi", ".mkv", ".mpg"}:
        data = path.read_bytes()
        manifest[str(path.relative_to(DEST))] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "probe": probe(path)}
(ROOT / "artifacts" / "fixtures-manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
print(f"Generated {len(manifest)} synthetic fixtures at {DEST}")
