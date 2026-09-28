#!/usr/bin/env python3
"""Fills and checks App/Localizable.xcstrings.

  scripts/localize.py apply   write translations from scripts/l10n_data.py into the catalog
  scripts/localize.py prune   remove strings marked stale (no longer used in code)
  scripts/localize.py check   fail if any string lacks an English or Turkish value, a
                              string is stale, format specifiers differ, or a sensor id
                              from SensorMaps/sensor-map.json has no catalog entry

The catalog itself is updated from source code by scripts/build-app.sh
(swiftc -emit-localized-strings + xcstringstool sync).
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "App", "Localizable.xcstrings")
SENSOR_MAP = os.path.join(ROOT, "SensorMaps", "sensor-map.json")
LANGUAGES = ["en", "tr"]

sys.path.insert(0, os.path.join(ROOT, "scripts"))
from l10n_data import SENSORS, TR  # noqa: E402

SPEC = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|lf|f)")


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def load():
    with open(CATALOG, encoding="utf-8") as f:
        return json.load(f)


def save(catalog):
    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
        f.write("\n")


def apply():
    catalog = load()
    strings = catalog["strings"]
    for key, value in TR.items():
        entry = strings.setdefault(key, {})
        localizations = entry.setdefault("localizations", {})
        localizations["tr"] = unit(value)
        # xcstringstool adds an English value with positional specifiers for
        # multi-argument keys, marked "new"; it is correct as generated.
        en = localizations.get("en", {}).get("stringUnit")
        if en and en.get("state") == "new":
            en["state"] = "translated"
    for key, (en, tr) in SENSORS.items():
        entry = strings.setdefault(key, {})
        entry["extractionState"] = "manual"
        entry["comment"] = "Sensor name; key = sensor map id. '.n' keys take the index (%lld)."
        entry.setdefault("localizations", {}).update({"en": unit(en), "tr": unit(tr)})
    save(catalog)


def prune():
    catalog = load()
    stale = [k for k, v in catalog["strings"].items() if v.get("extractionState") == "stale"]
    for key in stale:
        del catalog["strings"][key]
    save(catalog)
    print(f"removed {len(stale)} stale string(s)")


def sensor_keys():
    """Catalog keys needed for every id in the sensor map."""
    with open(SENSOR_MAP, encoding="utf-8") as f:
        sensor_map = json.load(f)
    ids = [p["id"] for p in sensor_map.get("patterns", [])]
    for model in sensor_map.get("models", {}).values():
        ids += [s["id"] for s in model.get("sensors", [])]
    for chip in sensor_map.get("chips", {}).values():
        ids += [s["id"] for s in chip.get("sensors", [])]
    keys = set()
    for sensor_id in ids:
        parts = sensor_id.split(".")
        if len(parts) > 1 and (parts[-1].isdigit() or parts[-1].startswith("$")):
            keys.add("sensor." + ".".join(parts[:-1]) + ".n")
        else:
            keys.add("sensor." + sensor_id)
    return keys


def check():
    catalog = load()
    strings = catalog["strings"]
    problems = []
    for key, entry in sorted(strings.items()):
        if entry.get("extractionState") == "stale":
            problems.append(f"stale (no longer used in code, run 'localize.py prune'): {key!r}")
            continue
        if entry.get("shouldTranslate") is False:
            continue
        localizations = entry.get("localizations", {})
        for lang in LANGUAGES:
            loc = localizations.get(lang)
            if loc is None and lang == "en" and not key.startswith("sensor."):
                continue  # English source text is the key
            value = (loc or {}).get("stringUnit", {}).get("value")
            state = (loc or {}).get("stringUnit", {}).get("state")
            if not value or state != "translated":
                problems.append(f"missing {lang}: {key!r}")
                continue
            reference = localizations.get("en", {}).get("stringUnit", {}).get("value", key)
            if sorted(SPEC.findall(value)) != sorted(SPEC.findall(reference)):
                problems.append(f"format specifiers differ in {lang}: {key!r} -> {value!r}")
    for key in sorted(sensor_keys() - set(strings)):
        problems.append(f"sensor id without catalog entry: {key!r}")
    if problems:
        print("localization check failed:", file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        sys.exit(1)
    print(f"localization check passed: {len(strings)} strings, languages {', '.join(LANGUAGES)}")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "check"
    if command == "apply":
        apply()
    elif command == "prune":
        prune()
    elif command == "check":
        check()
    else:
        sys.exit(__doc__)
