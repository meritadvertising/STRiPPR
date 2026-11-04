#!/usr/bin/env bash
# Use a command-local Xcode selection; never change the user's xcode-select.
set -euo pipefail
TEST_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TEST_PROJECT"
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="$TEST_PROJECT/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
exec swift test --disable-sandbox --cache-path .build/swiftpm-cache --manifest-cache local \
    -Xswiftc -module-cache-path -Xswiftc "$CLANG_MODULE_CACHE_PATH" "$@"
