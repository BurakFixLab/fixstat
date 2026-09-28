#!/bin/bash
# Builds FixStat.app and packs it with the installation notes into
# build/FixStat.zip (the file README / INSTALL tell users to download).
#
#   scripts/package-release.sh
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/build-app.sh release

staging="build/package"
rm -rf "$staging" build/FixStat.zip
mkdir -p "$staging"
# ditto keeps the bundle intact; extended attributes are left out (no __MACOSX
# entries). The code signature does not depend on them.
ditto build/FixStat.app "$staging/FixStat.app"
cp packaging/INSTALL.txt "$staging/INSTALL.txt"
(cd "$staging" && ditto -c -k --norsrc --noextattr --noacl . ../FixStat.zip)
rm -rf "$staging"

version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" App/Info.plist)
echo "built build/FixStat.zip (FixStat $version)"
unzip -l build/FixStat.zip | tail -n +4 | grep -E 'INSTALL|Info.plist|MacOS/FixStat$' || true
