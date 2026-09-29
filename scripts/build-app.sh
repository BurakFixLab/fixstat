#!/bin/bash
# Builds build/FixStat.app from the Swift package.
#
#   scripts/build-app.sh [release|debug]
#
# Steps: build with localized-string extraction, sync the string catalog with
# the code, check that every string has English and Turkish values, assemble
# the bundle (binary, Info.plist, sensor map, compiled strings) and sign it
# ad hoc. No tools beyond Xcode and the system python3 are needed.
set -euo pipefail

cd "$(dirname "$0")/.."
config="${1:-release}"
strings_dir="$PWD/.build/strings"
app="build/FixStat.app"

# The compiler only writes .stringsdata for files it recompiles, so the directory is
# kept between builds. Files whose source was deleted are removed below.
mkdir -p "$strings_dir"
# Release builds are universal (Apple Silicon and Intel); debug builds are native only.
arch_flags=()
if [ "$config" = "release" ]; then
    arch_flags=(--arch arm64 --arch x86_64)
fi
build() {
    swift build -c "$config" "${arch_flags[@]}" --product FixStat \
        -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$strings_dir"
}
build
if ! ls "$strings_dir"/*.stringsdata >/dev/null 2>&1; then
    # Up-to-date build from before this directory existed: force the app sources to recompile.
    touch Sources/FixStat/*.swift
    build
fi
for data in "$strings_dir"/*.stringsdata; do
    name="$(basename "$data" .stringsdata)"
    if ! ls Sources/*/"$name".swift >/dev/null 2>&1; then
        rm -f "$data"
    fi
done

xcrun xcstringstool sync App/Localizable.xcstrings --stringsdata "$strings_dir"/*.stringsdata
python3 scripts/localize.py check

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
bin="$(swift build -c "$config" "${arch_flags[@]}" --show-bin-path)"
cp "$bin/FixStat" "$app/Contents/MacOS/FixStat"
swift build -c "$config" "${arch_flags[@]}" --product fixstat-diskscan >/dev/null
cp "$bin/fixstat-diskscan" "$app/Contents/MacOS/fixstat-diskscan"
cp App/Info.plist "$app/Contents/Info.plist"
cp SensorMaps/sensor-map.json "$app/Contents/Resources/sensor-map.json"
cp SensorMaps/parts.json "$app/Contents/Resources/parts.json"
cp App/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp App/DMGBackground.tiff "$app/Contents/Resources/DMGBackground.tiff" # used by package-release.sh
# Permission prompts (Info.plist usage descriptions); English comes from Info.plist.
for lproj in App/*.lproj; do
    mkdir -p "$app/Contents/Resources/$(basename "$lproj")"
    cp "$lproj"/*.strings "$app/Contents/Resources/$(basename "$lproj")/"
done
xcrun xcstringstool compile App/Localizable.xcstrings --output-directory "$app/Contents/Resources" >/dev/null
codesign --force --sign - "$app/Contents/MacOS/fixstat-diskscan"
codesign --force --sign - "$app"

echo "built $app"
