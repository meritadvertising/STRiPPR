#!/usr/bin/env bash
# Preserve the approved R cutout and package native icons with transparent insets.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CUTOUT="$ROOT_DIR/Resources/STRiPPR-icon-cutout.png"
SOURCE="$ROOT_DIR/Resources/STRiPPR-icon-source.png"
ICONSET="$ROOT_DIR/Resources/STRiPPR.iconset"
mkdir -p "$ROOT_DIR/.build/icon-module-cache"
# The tile already has its rounded silhouette. Render it onto clear pixels,
# inset to match neighboring macOS icons, without adding a rectangular backdrop.
/usr/bin/swift -module-cache-path "$ROOT_DIR/.build/icon-module-cache" - "$CUTOUT" "$SOURCE" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: 1024, height: 1024,
                              bitsPerComponent: 8, bytesPerRow: 4096,
                              space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Could not read the approved R cutout or create an RGBA icon canvas")
}
context.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.interpolationQuality = .high
context.draw(image, in: CGRect(x: 51.2, y: 51.2, width: 921.6, height: 921.6))
guard let icon = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("Could not create the transparent icon PNG")
}
CGImageDestinationAddImage(destination, icon, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not save the icon PNG") }
SWIFT
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  /usr/bin/sips -z "$double" "$double" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil --convert icns --output "$ROOT_DIR/Resources/STRiPPR.icns" "$ICONSET"
printf '%s\n' "$ROOT_DIR/Resources/STRiPPR.icns"
