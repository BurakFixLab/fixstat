#!/usr/bin/env python3
"""Writes .stringsdata files for the L("…") calls of the modules that also run on macOS
10.13 – 11 (Sources/FixStatCore, Sources/FixStatLegacy).

The compiler's -emit-localized-strings only extracts String(localized:) / SwiftUI text,
which needs macOS 12; those modules use L() → NSLocalizedString instead. Without this
file the catalog would mark their keys stale and `localize.py prune` would drop them.

    scripts/extract-strings.py STRINGS_DIR
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULES = ["Sources/FixStatCore", "Sources/FixStatLegacy"]
CALL = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)*)"')


def unescape(literal: str) -> str:
    out, i = [], 0
    while i < len(literal):
        c = literal[i]
        if c == "\\" and i + 1 < len(literal):
            n = literal[i + 1]
            if n == "u" and literal[i + 2:i + 3] == "{":
                end = literal.index("}", i)
                out.append(chr(int(literal[i + 3:end], 16)))
                i = end + 1
                continue
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'", "0": "\0"}.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def main() -> int:
    target = Path(sys.argv[1])
    target.mkdir(parents=True, exist_ok=True)
    errors = 0
    for module in MODULES:
        for source in sorted((ROOT / module).glob("*.swift")):
            entries = []
            for number, line in enumerate(source.read_text(encoding="utf-8").splitlines(), 1):
                if line.lstrip().startswith("//"):
                    continue  # documentation examples such as L("…")
                for match in CALL.finditer(line):
                    literal = match.group(1)
                    if "\\(" in literal:
                        print(f"{source.relative_to(ROOT)}:{number}: L() key must not interpolate", file=sys.stderr)
                        errors += 1
                        continue
                    entries.append({"comment": "", "key": unescape(literal),
                                    "location": {"startingColumn": match.start() + 1, "startingLine": number}})
            if entries:
                data = {"source": str(source.relative_to(ROOT)), "tables": {"Localizable": entries}, "version": 1}
                (target / f"{source.stem}-L.stringsdata").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
