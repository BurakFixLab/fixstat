#!/bin/bash
# Builds FixStat.app and packs it into build/FixStat.dmg, the file README / INSTALL
# tell users to download: a window with FixStat, an Applications shortcut, an arrow
# ("drag into Applications") and INSTALL.txt.
#
#   scripts/package-release.sh
#
# Only macOS tools are used (hdiutil, Finder via osascript for the window layout). The first run asks to allow controlling Finder. With
# FIXSTAT_DMG_LAYOUT=0 (CI) the layout step is skipped and a plain DMG is built.
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/build-app.sh release

# The AppKit interface must start on macOS 10.13 – 13: run it with every library that is
# missing there taken away (needs Rosetta on Apple Silicon; skipped where unavailable).
if arch -x86_64 /usr/bin/true 2>/dev/null; then
    result="$(scripts/simulate-old-macos.sh build/FixStat.app 2>&1 | grep -v Terminated)"
    echo "old macOS simulation: $result"
    case "$result" in *"still running"*) ;; *) echo "error: the AppKit interface does not start without the newer libraries" >&2; exit 1 ;; esac
fi
scripts/check-weak-imports.sh build/FixStat.app/Contents/MacOS/FixStat x86_64

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

# Only these three items: no hidden helper files, so the window has nothing to scroll to
# and nothing extra shows where Finder displays hidden files. The background picture is
# App/DMGBackground.tiff inside the app bundle (scripts/make-artwork.sh).
mkdir -p "$staging"
ditto build/FixStat.app "$staging/FixStat.app"
cp packaging/INSTALL.txt "$staging/INSTALL.txt"
ln -s /Applications "$staging/Applications"

hdiutil create -quiet -volname "$volume" -srcfolder "$staging" -fs HFS+ -format UDRW -ov "$rw"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$rw"

if [ "${FIXSTAT_DMG_LAYOUT:-1}" != "0" ]; then
    # Window 640 × 480 pt (the bounds include the 28 pt title bar); positions are icon centres
    # and must match packaging/dmg-background.svg. Finder adds a margin below the lowest
    # label: keep it about 60 pt above the bottom edge, or the window scrolls a little.
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
        set background picture of options to file "FixStat.app:Contents:Resources:DMGBackground.tiff"
        set position of item "FixStat.app" of container window to {160, 150}
        set position of item "Applications" of container window to {480, 150}
        set position of item "INSTALL.txt" of container window to {320, 340}
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
