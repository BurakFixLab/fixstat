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

rm -rf "$strings_dir"
swift build -c "$config" --product FixStat \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$strings_dir"

xcrun xcstringstool sync App/Localizable.xcstrings --stringsdata "$strings_dir"/*.stringsdata
python3 scripts/localize.py check

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c "$config" --show-bin-path)/FixStat" "$app/Contents/MacOS/FixStat"
cp App/Info.plist "$app/Contents/Info.plist"
cp SensorMaps/sensor-map.json "$app/Contents/Resources/sensor-map.json"
xcrun xcstringstool compile App/Localizable.xcstrings --output-directory "$app/Contents/Resources" >/dev/null
codesign --force --sign - "$app"

echo "built $app"
