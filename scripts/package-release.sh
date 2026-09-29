#!/bin/bash
# Builds FixStat.app and packs it into build/FixStat.dmg, the file README / INSTALL
# tell users to download: a window with FixStat, an Applications shortcut, an arrow
# ("drag into Applications") and INSTALL.txt.
#
#   scripts/package-release.sh
#
# Only macOS tools are used (hdiutil, tiffutil, SetFile, Finder via osascript for the
# window layout). The first run asks to allow controlling Finder. With
# FIXSTAT_DMG_LAYOUT=0 (CI) the layout step is skipped and a plain DMG is built.
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/build-app.sh release

volume="FixStat"
work="$(mktemp -d)"
staging="$work/staging"
rw="$work/rw.dmg"
out="build/FixStat.dmg"
trap 'hdiutil detach "/Volumes/$volume" -quiet 2>/dev/null || true; rm -rf "$work"' EXIT

if [ -d "/Volumes/$volume" ]; then
    echo "A volume named $volume is already mounted; eject it first." >&2
    exit 1
fi

mkdir -p "$staging/.background"
ditto build/FixStat.app "$staging/FixStat.app"
cp packaging/INSTALL.txt "$staging/INSTALL.txt"
ln -s /Applications "$staging/Applications"
cp App/AppIcon.icns "$staging/.VolumeIcon.icns"

# Background at 1× and 2× in one TIFF (sharp on Retina displays).
swiftc -O scripts/svg2png.swift -o "$work/svg2png"
"$work/svg2png" packaging/dmg-background.svg "$work/bg.png" 640 480
"$work/svg2png" packaging/dmg-background.svg "$work/bg@2x.png" 1280 960
tiffutil -cathidpicheck "$work/bg.png" "$work/bg@2x.png" -out "$staging/.background/background.tiff" >/dev/null 2>&1

hdiutil create -quiet -volname "$volume" -srcfolder "$staging" -fs HFS+ -format UDRW -ov "$rw"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$rw"
SetFile -a C "/Volumes/$volume"
# Hidden even where Finder shows hidden files is not possible, so they are also moved
# out of the window below.
SetFile -a V "/Volumes/$volume/.background" "/Volumes/$volume/.VolumeIcon.icns"

if [ "${FIXSTAT_DMG_LAYOUT:-1}" != "0" ]; then
    # Window 640 × 480 pt (the bounds include the 28 pt title bar); positions are icon centres
    # and must match packaging/dmg-background.svg.
    if ! osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$volume"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 840, 628}
        set options to icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to 112
        set text size of options to 13
        set background picture of options to file ".background:background.tiff"
        set position of item "FixStat.app" of container window to {160, 170}
        set position of item "Applications" of container window to {480, 170}
        set position of item "INSTALL.txt" of container window to {320, 380}
        set position of item ".background" of container window to {900, 900}
        set position of item ".VolumeIcon.icns" of container window to {1000, 900}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
    then
        echo "warning: Finder layout failed; the DMG has no custom window" >&2
    fi
fi

chmod -Rf go-w "/Volumes/$volume" || true
rm -rf "/Volumes/$volume/.fseventsd"
sync
hdiutil detach -quiet "/Volumes/$volume"
rm -f "$out"
hdiutil convert -quiet "$rw" -format UDZO -imagekey zlib-level=9 -o "$out"

version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" App/Info.plist)
echo "built $out (FixStat $version, $(du -h "$out" | cut -f1))"
