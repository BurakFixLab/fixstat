#!/bin/bash
# Runs a copy of FixStat as if every weak-linked library (Swift concurrency, SwiftUI,
# Charts, Observation, … — missing on older macOS) were absent: their load commands point
# to a non-existent path. Catches calls into them from code that must work on macOS
# 10.13 – 13 (the AppKit interface), which dyld only reports when the call happens.
#
#   scripts/simulate-old-macos.sh [APP] [-- ARGS…]     (default build/FixStat.app, --legacy-ui)
#
# Prints "still running after 6 s" when the app survived its launch, or dyld's error.
# SIM_WAIT=SECONDS changes the 6 s (the run ends earlier when the app exits by itself).
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
# The copy runs under Rosetta, which macOS 26 announces ("Intel app"). Give it its own name
# and bundle id, so that notice names the test copy and it keeps its own preferences.
plist="$work/FixStat.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier io.github.burakfixlab.fixstat.rosetta-test" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName FixStat Rosetta test" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string FixStat Rosetta test" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName FixStat Rosetta test" "$plist"
# Every weak-linked library: absent on macOS 10.13 – 11 or newer than the deployment target.
for lib in $(otool -arch x86_64 -l "$binary" | awk '/LC_LOAD_WEAK_DYLIB/{getline; getline; print $2}'); do
    install_name_tool -change "$lib" "/nonexistent/$(basename "$lib")" "$binary" 2>/dev/null
done
codesign --force --sign - "$work/FixStat.app" >/dev/null 2>&1
arch -x86_64 "$binary" "${args[@]}" > "$work/out.txt" 2>&1 &
pid=$!
# SIM_WAIT=SECONDS for runs that take longer (e.g. --export report.pdf under Rosetta).
wait_seconds="${SIM_WAIT:-6}"
for _ in $(seq 1 "$wait_seconds"); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
done
if kill -0 "$pid" 2>/dev/null; then
    echo "still running after $wait_seconds s"
    kill "$pid"
else
    wait "$pid" || true
    echo "exited:"; tail -5 "$work/out.txt"
fi
