#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
APP_NAME="STRiPPR"
BUNDLE_ID="com.laz.strippr"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_BUNDLE="${STRIPPR_APP_BUNDLE:-$ROOT_DIR/dist/$APP_NAME.app}"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_BINARY="$APP_CONTENTS/MacOS/$APP_NAME"

if [[ "$MODE" != "--build-only" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi
mkdir -p "$ROOT_DIR/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$ROOT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/module-cache"
swift build --disable-sandbox --cache-path "$ROOT_DIR/.build/swiftpm-cache" --manifest-cache local -Xswiftc -module-cache-path -Xswiftc "$ROOT_DIR/.build/module-cache"
BUILD_DIR="$(swift build --disable-sandbox --cache-path "$ROOT_DIR/.build/swiftpm-cache" --manifest-cache local --show-bin-path)"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_BINARY"
cp "$ROOT_DIR/Resources/STRiPPR-logo.png" "$APP_CONTENTS/Resources/STRiPPR-logo.png"
cp "$ROOT_DIR/Resources/STRiPPR.icns" "$APP_CONTENTS/Resources/STRiPPR.icns"
/usr/bin/ditto --norsrc --noextattr --noacl "$ROOT_DIR/Resources/Credits.rtf" "$APP_CONTENTS/Resources/Credits.rtf"
chmod +x "$APP_BINARY"
/usr/bin/ditto --norsrc --noextattr --noacl "$ROOT_DIR/Resources/Info.plist" "$APP_CONTENTS/Info.plist"
/usr/bin/codesign --force --sign - "$APP_BUNDLE"
# Replacing nested files does not update the enclosing bundle's timestamp.
# Refresh only this app's registration so Finder and the Dock see its current icon.
/usr/bin/touch "$APP_BUNDLE"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE"
case "$MODE" in
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --build-only) printf '%s\n' "$APP_BUNDLE" ;;
  --debug|debug) lldb -- "$APP_BINARY" ;;
  --logs|logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "STRiPPR"' ;;
  --telemetry|telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.laz.strippr"' ;;
  --verify|verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null; printf '%s\n' "Build and launch verified: $APP_BUNDLE" ;;
  *) printf 'usage: %s [run|--build-only|--debug|--logs|--telemetry|--verify]\n' "$0" >&2; exit 2 ;;
esac
