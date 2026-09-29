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
build() {
    swift build -c "$config" --product FixStat \
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
cp "$(swift build -c "$config" --show-bin-path)/FixStat" "$app/Contents/MacOS/FixStat"
swift build -c "$config" --product fixstat-diskscan >/dev/null
cp "$(swift build -c "$config" --show-bin-path)/fixstat-diskscan" "$app/Contents/MacOS/fixstat-diskscan"
cp App/Info.plist "$app/Contents/Info.plist"
cp SensorMaps/sensor-map.json "$app/Contents/Resources/sensor-map.json"
cp SensorMaps/parts.json "$app/Contents/Resources/parts.json"
# Permission prompts (Info.plist usage descriptions); English comes from Info.plist.
for lproj in App/*.lproj; do
    mkdir -p "$app/Contents/Resources/$(basename "$lproj")"
    cp "$lproj"/*.strings "$app/Contents/Resources/$(basename "$lproj")/"
done
xcrun xcstringstool compile App/Localizable.xcstrings --output-directory "$app/Contents/Resources" >/dev/null
codesign --force --sign - "$app/Contents/MacOS/fixstat-diskscan"
codesign --force --sign - "$app"

echo "built $app"
