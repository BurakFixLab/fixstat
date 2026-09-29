#!/bin/bash
# Builds App/AppIcon.icns from App/AppIcon.svg.
#
#   scripts/make-icon.sh
#
# The SVG is rendered with WebKit (scripts/svg2png.swift, full filter support, transparent
# background) at 1024 px, scaled with sips and packed with iconutil. Only Xcode's
# command-line tools are needed. Run it after changing the SVG and commit the .icns.
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
