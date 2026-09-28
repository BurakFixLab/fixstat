# FixStat — notes for AI coding assistants

FixStat is a free, open-source macOS menu bar monitor (an iStat Menus / Stats
alternative) for board-level Mac repair technicians. Its key differentiator is
**model-specific, verified sensor names** instead of raw SMC/HID keys, plus
technician-grade battery data. See `README.md` for the user-facing description and
`CONTRIBUTING.md` for contributor workflows.

Personal, machine-specific notes may exist in a git-ignored `CLAUDE.local.md`.

## Hard rules

- **Never write to the SMC.** Read-only access only. Fan control, charge limits and
  anything else that needs SMC writes is out of scope. The C shim implements only the
  key-info, read-bytes and read-index commands and rejects everything else.
- **No sudo / root.** No `powermetrics` or other root-only tools.
- Private APIs are allowed (no App Store, no sandbox): `IOHIDEventSystemClient` for Apple
  Silicon temperatures, the `AppleSMC` user client (read-only) for SMC keys.
- No new dependencies (brew, SPM packages, code generators) without discussing it first.
- Reference code: `exelban/stats` (MIT). If code is ever copied or adapted, keep its
  license notice and cite the source file in a comment and in the README.
- Code, code comments and commit messages are in English.

## Privacy (very important)

- Never commit battery serials, device serials, UUIDs, or paths containing a user name.
  Example outputs and test data must be masked.
- Serial numbers are masked in every output (first 3 characters kept, the rest `*`);
  shown only with `sensordump --include-serial`, never in exported reports.
- Pre-commit hook: `.githooks/pre-commit` → `scripts/privacy-scan.sh --staged`
  (enable with `git config core.hooksPath .githooks`). It reads the current Mac's
  serials / UUID from ioreg at runtime, so the literal values are never stored, and
  checks generic patterns: UUIDs, unmasked `Serial*`/`UUID` keys, Apple-style serial
  tokens (10–12 / 17–18 chars), `/Users/<name>/` paths. Escape hatch: `privacy:allow`
  on the line. Binary files (screenshots) are not scanned — check them by eye.
- `scripts/privacy-scan.sh --history` scans every commit.

## Sensor naming

Apple Silicon CPU/GPU die sensors measure **thermal zones within a cluster**, not
individual cores. Never name them per core ("P-core 1"). Use ids like
`cpu.pcluster.1`, `cpu.ecluster.2`, `gpu.cluster.1` with display names like
"Performance cluster 1" / "Performans kümesi 1".

## Sensor map (`SensorMaps/sensor-map.json`)

- `models` (keyed by `hw.model`) + `chips` (keyed by `machdep.cpu.brand_string`) +
  `patterns` (regex on the raw key and/or HID name; `$1` captures in the id).
- Lookup is layered, first match wins: **model** entry (`verified` or `estimated`) →
  **chip** entry (always estimated) → **pattern** (always estimated). A model entry
  always wins. Unmatched sensors are listed separately with their raw names.
- Model entries also carry `ignored` (never plausible / constant calibration keys) and
  `derived` (SMC aggregates of other sensors, e.g. Apple Silicon `Tp2a/b/x/z`, `Tc*`);
  both appear only in raw lists and are never polled by the app.
- The id is the localization key; display names are not stored in the JSON.
- Ids are renumbered 1…n per base (`cpu.pcluster.1…7`), except PMU channels, which keep
  hardware numbers (`pmu.ntc.3` = "PMU tdev3").
- A user's own map (`~/Library/Application Support/FixStat/sensor-map.json`) is layered on
  top; `Entry.name` holds user-defined display names.

## Sensor mapping tool (`sensormap`)

- `sensormap record`: idle baseline, single/all-core CPU, Metal GPU, SSD write/read and a
  charger unplug/replug test; samples every HID and SMC temperature at 1 Hz; recordings go
  to git-ignored `local/sensormap/`.
- `sensormap report FILE...`: per-sensor rise for each test.
- `sensormap propose FILE... [--write SensorMaps/sensor-map.json]`: names from pattern rules;
  `verified` only when the test matching the group gave ≥ 1.5 °C and ≥ 90 % of the sensor's
  strongest rise (cpu → single/all, gpu → gpu, ssd → ssd, battery → charging,
  board.charger/psu → charging); everything else `estimated`. SMC keys that read the same
  physical sensor as a HID service are noted as aliases. Hand review is expected.

## Hardware findings (reference machine: MacBookAir10,1 / M1, macOS 26)

- SMC works on Apple Silicon via the `AppleSMC` user client (≈1500 keys, ≈150 `T*`).
  Types: `flt ` (little-endian float), `ioft` (8-byte LE 48.16 fixed point), `ui*`/`si*`
  big endian, `fpXY`/`spXY` fixed point. `#KEY` is `ui32`.
- **HID `LocationID` = SMC key FourCC** (e.g. "gas gauge battery" → `TG0B`,
  "pACC MTR Temp Sensor2" → `Tp2i`, "PMU tdie1" → `TP1l`, "NAND CH0 temp" → `TN0n`).
- PMU `tdev` channels are board NTCs; SMC keys give them meaning. Aliases found on M1:
  TCHP=TP7d (charger), TW0P=TP4d (Wi-Fi), TIOP=TP3d (I/O), TPMP=TP5d (PMU), TMVR=TP8d
  (memory VR), TPSP=TR5d (power input), TSCD=TR4d, TH0T/TH0x=TR2d (SSD), TB2T=TG2B.
- Unpopulated NTC channels read ≈ −22 °C and are listed as `ignored`.
- HID power page (0xff08) voltage/current events return implausible raw values; they are
  behind `sensordump --hid-power` and marked experimental.
- Battery (`AppleSmartBattery`): health = `AppleRawMaxCapacity / DesignCapacity`;
  `CurrentCapacity/MaxCapacity` is % on Apple Silicon and mAh on Intel (the ratio works
  for both). Cell voltages in `BatteryData.CellVoltage`.
- Real adapter input power is `PowerTelemetryData.SystemPowerIn` (Apple Silicon only).
  Telemetry `BatteryPower` is negative both while charging and discharging, and
  `SystemLoad` = SystemPowerIn − BatteryPower, so neither is used directly; system power
  is derived as input − battery V×I − AdapterEfficiencyLoss.
- Cell spread grows while charging near the top of charge (≈ 100 mV is possible on an aged
  pack), hence the default imbalance warning threshold of 50 mV.

## App architecture (`Sources/FixStat`)

- SwiftUI `MenuBarExtra(.window)` + `Settings` scene + battery history `Window`,
  LSUIElement app, built as an SPM executable; `scripts/build-app.sh` assembles the bundle
  (no Xcode project). Currently requires macOS 14.
- `Monitor` (@MainActor @Observable) polls battery (IORegistry), HID + selected SMC keys and
  CPU/memory. It assigns whole Equatable values (no in-place mutation) to limit view
  updates. Panel open → full refresh at the chosen interval; closed → only battery + HID
  (menu bar CPU temperature), at most every 5 s, timer tolerance 20 %. Battery history is
  recorded every 60 s regardless.
- Menu bar CPU temperature = hottest `cpu` group sensor.
- Appearance setting (System / Light / Dark) sets `NSApp.appearance`;
  `AppearancePreference.apply()` must tolerate `NSApp == nil` (UserDefaults notifications
  can arrive before NSApplication exists).
- MenuBarExtra pitfalls (all handled):
  - a ScrollView in the panel has no ideal height and collapses → explicit heights;
  - `onDisappear` is not reliably called when the panel closes, and the window grows but
    never shrinks, resizing from the bottom → `PanelWindowObserver` uses the window's
    occlusion state for visibility and fits the window to the content with the top edge
    fixed, also on every opening;
  - hiding the panel window with `orderOut` desyncs MenuBarExtra → close it with
    `performClick` on the `NSStatusBarButton`;
  - windows opened from the panel must be brought to the front explicitly.
- UI testing: use real mouse events (CGEvent); an AXPress is not user-initiated, so macOS
  does not activate the app.

## Battery history

- `BatteryHistoryStore` (library): append-only CSV in the data directory
  (`~/Library/Application Support/FixStat/`, override with `--data-dir DIR`):
  `battery-samples.csv` one line per minute, pruned to 30 days daily;
  `battery-health.csv` one line per day, kept.
- `HistoryView`: ranges 1 h / 3 h / 6 h / 12 h / 1 d / 7 d / 30 d; raw minute samples up to
  6 h, then buckets (≤ ~360 points); reloads every minute while open; hover shows a rule and
  a value card; CSV/JSON export. The sensor report also includes the daily health history.

## Localization

- Apple String Catalog `App/Localizable.xcstrings`; development language English, plus
  Turkish. Follows the system language; no in-app language menu.
- No user-visible hard-coded strings; everything comes from the catalog. UI keys are the
  English source text, extracted by the compiler (`-emit-localized-strings`) and merged
  with `xcstringstool sync` in `build-app.sh`. Multi-argument strings use positional
  specifiers (`%1$@`) in every language.
- Sensor names: manual keys `sensor.<id base>` or `sensor.<id base>.n` (one `%lld`).
- Turkish values and sensor names live in `scripts/l10n_data.py`; `scripts/localize.py
  apply` writes them, `prune` removes stale keys, `check` fails on missing values, stale
  keys, mismatched specifiers or sensor ids without a key. `build-app.sh` runs `check`.
- Numbers, percentages, durations and units via `FormatStyle` / `Measurement`, never
  hand-written format strings. Formatting follows the user's region, not the UI
  language; check English formatting with `-AppleLocale en_US`.
- CLI output (`sensordump`, `sensormap`) is English only.

## Build / run / check

```
swift build
swift test
.build/debug/sensordump [--json] [--raw] [--smc-all] [--hid-power] [--all] [--include-serial]
scripts/build-app.sh            # → build/FixStat.app (ad-hoc signed)
open build/FixStat.app
# Render the panel, a Settings tab or the history window to PNG (no screen recording needed):
build/FixStat.app/Contents/MacOS/FixStat --snapshot out.png [--technician] [--settings 0|1|2] \
    [--history [--range 0…6] --data-dir DIR] [--dark|--light] -AppleLanguages "(tr)" [-AppleLocale en_US]
# Write the report (same as "Export report") and exit:
build/FixStat.app/Contents/MacOS/FixStat --export report.csv|report.json
```

## Repository layout

```
.
├── CLAUDE.md                   this file
├── .githooks/pre-commit        privacy check hook
├── scripts/privacy-scan.sh     privacy scanner (--staged / --history / files)
├── scripts/build-app.sh        builds build/FixStat.app
├── scripts/localize.py         catalog apply / prune / check (+ l10n_data.py)
├── Package.swift               SPM: CMacSensors, MacSensors, sensordump, sensormap, FixStat, tests
├── Sources/CMacSensors/        C shims: read-only AppleSMC user client, private HID event API
├── Sources/MacSensors/         SMC, HID, battery, system info, sensor map, history store, masking
├── Sources/sensordump/         CLI dump
├── Sources/sensormap/          load tests, report, map proposal
├── Sources/FixStat/            SwiftUI menu bar app
├── Tests/MacSensorsTests/      swift-testing unit tests
├── SensorMaps/sensor-map.json  sensor naming database
├── App/                        Info.plist, Localizable.xcstrings
├── examples/                   masked sample outputs per model
├── docs/screenshots/{en,tr}/   README screenshots (made with --snapshot)
└── design/                     early UI mockups (internal reference, Turkish)
```

## Documentation

- Keep `README.md` and `README.tr.md` in sync, including the verified models table.
- Screenshots: English ones in README.md, Turkish ones in README.tr.md; check every
  screenshot by eye for serial numbers and user names before committing. The history
  screenshot uses synthetic sample data and is captioned as such.

## Roadmap

- Support for older macOS versions (down to 10.13 High Sierra). SwiftUI does not exist
  before 10.15, so this needs an AppKit UI; testing requires real Intel Macs.
