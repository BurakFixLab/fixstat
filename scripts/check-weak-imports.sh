#!/bin/bash
# Fails if a binary imports a symbol non-weakly from a weak-linked library.
#
#   scripts/check-weak-imports.sh BINARY [ARCH]     (default ARCH: x86_64)
#
# Libraries newer than the deployment target (SwiftUI, Charts, libswift_Concurrency, …) are
# weak-linked, so the app still loads on older macOS. A non-weak symbol from such a library
# makes dyld abort as soon as that symbol is bound — at launch or at the first call — on a
# system without the library (FixStat 1.1 development: MainActor metadata on Big Sur).
set -euo pipefail
binary="$1"
arch="${2:-x86_64}"
weak_libs=$(otool -arch "$arch" -l "$binary" | awk '/LC_LOAD_WEAK_DYLIB/{getline; getline; print $2}' \
    | sed -E 's|.*/||; s|\.dylib$||' | sort -u)
bad=$(nm -m -arch "$arch" "$binary" | grep '(undefined)' | grep -v ' weak ' | while read -r line; do
    lib=$(echo "$line" | sed -nE 's/.*\(from ([^)]*)\)$/\1/p')
    for weak in $weak_libs; do
        if [ "$lib" = "$weak" ]; then echo "$line"; fi
    done
done)
if [ -n "$bad" ]; then
    echo "error: non-weak imports from weak-linked libraries ($arch):" >&2
    echo "$bad" | sed -E 's/^ +/  /' | head -40 >&2
    exit 1
fi
echo "weak imports ok ($arch)"
