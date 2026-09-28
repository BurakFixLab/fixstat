# Contributing to FixStat

Thanks for helping! The most valuable contributions are **sensor maps for Mac models**
that are not verified yet, and **translations**.

## Ground rules

- **Read-only hardware access.** Never add code that writes to the SMC (no fan control,
  no charge limits). No features that need `sudo`.
- **No personal data in the repository.** Serial numbers, UUIDs and paths containing a
  user name must never be committed. Enable the hook once per clone:
  ```bash
  git config core.hooksPath .githooks
  ```
  It runs `scripts/privacy-scan.sh` on every commit and blocks serial-number-like values,
  including the actual serials of the Mac you commit from. Screenshots are not scanned —
  check them yourself.
- **No new dependencies** without discussing it in an issue first.
- **User-visible text** comes from the string catalog (see below); numbers and units are
  formatted with `FormatStyle` / `Measurement`, never with hand-written format strings.

## Adding a Mac model

You need the Mac itself, about 20 minutes, and its power adapter.

1. **Build the tools**
   ```bash
   swift build -c release
   ```
2. **Dump the sensors** (serial numbers are masked by default — never share output made
   with `--include-serial`):
   ```bash
   .build/release/sensordump > "examples/sensordump-$(sysctl -n hw.model).txt"
   ```
3. **Record the load tests.** Quit other apps and leave the Mac alone while it runs.
   The charger test plays a sound when you should unplug and re-plug the adapter.
   ```bash
   .build/release/sensormap record --tests single,all,gpu,ssd,charger --duration 60 --baseline 60
   ```
   Recordings are written to `local/sensormap/` (ignored by git). You can record several
   times, e.g. the charger test separately with `--tests charger`.
4. **Look at the result**
   ```bash
   .build/release/sensormap report local/sensormap/*.json
   ```
   Each column is the rise in °C during one test. SMC keys that read the same physical
   sensor as a HID service are detected automatically.
5. **Propose the map entry**
   ```bash
   .build/release/sensormap propose local/sensormap/*.json --write SensorMaps/sensor-map.json
   ```
   `verified` is set only when the test that matches the sensor's group caused a rise of
   at least 1.5 °C and at least 90 % of its strongest rise (cpu → CPU tests, gpu → GPU,
   ssd → SSD, battery / charger → charging). Everything else is `estimated`.
6. **Review the entry by hand** in `SensorMaps/sensor-map.json`:
   - Apple Silicon CPU/GPU die sensors are thermal zones of a cluster: use
     `cpu.pcluster.N`, `cpu.ecluster.N`, `gpu.cluster.N` — never per-core names.
   - PMU channels keep their hardware numbers (`pmu.ntc.3` = `PMU tdev3`).
   - Keys that are never plausible or constant go into `ignored`; SMC aggregates of other
     sensors (Apple Silicon `Tp2a/b/x/z`, `Tc*`) into `derived`.
   - Downgrade anything you are not sure about to `estimated`. The `note` field should
     say how the mapping was decided.
7. **Names for new ids.** Sensor names live in the string catalog, keyed by the id:
   `sensor.<id base>` or, for numbered ids, `sensor.<id base>.n` with one `%lld`. Add
   English and Turkish names to `SENSORS` in `scripts/l10n_data.py`, then:
   ```bash
   python3 scripts/localize.py apply
   python3 scripts/localize.py check
   ```
8. **Check and submit**
   ```bash
   .build/release/sensormap report local/sensormap/*.json > "examples/sensormap-report-$(sysctl -n hw.model).txt"
   swift test
   scripts/build-app.sh
   ```
   Add the model to the "Verified models" tables in `README.md` and `README.tr.md` and
   open a pull request.

Can't build it yourself? Open a
[new model sensor data](../../issues/new?template=new-model-sensor-data.yml) issue with
the masked `sensordump` output.

## Adding a language

1. Add the language code to `CFBundleLocalizations` in `App/Info.plist` and to
   `LANGUAGES` in `scripts/localize.py`.
2. Open `App/Localizable.xcstrings` in Xcode (String Catalog editor), add the language
   and translate every string, including the `sensor.*` keys. Keep the format
   specifiers exactly: `%@`, `%lld`, and positional ones like `%1$@` / `%2$lld`.
3. Build:
   ```bash
   scripts/build-app.sh
   ```
   The build fails and lists the keys if any translation is missing.
4. Check the UI in the new language without changing your system language:
   ```bash
   build/FixStat.app/Contents/MacOS/FixStat --snapshot /tmp/panel.png -AppleLanguages "(de)"
   build/FixStat.app/Contents/MacOS/FixStat --snapshot /tmp/tech.png --technician -AppleLanguages "(de)"
   ```

How the catalog is maintained: English UI strings are the keys and are extracted from
the code by the compiler during `scripts/build-app.sh`. The Turkish values are kept in
`scripts/l10n_data.py` and written with `localize.py apply`; other languages are edited
directly in the catalog.

## Code overview

| Path | What |
|---|---|
| `Sources/CMacSensors` | C shims: read-only AppleSMC user client, private IOHID event API |
| `Sources/MacSensors` | Battery (IORegistry), SMC and HID readers, sensor map, history store |
| `Sources/sensordump` | CLI dump |
| `Sources/sensormap` | Load tests, report, map proposal |
| `Sources/FixStat` | SwiftUI menu bar app |
| `SensorMaps/sensor-map.json` | Sensor naming database |
| `App/` | Info.plist and string catalog |
