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
- **No sudo / root.** No `powermetrics` or other root-only tools. The one approved
  exception is the optional full SSD surface scan (read-only, see Diagnostics tools).
- **MacSensors and CMacSensors must build for macOS 10.13** (Intel) / 11 (Apple Silicon):
  they are compiled for older macOS outside SwiftPM (which raises the deployment target
  to 12) for tools and the planned older-macOS app. Guard newer APIs with `#available` or
  use older equivalents: `ioMainPort` instead of `kIOMainPortDefault`, the pre-10.15
  `FileHandle` methods, no `formatted()` / `.withoutEscapingSlashes` without a check.
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
  to git-ignored `local/sensormap/`. `--quick` (all cores, GPU, SSD, 30 s each, ≈ 3 min)
  gave the same ids for all 64 sensors of the M1 Air and verified 14 of 16 (the other two
  are charger sensors).
- The recording, report and proposal code lives in the library (`SensorRecording`,
  `SensorLoadTests`, `SensorMapReport`, `SensorMapProposer`) so other tools can use it.
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

- One app for macOS 10.13+ (Intel) / 11+ (Apple Silicon). `main.swift` picks the interface:
  macOS 14+ → SwiftUI (`FixStatApp`, every declaration marked `@available(macOS 14.0, *)`);
  older → AppKit (`Sources/FixStatLegacy`, in progress; `--legacy-ui` forces it for
  testing). The AppKit module must work on 10.13: no SwiftUI / Combine / FormatStyle and
  **nothing that calls the Swift concurrency runtime** (missing before macOS 12). It is
  compiled in **Swift 5 mode without actor annotations**: in Swift 6, a `@MainActor`
  class called from AppKit gets main-actor checks that call `MainActor` metadata — weak
  linked, so it loads, but calling it crashed on Big Sur (MacBookAir6,1, macOS 11.7).
  Use target/selector timers. `scripts/simulate-old-macos.sh` runs the x86_64 slice with
  every weak-linked library taken away (Rosetta) and `package-release.sh` refuses to
  package if the AppKit interface does not survive; `scripts/check-weak-imports.sh`
  catches non-weak imports from weak libraries.
- SwiftUI `MenuBarExtra(.window)` + `Settings` scene + tool `Window`s, LSUIElement app.
- `scripts/build-app.sh` compiles with clang/swiftc directly (SwiftPM raises the deployment
  target to 12): x86_64 for 10.13, arm64 for 11, lipo; the Swift runtime for < 10.14.4 is
  copied to Contents/Frameworks (rpath after /usr/lib/swift); frameworks newer than 10.13
  (SwiftUI, Charts, UserNotifications, …) end up weak-linked — check with `otool -L`.
  C functions of frameworks that have a Swift overlay can bind through the overlay: the
  x86_64 (10.13) slice binds `CMSampleBufferGetImageBuffer` /
  `CMVideoFormatDescriptionGetDimensions` to libswiftCoreMedia, which re-exports CoreMedia
  only on recent macOS (the back-deploy copy does not). Fine for the SwiftUI camera test
  (macOS 14+); an AppKit camera test must load them with dlsym from CoreMedia. Check
  `nm -m -arch x86_64 … | grep '(from libswift'` for C symbols after adding such code.
  Building for macOS 11 changes a few SwiftUI defaults (e.g. wider menu buttons): the
  technician footer uses small controls. `swift build` / `swift test` (SwiftPM, macOS 14)
  are for development and tests only.
- `Sources/FixStatCore` holds everything both interfaces share, under the same rules as
  the AppKit module (Swift 5 mode, no actors, 10.13): `MonitorCore`, `Pref`,
  `AlertManager` (rules; delivery through `AlertManager.sender`), `OffStateRecorder`,
  `UnexpectedShutdown`, `DisplaySensor` / `SensorNames`, `Format` and the `*Text` helpers
  (`BatteryText`, `SSDText`, `SleepText`, …). Guard newer Foundation APIs too
  (`UnitInformationStorage` is 10.15+). The x86_64 slice of `build-app.sh` is the check.
- `MonitorCore` polls battery (IORegistry), HID + selected SMC keys and CPU/memory with a
  block timer on the main run loop and calls `onUpdate` after each refresh. The SwiftUI
  `Monitor` (@MainActor @Observable) is a thin wrapper: it copies the core's values,
  assigning only what changed (whole Equatable values) to limit view updates, and keeps
  the session's test results for reports. Panel open → full refresh at the chosen interval; closed → only battery + HID
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
- DMG: `package-release.sh` builds it with hdiutil and lays the window out through Finder
  (osascript; needs Automation permission for Finder once). Finder positions are icon
  centres, but only after the window bounds are set; keep them in sync with
  `packaging/dmg-background.svg`. The disk image holds only FixStat.app, Applications and
  INSTALL.txt: the background is `Contents/Resources/DMGBackground.tiff` in the app (a
  `.background` folder shows where Finder displays hidden files, and moving it out of the
  window made the window scroll to a white area). No custom volume icon for the same
  reason. CI sets `FIXSTAT_DMG_LAYOUT=0` and uploads a DMG without the custom window.

## Battery history

- `BatteryHistoryStore` (library): append-only CSV in the data directory
  (`~/Library/Application Support/FixStat/`, override with `--data-dir DIR`):
  `battery-samples.csv` one line per minute, pruned to 30 days daily;
  `battery-health.csv` one line per day, kept.
- `HistoryView`: ranges 1 h / 3 h / 6 h / 12 h / 1 d / 7 d / 30 d; raw minute samples up to
  6 h, then buckets (≤ ~360 points); reloads every minute while open; hover shows a rule and
  a value card; CSV/JSON export. The sensor report also includes the daily health history.

## Diagnostics tools (Tools menu)

- SSD: NVMe SMART via the NVMeSMARTLib CFPlugIn (no root); write–verify stress test on
  free space (`SSDStressTest`, keeps 10 GB free, speeds from per-block I/O time).
- Full SSD test: `fixstat-diskscan` (in `Contents/MacOS`) reads `/dev/rdiskN` read-only
  (O_RDONLY + F_NOCACHE, 8 MiB chunks, 256 KB re-probe on errors) and writes JSON lines
  that `SurfaceScanResult` parses; then the write–verify test runs on free space.
  - Started as `/usr/bin/sudo -A` with an osascript askpass, **as a child of FixStat**, so
    TCC attributes the raw-disk access to FixStat and its Full Disk Access applies.
    `osascript … with administrator privileges` starts the command through a system
    trampoline instead: EPERM on `/dev/rdisk0` even with Full Disk Access.
  - The askpass prompt is embedded as an AppleScript literal (`system attribute` decodes
    environment variables as Mac Roman → garbled Turkish).
  - Full Disk Access check: open `/Library/Application Support/com.apple.TCC/TCC.db`.
    Ad-hoc signed rebuilds lose the grant; toggle FixStat off/on in System Settings.
- Panic / shutdown history: `.panic` / panic `.ips` in DiagnosticReports (file names
  contain the computer name — never show them); "Previous shutdown cause" from
  `/usr/bin/log` (zsh has a `log` builtin — always use the full path). Code meanings are
  community knowledge, labeled as such.
- Originality check: `SensorMaps/parts.json` (known-genuine reference values) +
  evidence rules in `PartCheck`; verdicts consistent / suspicious / unknown, never "proof".
  macOS' own condition comes from `system_profiler SPPowerDataType -json`.
- Sleep / wake (`SleepAnalysis`, `SleepView`): parses `pmset -g log` (about a week; lines
  are "date +zone Domain(20 cols)\tmessage"; Sleep lines end with the time asleep, charge
  in "(Charge:N%)") and `pmset -g` ("sleep prevented by …"). Drain while asleep = charge
  lost between sleep and the next (dark) wake on battery, sleeps ≥ 30 min. Assertion
  holders are ranked by their longest assertion (they overlap, so sums are meaningless).
- Drain while shut down (`OffStateDrain`): from the log, the last "Charge: N" before a
  shutdown and the first after the boot (wtmp boot / shutdown records via
  `getutxent_wtmp`; `kern.boottime` is not reliable after hibernation); measured by
  `OffStateRecorder`, which saves the gauge's remaining mAh on
  `NSWorkspace.willPowerOffNotification` (also sent for logout: only kept if a boot follows)
  and reads it at the next launch within 15 min of the boot. mAh per hour = mA while off.
  Log-based periods are only flagged with ≥ 3 points of drop (whole percentages).
- Capacity test runs can go to 0 %: samples are appended to `capacity-run.jsonl` in the data
  directory and recovered at the next launch if the Mac turned off (above 5 % that is an
  "unexpected shutdown" finding: the pack could not deliver what the gauge showed); a wake
  during the run ends it (low-battery sleep at ≤ 10 %).
- Unexpected shutdown notification (`UnexpectedShutdown`): at launch within an hour of a boot
  that had no wtmp shutdown record, no panic and no power-button cause, while the log's last
  charge was above 5 % (or the shutdown cause is battery related); once per boot.
- Capacity test (`CapacityResult`, `CapacityTestView`): discharge under a steady load to a
  stop level; delivered mAh / Wh integrated from the gauge's Voltage × Amperage every 5 s;
  compared with the displayed % drop (extrapolated capacity vs. AppleRawMaxCapacity) and
  with the drop of AppleRawCurrentCapacity (gauge agreement); DC pack resistance from the
  load step (Amperage is averaged, so ≥ 60 s after the load starts; shown only, no
  threshold yet); cell spread under load.
- Device card (`DeviceInfo`, `DeviceInfoView`): `system_profiler SPHardwareDataType -json`
  (part number `model_number`, `boot_rom_version`, `activation_lock_status`; serial masked,
  platform UUID / provisioning UDID never read), `profiles status -type enrollment`
  (DEP / MDM), `csrutil status`, `fdesetup status`, `gpu-core-count` of AGXAccelerator —
  all without root. Loaded on demand (`Monitor.loadDeviceInfo`).
- Hardware check (`HardwareCheckView`, model `HardwareCheck`): keyboard (layout from
  `KeyboardLayout` + legends from the current input source via `UCKeyTranslate`, ANSI/ISO
  from `KBGetLayoutType`; key codes of new function-row keys and NX media keys are mapped
  to the F-key positions; keys macOS consumes — F3–F6, volume — only arrive through a
  HID-level `CGEvent` tap: active with Accessibility (blocks them during the test),
  listen-only with Input Monitoring), trackpad (raw contacts from the private
  MultitouchSupport framework via `dlopen` in `multitouch.c`, independent of the
  pointer → 16×10 surface grid; clicks assigned to 3×3 zones by the pressing finger /
  the centre of two fingers; force click / scroll / pinch, haptic pulses), display
  (full-screen colours on the built-in screen), speakers (L/R tones, sweep), microphone
  (level, record + play back), camera (preview, average luma), Wi-Fi (CoreWLAN; scan
  works without Location, names hidden), Bluetooth (`system_profiler` + CoreBluetooth
  scan), ports, lid. Tests fill in evidence and may mark passed; the technician's choice
  always wins. Page 2 of the PDF report when anything was marked.
- Ambient light (`AmbientLightSensor`, `als.c`; test logic `LightCheck`, UI
  `AmbientLightTest.swift`): Apple Silicon lux from the SPU ALS HID service (usage page
  0xFF00 / usage 4, no Product name, event type 12, field 12 << 16); Intel raw channels from
  AppleLMUController selector 0. Guided steps normal → covered → flashlight; the camera's
  average brightness confirms the flashlight, so "no light" (repeat) is told apart from
  "reads dark" (fail). "Automatic brightness" is readable only from the old
  com.apple.iokit.AmbientLightSensor preference; on recent macOS it lives in root-owned
  CoreBrightness preferences and is not shown.
- Ports (`PortReader`): `IOPort` services ("Port-USB-C@1": ConnectionActive,
  TransportsActive, Overcurrent Count, ConnectionCount), USB enumeration failures from
  `AppleUSBHostPort` `port-statistics`, devices below `UsbCPortNumber`, and
  AppleSmartBattery `PortControllerInfo[n-1]` (charging = active contract; short detect,
  PD hard reset, input FET and I²C error counters). `IOPortFeaturePowerIn.Active` stayed
  false while charging on M1 / macOS 26.
- Lid: `IOPMrootDomain.AppleClamshellState` polled, plus the last `pmset -g log` sleep
  reason ("Clamshell Sleep") after a wake. No lid angle sensor on MacBookAir10,1.
- USB-C PD: the active profile is macOS' selection (`AdapterDetails.UsbHvcMenu` /
  `UsbHvcHvcIndex`); the port controller's RDO can lag (showed 5 V while charging at 20 V).

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
- Code that also runs before macOS 12 (FixStatCore, FixStatLegacy) uses `L("key", args…)`
  instead of `String(localized:)`, with the key exactly as the compiler would extract it
  (`%@` for strings, `%lld` for Int; no interpolation inside `L()`).
  `scripts/extract-strings.py` adds those keys to the catalog sync.
- Numbers, percentages, durations and units via `Format` (FormatStyle / `Measurement`,
  with NumberFormatter / MeasurementFormatter fallbacks before macOS 12), never
  hand-written format strings. Formatting follows the user's region, not the UI
  language; check English formatting with `-AppleLocale en_US`.
- CLI output (`sensordump`, `sensormap`) is English only.

## Build / run / check

```
swift build
swift test
.build/debug/sensordump [--json] [--raw] [--smc-all] [--hid-power] [--all] [--include-serial]
scripts/build-app.sh            # → build/FixStat.app (ad-hoc signed; release = universal arm64 + x86_64)
scripts/package-release.sh      # → build/FixStat.dmg (drag-to-Applications window + INSTALL.txt) for Releases
scripts/make-artwork.sh         # App/AppIcon.svg → AppIcon.icns, packaging/dmg-background.svg → App/DMGBackground.tiff
open build/FixStat.app
# Render the panel, a Settings tab or the history window to PNG (no screen recording needed;
# NavigationSplitView windows such as --hardware do not render this way, use a screenshot):
build/FixStat.app/Contents/MacOS/FixStat --snapshot out.png [--technician] [--settings 0|1|2] \
    [--history [--range 0…6] --data-dir DIR] [--dark|--light] -AppleLanguages "(tr)" [-AppleLocale en_US]
# Write the report (same as "Export report") and exit:
build/FixStat.app/Contents/MacOS/FixStat --export report.csv|report.json|report.pdf [--sample-check]
```

## Repository layout

```
.
├── CLAUDE.md                   this file
├── .githooks/pre-commit        privacy check hook
├── scripts/privacy-scan.sh     privacy scanner (--staged / --history / files)
├── scripts/build-app.sh        builds build/FixStat.app
├── scripts/package-release.sh  builds build/FixStat.dmg for GitHub Releases
├── packaging/INSTALL.txt       plain-text install notes (en + tr) shipped in the DMG
├── packaging/dmg-background.svg  DMG window background (arrow, en + tr hint)
├── scripts/localize.py         catalog apply / prune / check (+ l10n_data.py)
├── Package.swift               SPM: CMacSensors, MacSensors, sensordump, sensormap, fixstat-diskscan,
│                               FixStatCore, FixStatLegacy, FixStat, tests
├── Sources/CMacSensors/        C shims: read-only AppleSMC user client, private HID event API,
│                               NVMe SMART, MultitouchSupport contacts
├── Sources/MacSensors/         SMC, HID, battery, ports, system info, sensor map, history store, masking
├── Sources/sensordump/         CLI dump
├── Sources/sensormap/          load tests, report, map proposal
├── Sources/fixstat-diskscan/   read-only raw disk surface scan (full SSD test, runs as root)
├── Sources/FixStat/            SwiftUI menu bar app (macOS 14+) and main.swift
├── Sources/FixStatCore/        shared by both interfaces: MonitorCore, Pref, alerts, texts, Format
├── Sources/FixStatLegacy/      AppKit interface for macOS 10.13 – 13 (Swift 5 mode)
├── Tests/MacSensorsTests/      swift-testing unit tests
├── SensorMaps/sensor-map.json  sensor naming database
├── App/                        Info.plist, Localizable.xcstrings, AppIcon.svg / .icns, DMGBackground.tiff
├── examples/                   masked sample outputs per model
├── docs/screenshots/{en,tr}/   README screenshots (made with --snapshot)
└── design/                     early UI mockups (internal reference, Turkish)
```

## Documentation

- Keep `README.md` and `README.tr.md` in sync, including the verified models table.
  The same applies to `INSTALL.md` / `INSTALL.tr.md` and the bilingual
  `packaging/INSTALL.txt` (user-facing installation steps).
- Screenshots: English ones in README.md, Turkish ones in README.tr.md; check every
  screenshot by eye for serial numbers and user names before committing. The history
  screenshot uses synthetic sample data and is captioned as such.

## Roadmap

- Support for older macOS versions (down to 10.13 High Sierra). SwiftUI does not exist
  before 10.15, so this needs an AppKit UI; testing requires real Intel Macs.
