#!/usr/bin/env bash
# Build a local, ad hoc signed Apple-silicon download. This does not notarize.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT_DIR/artifacts/releases}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
cd "$ROOT_DIR"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift build -c release --disable-sandbox --cache-path .build/swiftpm-cache --manifest-cache local \
  -Xswiftc -module-cache-path -Xswiftc "$CLANG_MODULE_CACHE_PATH" \
  -Xswiftc -gnone -Xswiftc -debug-prefix-map -Xswiftc "$ROOT_DIR=." \
  -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=."
BUILD_DIR="$(swift build -c release --disable-sandbox --cache-path .build/swiftpm-cache --manifest-cache local --show-bin-path)"
[[ "$(/usr/bin/lipo -archs "$BUILD_DIR/STRiPPR")" == "arm64" ]] || {
  printf '%s\n' 'This release script requires an Apple-silicon build host.' >&2; exit 1;
}
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
PACKAGE_NAME="STRiPPR-${VERSION}.0-macOS-arm64"
STAGING_DIR="$(mktemp -d "$OUT_DIR/.strippr-package-XXXXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
PACKAGE_DIR="$STAGING_DIR/$PACKAGE_NAME"
APP_DIR="$PACKAGE_DIR/STRiPPR.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
# Copy bytes only: local Library identity and other filesystem attributes stay local.
python3 - "$ROOT_DIR" "$BUILD_DIR" "$PACKAGE_DIR" <<'PY'
from pathlib import Path
import shutil, subprocess, sys
root, build, package = map(Path, sys.argv[1:])
app = package / 'STRiPPR.app/Contents'
sources = [(build/'STRiPPR', app/'MacOS/STRiPPR'),
           (root/'Resources/Info.plist', app/'Info.plist')]
sources += [(root/'Resources'/n, app/'Resources'/n) for n in ['STRiPPR-logo.png', 'STRiPPR.icns', 'Credits.rtf']]
sources += [(root/n, package/n) for n in ['README.md', 'LICENSE', 'NOTICE.md']]
for source, target in sources:
    shutil.copyfile(source, target)
    target.chmod(0o755 if target.name == 'STRiPPR' else 0o644)
    if target.name == 'STRiPPR':
        # SwiftPM's linker can embed AST/debug paths even with compiler -gnone.
        # Strip debug symbols before scanning paths and before applying signing.
        subprocess.run(['/usr/bin/strip', '-S', str(target)], check=True)
    data = target.read_bytes()
    if any(marker in data for marker in [b'/Users/', b'/var/folders/', str(root).encode()]):
        raise SystemExit(f'Private build path found in staged file: {target.name}')
PY
/usr/bin/codesign --force --sign - "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noacl \
  "$PACKAGE_DIR" "$OUT_DIR/$PACKAGE_NAME.zip"
python3 - "$OUT_DIR/$PACKAGE_NAME.zip" <<'PY'
from pathlib import Path
import hashlib, sys, zipfile
archive = Path(sys.argv[1])
with zipfile.ZipFile(archive) as z:
    names = z.namelist()
    if any('__MACOSX' in n or Path(n).name.startswith('._') or n.startswith('/') or '..' in Path(n).parts for n in names):
        raise SystemExit('Unexpected archive metadata or path')
    if not any(n.endswith('/STRiPPR.app/Contents/MacOS/STRiPPR') for n in names):
        raise SystemExit('Application missing from archive')
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
(archive.parent/'SHA256SUMS.txt').write_text(f'{digest}  {archive.name}\n')
print(archive)
print(f'SHA256: {digest}')
print('Ad hoc signed; not Developer ID signed or notarized.')
PY
