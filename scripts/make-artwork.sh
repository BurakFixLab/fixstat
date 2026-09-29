#!/bin/bash
# Renders the artwork that is committed as binaries:
#   App/AppIcon.svg               → App/AppIcon.icns (app icon)
#   packaging/dmg-background.svg  → App/DMGBackground.tiff (DMG window background, 1× + 2×)
#
#   scripts/make-artwork.sh
#
# SVGs are rendered with WebKit (scripts/svg2png.swift, full filter support, transparent
# background), scaled with sips and packed with iconutil / tiffutil. Only Xcode's
# command-line tools are needed. Run it after changing an SVG and commit the results.
set -euo pipefail

cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

swiftc -O scripts/svg2png.swift -o "$work/svg2png"
"$work/svg2png" App/AppIcon.svg "$work/1024.png" 1024

set_dir="$work/AppIcon.iconset"
mkdir -p "$set_dir"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$work/1024.png" --out "$set_dir/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$work/1024.png" --out "$set_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o App/AppIcon.icns
echo "wrote App/AppIcon.icns"

# The DMG background lives inside the app bundle: a background file on the disk image
# itself would be an item in the window (visible where Finder shows hidden files, and
# moving it out of the window makes the window scroll).
"$work/svg2png" packaging/dmg-background.svg "$work/bg.png" 640 480
"$work/svg2png" packaging/dmg-background.svg "$work/bg@2x.png" 1280 960
tiffutil -cathidpicheck "$work/bg.png" "$work/bg@2x.png" -out App/DMGBackground.tiff >/dev/null 2>&1
echo "wrote App/DMGBackground.tiff"
