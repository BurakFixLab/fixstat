# Installing FixStat

[Türkçe](INSTALL.tr.md)

> **Runs on macOS 10.13 High Sierra or later** (Intel) and **macOS 11 Big Sur or later**
> (Apple Silicon). macOS 14 and later show the SwiftUI interface, older versions an AppKit
> interface with the same features. Tested down to macOS 10.13 High Sierra (Intel iMac).
> SSD health (SMART) of AHCI / SATA SSDs is not supported yet; it is coming in a later version.

- [1. Download](#1-download)
- [2. Open it the first time](#2-open-it-the-first-time)
- [3. Find it in the menu bar](#3-find-it-in-the-menu-bar)
- [4. Open at login (optional)](#4-open-at-login-optional)
- [Updating](#updating)
- [Uninstalling](#uninstalling)
- [Building from source](#building-from-source)
- [Troubleshooting](#troubleshooting)

## 1. Download

1. Download `FixStat.dmg` from the [Releases](../../releases) page.
2. Double-click it. A window opens with FixStat, an arrow and the Applications folder.
3. Drag **FixStat** onto **Applications**, then eject the disk image (the ⏏ button next to
   "FixStat" in the Finder sidebar). The DMG can be deleted afterwards.

## 2. Open it the first time

FixStat is free and open source, but it is not notarized by Apple (that requires a paid
developer account). macOS therefore blocks the first launch. You only have to do this once.

**macOS 15 Sequoia and later**

1. Double-click FixStat in Applications. macOS shows *"FixStat" Not Opened* — click **Done**.
2. Open **System Settings › Privacy & Security** and scroll down to **Security**.
3. Next to *"FixStat" was blocked…*, click **Open Anyway** and confirm with your password.
4. Click **Open Anyway** once more in the dialog that follows.

**macOS 14 Sonoma and earlier (10.13 – 14)**

1. In Applications, **right-click** (or Control-click) FixStat and choose **Open**.
2. Click **Open** in the dialog.
3. If the dialog has no **Open** button: **System Preferences › Security & Privacy ›
   General** (System Settings › Privacy & Security on macOS 13 – 14) › **Open Anyway**.

**Alternative for all versions (Terminal)**

```bash
xattr -dr com.apple.quarantine /Applications/FixStat.app
```

This removes the "downloaded from the internet" flag; FixStat then opens normally. Use it
also if macOS says the app *"is damaged and can't be opened"*.

FixStat needs **no special permissions**: no administrator rights, no Accessibility or Full
Disk Access, no network access. It only reads sensor values; it never writes to the SMC.

The **hardware check** asks macOS for camera, microphone and Bluetooth access the first time
you open those tests; they only work while the test is on screen.

The one exception is the optional **full SSD test** (Tools › SSD health and test). Reading
the whole disk surface needs your administrator password (asked each time, FixStat never
stores it) and **Full Disk Access**: System Settings › Privacy & Security › Full Disk
Access › turn FixStat on (macOS 12 and earlier: System Preferences › Security & Privacy ›
Privacy › Full Disk Access; macOS 10.13 has no such setting). The scan only reads the disk.

## 3. Find it in the menu bar

FixStat opens no window at start — it lives in the **menu bar** at the top right (battery
icon, percentage and CPU temperature). Click it to open the panel. While one of its windows
(a tool, Settings) is open, FixStat also shows a Dock icon so the window cannot get lost
behind other apps; Settings › General › **Always show the Dock icon** keeps it there.

- **Settings…** in the panel: what the menu bar shows, technician mode, appearance
  (system / light / dark), thresholds, update interval, sensor names.
- **History**: battery charge, current and health over time.
- **Quit** closes FixStat.

## 4. Open at login (optional)

Settings › General › **Open at login**. On macOS 13 and later, macOS may ask you to allow
FixStat under **System Settings › General › Login Items & Extensions**. On macOS 12 and
earlier, FixStat adds a small launch agent
(`~/Library/LaunchAgents/io.github.burakfixlab.fixstat.login.plist`) and removes it when you
turn the option off.

## Updating

Quit FixStat, replace `FixStat.app` in Applications with the new version and open it again
(repeat step 2 if macOS asks). Settings, custom sensor names and battery history are kept.

## Uninstalling

1. In FixStat Settings, turn **Open at login** off, then **Quit**.
2. Move `FixStat.app` from Applications to the Trash.
3. Optional — remove settings, custom sensor names and battery history:
   ```bash
   rm -rf ~/Library/Application\ Support/FixStat
   rm -f ~/Library/LaunchAgents/io.github.burakfixlab.fixstat.login.plist
   defaults delete io.github.burakfixlab.fixstat
   ```

## Building from source

Requires macOS 14 or later and Xcode 16 or later (Swift 6). No other tools. The app built
this way runs on macOS 10.13 and later like the released one.

```bash
git clone https://github.com/BurakFixLab/fixstat.git
cd fixstat
scripts/build-app.sh          # builds build/FixStat.app
open build/FixStat.app
```

A self-built app is not quarantined, so step 2 is not needed. The command-line tools:

```bash
swift build -c release
.build/release/sensordump     # battery, temperatures, fans
```

## Troubleshooting

| Problem | Solution |
|---|---|
| The icon does not appear in the menu bar | On MacBooks with a notch, a full menu bar can hide items behind the notch. Quit a few menu bar apps or use a menu bar manager. Check with Activity Monitor that FixStat is running. |
| *"FixStat" Not Opened* / *can't be opened* | See step 2, or use the `xattr` command. |
| *"is damaged and can't be opened"* | Use the `xattr` command in step 2. |
| Open at login does not work | Allow FixStat in System Settings › General › Login Items & Extensions (macOS 13 and later). On older versions, turn the option off and on again. |
| The panel looks different from the screenshots | On macOS 13 and earlier FixStat uses its AppKit interface: same data and tools, a simpler look. |
| Sensors show "estimated" | Your Mac model has no verified sensor map yet. Names are guessed from the chip and key patterns. You can [help add your model](CONTRIBUTING.md). |
| The full SSD test does not start / "macOS blocked reading the disk" | Turn FixStat on in System Settings › Privacy & Security › Full Disk Access. After replacing or rebuilding the app, turn it off and on again (an unsigned build counts as a new app). |
| Wrong language | FixStat follows the system language. To change it for FixStat only: System Settings › General › Language & Region › Applications. |

Questions or problems: [open an issue](../../issues).
