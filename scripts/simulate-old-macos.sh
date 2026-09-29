#!/bin/bash
# Runs a copy of FixStat as if every weak-linked library (Swift concurrency, SwiftUI,
# Charts, Observation, … — missing on older macOS) were absent: their load commands point
# to a non-existent path. Catches calls into them from code that must work on macOS
# 10.13 – 13 (the AppKit interface), which dyld only reports when the call happens.
#
#   scripts/simulate-old-macos.sh [APP] [-- ARGS…]     (default build/FixStat.app, --legacy-ui)
#
# Prints "still running after 6 s" when the app survived its launch, or dyld's error.
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-build/FixStat.app}"
shift || true
[ "${1:-}" = "--" ] && shift
args=("$@")
[ ${#args[@]} -eq 0 ] && args=(--legacy-ui)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -R "$app" "$work/FixStat.app"
binary="$work/FixStat.app/Contents/MacOS/FixStat"
# Every weak-linked library: absent on macOS 10.13 – 11 or newer than the deployment target.
for lib in $(otool -arch x86_64 -l "$binary" | awk '/LC_LOAD_WEAK_DYLIB/{getline; getline; print $2}'); do
    install_name_tool -change "$lib" "/nonexistent/$(basename "$lib")" "$binary" 2>/dev/null
done
codesign --force --sign - "$work/FixStat.app" >/dev/null 2>&1
arch -x86_64 "$binary" "${args[@]}" > "$work/out.txt" 2>&1 &
pid=$!
sleep 6
if kill -0 "$pid" 2>/dev/null; then
    echo "still running after 6 s"
    kill "$pid"
else
    wait "$pid" || true
    echo "exited:"; tail -5 "$work/out.txt"
fi
