<img src="App/AppIcon.svg" width="112" alt="FixStat icon">

# FixStat

**A free, open-source menu bar monitor for macOS, built for board-level Mac repair.**

[Türkçe](README.tr.md)

> **Runs on macOS 10.13 High Sierra or later** (Intel) and **macOS 11 Big Sur or later**
> (Apple Silicon) — one universal app. macOS 14 and later get the SwiftUI interface, older
> versions an AppKit interface with the same features.
> Tested on a MacBook Air M1 (macOS 26), a MacBook Air 11" Early 2014 (Intel, macOS 11) and
> an Intel iMac with macOS 10.13 High Sierra. Intel sensor names are still estimated —
> reports are welcome.
>
> **Download:** `FixStat.dmg` on the [Releases](../../releases/latest) page.

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
  sensor with its raw SMC / HID key, grouped by component (CPU, GPU, PMU and board, SSD …)
  with the hottest one in each group, and the unmatched sensors in a separate list.
- **Board-level details.** HID sensors are joined with their SMC keys (the HID
  `LocationID` is the SMC key), so e.g. `TCHP` shows up as the charger-side NTC read
  through `PMU tdev7`.
- **Battery history.** Charge, current and health from the last hour up to 30 days,
  plus a daily health log that is kept indefinitely.
- **Diagnostics in one app.** Post-repair stress test, SSD health in % (NVMe and AHCI / SATA SMART, capacity and free space) with a
  write–verify stress test and an optional full surface scan, memory test, kernel panic
  and shutdown cause history, battery and power adapter originality check, battery
  capacity (discharge) test, sleep / wake analysis with battery drain while asleep and
  while shut down, live power analysis (system total, CPU / GPU power, every power rail's
  voltage and current on Apple Silicon, without root), a live monitor that charts up to six SMC
  values (power, rails, temperatures, fans, battery) a few times a second with markers and CSV
  recording, a device card (Activation Lock, MDM, part number), and a
  hardware check (keyboard, trackpad surface, display, speakers, microphone, camera,
  Touch Bar, fans under load, temperature sensors (open / shorted / stuck sensors and what a
  missing sensor causes: fans at full speed, kernel_task holding the CPU back), Wi-Fi, Bluetooth, USB-C / USB-A ports with fault counters,
  slow USB 3 lane detection and a USB drive speed test per port, lid sensor).
- **Fits the Mac.** On an iMac, Mac mini or Mac Studio the battery tools disappear and the
  hardware check lists only the parts that Mac has.
- **Reports.** PDF / CSV / JSON export for customer devices, serial numbers masked unless you
  turn on full serials in Settings (for your own records).
- **Read-only.** FixStat never writes to the SMC, has no fan control and needs no
  administrator rights. The only exception is the optional full SSD surface scan, which
  asks for your password and Full Disk Access and only reads the disk.

## Verified models

| Model identifier | Mac | Chip | Board | Sensors named | Verified by test | macOS |
|---|---|---|---|---|---|---|
| `Mac14,2` | MacBook Air (M2, 2022) | Apple M2 | J413 | 62 | 11 | 26.6 |
| `Mac14,7` | MacBook Pro (13-inch, M2, 2022) | Apple M2 | J493 | 63 | 11 | 15.7 |
| `Mac14,9` | MacBook Pro (14-inch, 2023) | Apple M2 Pro | J414s | 69 | 22 | 26.6 |
| `Mac15,12` | MacBook Air (13-inch, M3, 2024) | Apple M3 | J613 | 76 | 6 | 27.0 |
| `Mac16,12` | MacBook Air (13-inch, M4, 2025) | Apple M4 | J713 | 75 | 12 | 15.5 |
| `MacBookAir10,1` | MacBook Air (M1, 2020) | Apple M1 | J313 | 64 | 16 | 26.6 |
| `MacBookAir6,1` | MacBook Air (11-inch, Mid 2013 / Early 2014) | Intel Core i5 (Haswell) | – | 15 | 5 | 11.7 |
| `MacBookPro15,2` | MacBook Pro (13-inch, 2018, four Thunderbolt 3 ports) | Intel Core i7 (Coffee Lake) | – | 17 | 7 | 15.8 |
| `MacBookPro18,3` | MacBook Pro (14-inch, 2021) | Apple M1 Pro | J314s | 58 | 13 | 14.8 |

Each map comes from bench recordings of one Mac (load tests on CPU, GPU, SSD and charger).
"Verified by test" counts the sensors a test confirmed; the others are named from the chip
and key patterns and shown as estimated. The MacBook Air M1 map was also checked by hand. These
Macs report more temperature keys than are named (unnamed ones appear under "Unmatched").

Other Macs work too: sensors are then named from chip and key patterns and marked as
estimated. The CPU and GPU zones of **M1 Pro / Max, M2, M2 Pro / Max, M3 and M4** are named per
chip from bench recordings (on these chips they exist only as SMC keys), so every Mac with
one of these chips, including iMacs and Mac minis, shows its CPU temperature. Please help add your model — see [CONTRIBUTING.md](CONTRIBUTING.md) or open a
[new model issue](../../issues/new?template=new-model-sensor-data.yml).

## Installation

**Step-by-step guide: [INSTALL.md](INSTALL.md)** — download, first launch of the unsigned
app, menu bar, open at login, updating, uninstalling and troubleshooting.

In short:

1. Download `FixStat.dmg` from [Releases](../../releases), open it and drag FixStat onto
   the Applications folder in its window.
2. FixStat is not notarized by Apple, so the first launch is blocked once: open it, then
   click **Open Anyway** in **System Settings › Privacy & Security** (on macOS 14 and
   earlier: right-click › Open). Or in Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/FixStat.app
   ```
3. FixStat runs in the menu bar; a Dock icon appears only while one of its windows is open.
   **Open at login** is in its settings.

To build from source (macOS 14+ with Xcode 16 or later, no other tools):

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
- **No data collection.** FixStat collects nothing and sends nothing: no analytics, no
  telemetry. Its only network access is the update check: once a day it asks GitHub's public
  releases API which FixStat version is the latest (nothing about your Mac is sent; turn it
  off under Settings › "Check for updates automatically"). FixStat never downloads or installs
  anything itself. Settings, custom sensor names and battery history stay on your Mac in
  `~/Library/Application Support/FixStat/`; reports are only created when you export them.
- **Serial numbers** are masked in every output and export, unless you turn on
  "Show full serial numbers in reports" in Settings (off by default).

## Acknowledgements

The SMC parameter layout and the IOHID sensor approach follow the public reverse
engineering used by [exelban/stats](https://github.com/exelban/stats) (MIT) and
smcFanControl. FixStat's code is an independent implementation; no code was copied.

## License

[MIT](LICENSE)
