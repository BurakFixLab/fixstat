#!/bin/bash
# Builds build/FixStat.app.
#
#   scripts/build-app.sh [release|debug]
#
# FixStat runs on macOS 10.13 and later (Intel) / 11 and later (Apple Silicon): macOS 14+
# gets the SwiftUI interface, older systems the AppKit one (Sources/FixStat/main.swift).
# SwiftPM raises the deployment target to macOS 12, so the app is compiled with clang and
# swiftc directly:
#   C shims → MacSensors (static library + module) → FixStat and fixstat-diskscan
#   (with localized-string extraction) → lipo → string catalog sync + check → bundle
#   (Swift runtime for macOS < 10.14.4 in Contents/Frameworks) → ad-hoc signature.
# release: universal and optimized; debug: this Mac's architecture, unoptimized (faster).
# `swift build` / `swift test` still work for development (SwiftPM, macOS 14).
# No tools beyond Xcode and the system python3 are needed.
set -euo pipefail

cd "$(dirname "$0")/.."
config="${1:-release}"
app="build/FixStat.app"
strings_dir="$PWD/.build/strings"
work="$PWD/.build/app-$config"

case "$config" in
    release)
        targets=(x86_64-apple-macos10.13 arm64-apple-macos11.0)
        optimize=(-O -whole-module-optimization)
        ;;
    debug)
        if [ "$(uname -m)" = "arm64" ]; then targets=(arm64-apple-macos11.0); else targets=(x86_64-apple-macos10.13); fi
        optimize=(-Onone -g)
        ;;
    *) echo "usage: $0 [release|debug]" >&2; exit 2 ;;
esac

rm -rf "$work" "$strings_dir"
mkdir -p "$work/include" "$strings_dir"

# Module map for the C shims (SwiftPM generates one; here it is written by hand).
cp Sources/CMacSensors/include/*.h "$work/include/"
cat > "$work/include/module.modulemap" <<'MAP'
module CMacSensors {
    umbrella header "CMacSensors.h"
    export *
}
MAP

# swiftc adds /usr/lib/swift (the system's Swift runtime) first; the bundled copy is the fallback.
rpaths=(-Xlinker -rpath -Xlinker @executable_path/../Frameworks)
# CoreMedia / CoreVideo are linked explicitly: otherwise their C functions bind through
# libswiftCoreMedia, which re-exports them only on recent macOS.
first=1
for target in "${targets[@]}"; do
    dir="$work/$target"
    mkdir -p "$dir"
    for c in Sources/CMacSensors/*.c; do
        clang -c -O2 -target "$target" -I "$work/include" "$c" -o "$dir/$(basename "$c" .c).o"
    done
    swiftc -target "$target" "${optimize[@]}" -swift-version 6 -parse-as-library \
        -module-name MacSensors -I "$work/include" \
        -emit-module -emit-module-path "$dir/MacSensors.swiftmodule" \
        -emit-library -static -o "$dir/libMacSensors.a" Sources/MacSensors/*.swift
    # The string catalog is fed from the first architecture's compile.
    strings=()
    if [ "$first" = 1 ]; then
        strings=(-emit-localized-strings -emit-localized-strings-path "$strings_dir")
        first=0
    fi
    # AppKit interface (macOS 10.13 – 13): Swift 5 mode, no actor isolation checks.
    swiftc -target "$target" "${optimize[@]}" -swift-version 5 -parse-as-library \
        -module-name FixStatLegacy -I "$dir" -I "$work/include" ${strings[@]+"${strings[@]}"} \
        -emit-module -emit-module-path "$dir/FixStatLegacy.swiftmodule" \
        -emit-library -static -o "$dir/libFixStatLegacy.a" Sources/FixStatLegacy/*.swift
    swiftc -target "$target" "${optimize[@]}" -swift-version 6 -module-name FixStat \
        -I "$dir" -I "$work/include" ${strings[@]+"${strings[@]}"} \
        Sources/FixStat/*.swift "$dir"/*.o -L "$dir" -lFixStatLegacy -lMacSensors \
        -framework IOKit -framework CoreFoundation -framework Metal \
        -framework CoreMedia -framework CoreVideo "${rpaths[@]}" \
        -o "$dir/FixStat"
    swiftc -target "$target" "${optimize[@]}" -swift-version 6 -module-name fixstat_diskscan \
        Sources/fixstat-diskscan/*.swift "${rpaths[@]}" -o "$dir/fixstat-diskscan"
done

xcrun xcstringstool sync App/Localizable.xcstrings --stringsdata "$strings_dir"/*.stringsdata
python3 scripts/localize.py check

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
lipo -create "$work"/*/FixStat -output "$app/Contents/MacOS/FixStat"
lipo -create "$work"/*/fixstat-diskscan -output "$app/Contents/MacOS/fixstat-diskscan"
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

# Swift runtime for macOS 10.13 – 10.14.3; newer systems use /usr/lib/swift (first rpath).
toolchain="$(dirname "$(dirname "$(xcrun --find swiftc)")")"
for binary in "$app/Contents/MacOS/FixStat" "$app/Contents/MacOS/fixstat-diskscan"; do
    xcrun swift-stdlib-tool --copy --scan-executable "$binary" --platform macosx \
        --source-libraries "$toolchain/lib/swift-5.0/macosx" --destination "$app/Contents/Frameworks" >/dev/null
done

# Only the x86_64 (10.13) slice needs the bundled runtime; a native arm64 debug build has none.
if ls "$app"/Contents/Frameworks/*.dylib >/dev/null 2>&1; then
    codesign --force --sign - "$app"/Contents/Frameworks/*.dylib
else
    rmdir "$app/Contents/Frameworks"
fi
codesign --force --sign - "$app/Contents/MacOS/fixstat-diskscan"
codesign --force --sign - "$app"

echo "built $app"
