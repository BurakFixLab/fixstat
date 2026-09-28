# FixStat

**A free, open-source menu bar monitor for macOS, built for board-level Mac repair.**

[Türkçe](README.tr.md)

FixStat shows battery, temperature, fan and system data in the menu bar — with
sensor names that were verified per Mac model, and a technician mode with the raw
battery gauge data you normally dig out of `ioreg`.

| Default | Technician mode |
|---|---|
| ![Default panel](docs/screenshots/en/panel-light.png) | ![Technician mode](docs/screenshots/en/technician-dark.png) |

![Battery history (sample data)](docs/screenshots/en/history.png)
<sub>Battery history window, shown with sample data.</sub>

## How it differs from Stats and iStat Menus

- **Model-specific, verified sensor names.** Other monitors show raw keys
  (`Tp09`, `TG0B`, `PMU tdev7`) or one generic list for all Macs. FixStat keeps a
  per-model [sensor map](SensorMaps/sensor-map.json). Each entry was found with load
  tests (single core, all cores, GPU, SSD, charger) and is marked **verified** when a
  test confirmed it, or **estimated** otherwise — the UI says which is which.
- **Layered lookup.** Model entry first, then an entry for the same chip, then a guess
  from the key pattern (`Tp`, `Te`, `Tg`, `TB`, `TH`, `NAND`, `PMU tdie` …). Chip and
  pattern names are always shown as estimated. Apple Silicon die sensors are named as
  thermal zones of a cluster ("Performance cluster 3"), not as individual cores.
- **Technician mode.** Design and raw maximum capacity, health to one decimal, cycle
  count, signed current, voltage, cell voltages with an imbalance warning, the
  adapter's rating and what it actually delivers right now (`SystemPowerIn`), every
  sensor with its raw SMC / HID key, and the unmatched sensors in a separate list.
- **Board-level details.** HID sensors are joined with their SMC keys (the HID
  `LocationID` is the SMC key), so e.g. `TCHP` shows up as the charger-side NTC read
  through `PMU tdev7`.
- **Battery history.** Charge, current and health from the last hour up to 30 days,
  plus a daily health log that is kept indefinitely.
- **Reports.** CSV / JSON export for customer devices, serial numbers always masked.
- **Read-only.** FixStat never writes to the SMC, has no fan control and needs no
  administrator rights.

## Verified models

| Model identifier | Mac | Chip | Board | Sensors named | Verified by test | macOS |
|---|---|---|---|---|---|---|
| `MacBookAir10,1` | MacBook Air (M1, 2020) | Apple M1 | J313 | 64 of 69 | 16 | 26.6 |

Other Macs work too: sensors are then named from chip and key patterns and marked as
estimated. Please help add your model — see [CONTRIBUTING.md](CONTRIBUTING.md) or open a
[new model issue](../../issues/new?template=new-model-sensor-data.yml).

## Installation

### Download

1. Download `FixStat.zip` from [Releases](../../releases) and move `FixStat.app` to
   `/Applications`.
2. FixStat is not notarized by Apple (that needs a paid developer account), so macOS
   blocks the first launch. Open the app once, then go to **System Settings › Privacy &
   Security** and click **Open Anyway** next to the FixStat message.
   Alternatively, in Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/FixStat.app
   ```
3. FixStat lives in the menu bar (no Dock icon). **Open at login** is in its settings.

### Build from source

Requires macOS 14 or later and Xcode 16 or later (Swift 6). No other tools.

```bash
git clone https://github.com/BurakFixLab/fixstat.git
cd fixstat
git config core.hooksPath .githooks   # privacy check before each commit
scripts/build-app.sh                  # builds build/FixStat.app
open build/FixStat.app
```

## Command-line tools

```bash
swift build -c release
.build/release/sensordump             # battery, temperatures, fans as tables
.build/release/sensordump --json      # the same as JSON
.build/release/sensordump --raw       # plus every AppleSmartBattery registry value
.build/release/sensormap record       # load tests to identify sensors (see CONTRIBUTING)
```

`sensordump` masks serial numbers unless `--include-serial` is given.

## Language

FixStat follows the system language; English and Turkish are included, other
languages fall back to English. To run FixStat in a different language than the
system, use **System Settings › General › Language & Region › Applications**, add
FixStat and pick a language. Numbers and units follow your region settings.

## Safety and privacy

- **Read-only.** SMC access uses only the key-info, read and read-index commands of
  the `AppleSMC` user client; the write command is not implemented and the C layer
  rejects anything else. No fan control, no root, no `powermetrics`.
- **Private APIs.** Temperatures on Apple Silicon come from `IOHIDEventSystemClient`,
  which is not public API. This is why FixStat is not on the App Store.
- **No network access.** Settings, custom sensor names and battery history stay in
  `~/Library/Application Support/FixStat/`.
- **Serial numbers** are masked in every output and export.

## Acknowledgements

The SMC parameter layout and the IOHID sensor approach follow the public reverse
engineering used by [exelban/stats](https://github.com/exelban/stats) (MIT) and
smcFanControl. FixStat's code is an independent implementation; no code was copied.

## License

[MIT](LICENSE)
