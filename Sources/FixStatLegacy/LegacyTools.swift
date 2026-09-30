import AppKit
import MacSensors
import FixStatCore

/// The Tools menu of the AppKit interface and its windows. Each window shows the same
/// content as its SwiftUI counterpart as a `LegacyDocumentView`.
final class LegacyTools {
    enum Tool: CaseIterable {
        case deviceInfo, history, batteryDetails, memory, crashHistory, sleep, stressTest

        var title: String {
            switch self {
            case .deviceInfo: return L("Device info")
            case .history: return L("Battery history")
            case .batteryDetails: return L("Battery details")
            case .crashHistory: return L("Panic and shutdown history")
            case .memory: return L("Memory test")
            case .sleep: return L("Sleep and wake")
            case .stressTest: return L("Post-repair test")
            }
        }

        /// Separator after this item in the menu.
        var endsGroup: Bool { self == .deviceInfo }
    }

    private let core: MonitorCore
    private var windows: [Tool: LegacyToolWindow] = [:]
    /// Range the history window opens with (`--range N` for snapshots).
    static var initialRange = HistoryRange.day

    init(core: MonitorCore) {
        self.core = core
    }

    /// Pull-down "Tools" button for the panel footer.
    func makeMenuButton(small: Bool, willOpen: @escaping () -> Void) -> NSView {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.addItem(withTitle: L("Tools"))
        for tool in Tool.allCases {
            let item = LegacyMenuItem(title: tool.title) { [unowned self] in
                willOpen()
                open(tool)
            }
            button.menu?.addItem(item)
            if tool.endsGroup { button.menu?.addItem(.separator()) }
        }
        if small {
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        return button
    }

    func open(_ tool: Tool) {
        let window = windows[tool] ?? makeWindow(tool)
        windows[tool] = window
        window.present()
    }

    func window(_ tool: Tool) -> LegacyToolWindow {
        let window = windows[tool] ?? makeWindow(tool)
        windows[tool] = window
        return window
    }

    /// The objects behind the windows (their content builders), kept for the app's lifetime.
    private var controllers: [Tool: AnyObject] = [:]

    private func makeWindow(_ tool: Tool) -> LegacyToolWindow {
        switch tool {
        case .deviceInfo: return keep(tool, LegacyDeviceInfo(core: core)).window
        case .history: return keep(tool, LegacyHistory(core: core, initialRange: LegacyTools.initialRange)).window
        case .batteryDetails: return keep(tool, LegacyBatteryDetails(core: core)).window
        case .crashHistory: return keep(tool, LegacyCrashHistory(core: core)).window
        case .memory: return keep(tool, LegacyMemoryTest(core: core)).window
        case .sleep: return keep(tool, LegacySleep(core: core)).window
        case .stressTest: return keep(tool, LegacyStressTest(core: core)).window
        }
    }

    /// The object behind an opened window (snapshots start tests through it).
    func controller(_ tool: Tool) -> AnyObject? { controllers[tool] }

    private func keep<T: AnyObject>(_ tool: Tool, _ controller: T) -> T {
        controllers[tool] = controller
        return controller
    }
}

/// Menu item that runs a closure.
final class LegacyMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(run), keyEquivalent: "")
        self.handler = handler
        target = self
    }

    @objc private func run() { handler?() }
}

/// Runs `work` in the background and `done` on the main thread.
func background<T>(_ work: @escaping () -> T, done: @escaping (T) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let value = work()
        DispatchQueue.main.async { done(value) }
    }
}

// MARK: - Device info

final class LegacyDeviceInfo {
    private let core: MonitorCore
    private var ssd: SSDInfo?
    private var panics: [PanicReport]?
    private var copied = false
    private(set) var window: LegacyToolWindow!

    init(core: MonitorCore) {
        self.core = core
        window = LegacyToolWindow(title: L("Device info"), contentWidth: 580, height: 680) { [unowned self] in blocks() }
        window.onOpen = { [unowned self] in load() }
    }

    private func load() {
        copied = false
        MonitorCore.loadDeviceInfo { [weak self] info in
            self?.core.deviceInfo = info
            self?.window.reload()
        }
        background({ (SSDInfo.read(), CrashHistory.panics()) }, done: { [weak self] result in
            self?.ssd = result.0
            self?.panics = result.1
            self?.window.reload()
        })
    }

    private var healthRows: [(String, String, Bool)] {
        DeviceText.healthRows(battery: core.battery, model: core.system.model, reference: core.partsReference,
                              ssd: ssd, panics: panics, hardwareCheck: core.hardwareCheck)
    }

    private func blocks() -> [Block] {
        guard let info = core.deviceInfo else { return [.progress("")] }
        var header = [[info.system.model, info.system.boardTarget, info.partNumber].compactMap { $0 }.joined(separator: " · ")]
        if let serial = info.serial { header.append(L("Serial %@", serial)) }
        let health = healthRows
        return [
            .header(info.system.marketingName ?? info.system.model, header),
            .section(L("Configuration")),
            .rows(DeviceText.configuration(info, ssd: ssd).map { DocRow(title: $0.0, value: $0.1) }, labelWidth: 190),
            .section(L("Ownership and security")),
            .list(DeviceText.security(info).map { .status("\($0.0): \($0.1)", $0.2 ? .bad : .good) }),
            .section(L("Health summary")),
            .list(health.map { .status("\($0.0): \($0.1)", $0.2 ? .bad : .good) }),
        ] + [.actions([DocAction(title: copied ? L("Copied") : L("Copy as text")) { [unowned self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(DeviceText.plainText(info, ssd: ssd, health: healthRows), forType: .string)
                copied = true
                window.reload()
            }])]
    }
}

// MARK: - Battery details

final class LegacyBatteryDetails {
    private let core: MonitorCore
    private var macOSHealth: MacOSBatteryHealth?
    private(set) var window: LegacyToolWindow!

    init(core: MonitorCore) {
        self.core = core
        window = LegacyToolWindow(title: L("Battery details"), contentWidth: 680, height: 720) { [unowned self] in blocks() }
        window.onOpen = { [unowned self] in
            core.detailsVisible = true
            let interval = UserDefaults.standard.double(forKey: Pref.updateInterval)
            window.refresh(every: interval > 0 ? interval : Pref.defaultInterval)
            background({ MacOSBatteryHealth.read() }, done: { [weak self] health in
                self?.macOSHealth = health
                self?.window.reload()
            })
        }
        window.onClose = { [core] in core.detailsVisible = false }
    }

    private func blocks() -> [Block] {
        guard let battery = core.battery else {
            return [.headline(L("No battery"), nil), .secondary(L("This Mac has no internal battery."))]
        }
        return [
            originality(battery),
            cells(battery),
            .columns([[pack(battery)], [lifetime(battery.lifetime)]]),
            .columns([[charger(battery)], [powerDelivery(battery)]]),
        ]
    }

    private func originality(_ battery: BatteryInfo) -> Block {
        let batteryCheck = PartCheck.battery(battery, model: core.system.model, reference: core.partsReference)
        var adapterColumn: [Block]
        if let adapterCheck = PartCheck.adapter(battery, reference: core.partsReference) {
            adapterColumn = partColumn(L("Power adapter"), adapterCheck)
        } else {
            adapterColumn = [.headline(L("Power adapter"), nil), .secondary(L("Connect the power adapter to check it."))]
        }
        var blocks: [Block] = [.columns([partColumn(L("Battery"), batteryCheck), adapterColumn])]
        if let condition = macOSHealth?.condition {
            let text = L("macOS battery condition: %@", PartText.condition(condition))
                + (macOSHealth?.maximumCapacity.map { " · \($0)" } ?? "")
            blocks.append(.status(text, macOSHealth?.isGood == true ? .good : .bad))
        }
        blocks.append(.caption(L("macOS has no genuine-part flag for Mac batteries and clones can copy digital data, so this is a consistency check against known genuine parts, not proof.")))
        return .group(L("Originality check"), blocks)
    }

    private func partColumn(_ title: String, _ check: PartCheck) -> [Block] {
        let tone: Tone = check.verdict == .consistent ? .good : check.verdict == .suspicious ? .bad : .neutral
        let items = check.items.map { item -> Block in
            let itemTone: Tone = item.status == .pass ? .good : item.status == .warn ? .bad : .neutral
            return .status(PartText.item(item.id), itemTone, detail: item.detail.isEmpty ? nil : item.detail)
        }
        return [.list([.headline(title, nil), .headline(PartText.verdict(check.verdict), tone)] + items)]
    }

    private func cells(_ battery: BatteryInfo) -> Block {
        let analysis = CellAnalysis(battery: battery)
        let rows = analysis.cells.map { cell in
            [L("Cell %lld", cell.number),
             cell.voltage.map { Format.volts(millivolts: $0, digits: 3) } ?? "–",
             cell.qmax.map(Format.milliampHours) ?? "–",
             cell.resistance.map { Format.number(Double($0)) } ?? "–",
             BatteryDetailText.deviation(cell)]
        }
        let tones: [[Tone?]] = analysis.cells.map { cell in
            [nil, nil, cell.lowCapacity ? .bad : nil, cell.highResistance ? .bad : nil, cell.isSuspect ? .bad : .neutral]
        }
        var blocks: [Block] = [
            .table(header: [L("Cell"), L("Voltage"), L("Qmax"), L("Resistance"), L("vs. average")],
                   rows: rows, tones: tones, leading: false),
        ]
        if analysis.suspects.isEmpty {
            blocks.append(.status(L("Cells are consistent."), .good))
        } else {
            blocks.append(.list(analysis.suspects.map { .status(BatteryDetailText.finding($0), .bad) }))
        }
        blocks.append(.caption(L("Resistance is the gauge's weighted cell resistance; its unit is not documented, compare the cells with each other.")))
        return .group(L("Cells"), blocks)
    }

    private func pack(_ b: BatteryInfo) -> Block {
        .group(L("Pack"), [.rows([
            DocRow(title: L("Gauge"), value: b.gaugeDeviceName),
            DocRow(title: L("Chemistry ID"), value: b.identity?.chemistryID.map { String($0) }),
            DocRow(title: L("Manufacturer data"), value: BatteryDetailText.manufacturer(b)),
            DocRow(title: L("Cycles"), value: BatteryDetailText.cycles(b)),
            DocRow(title: L("Health"), value: b.healthPercent.map { Format.percent($0, digits: 1) }),
            DocRow(title: L("Nominal health"), value: b.nominalHealthPercent.map { Format.percent($0, digits: 1) }),
            DocRow(title: L("Permanent failure"), value: BatteryDetailText.hex(b.permanentFailureStatus),
                   tone: (b.permanentFailureStatus ?? 0) != 0 ? .bad : nil),
            DocRow(title: L("Cell disconnects"), value: b.cellDisconnectCount.map { Format.number(Double($0)) },
                   tone: (b.cellDisconnectCount ?? 0) != 0 ? .bad : nil),
            DocRow(title: L("Flash writes"), value: b.identity?.dataFlashWriteCount.map { Format.number(Double($0)) }),
            DocRow(title: L("Serial"), value: b.serial),
        ], labelWidth: nil)])
    }

    private func lifetime(_ l: BatteryLifetime?) -> Block {
        .group(L("Lifetime (gauge)"), [.rows([
            DocRow(title: L("Operating time"), value: l?.totalOperatingTime.map(BatteryDetailText.hours)),
            DocRow(title: L("Highest temperature"), value: l?.maximumTemperature.map { Format.temperature($0) }),
            DocRow(title: L("Average temperature"), value: l?.averageTemperature.map { Format.temperature($0) }),
            DocRow(title: L("Lowest temperature"), value: l?.minimumTemperature.map { Format.temperature($0) }),
            DocRow(title: L("Highest charge current"), value: l?.maximumChargeCurrent.map { Format.milliamps($0) }),
            DocRow(title: L("Highest discharge current"), value: l?.maximumDischargeCurrent.map { Format.milliamps($0) }),
            DocRow(title: L("Highest pack voltage"), value: l?.maximumPackVoltage.map { Format.volts(millivolts: $0) }),
            DocRow(title: L("Lowest pack voltage"), value: l?.minimumPackVoltage.map { Format.volts(millivolts: $0) }),
        ], labelWidth: nil)])
    }

    private func charger(_ b: BatteryInfo) -> Block {
        let c = b.charger
        return .group(L("Charger"), [
            .rows([
                DocRow(title: L("State"), value: BatteryText.state(b)),
                DocRow(title: L("Battery current"), value: b.amperage.map { Format.milliamps($0) }),
                DocRow(title: L("Charger target current"), value: c?.chargingCurrent.map { Format.milliamps($0, signed: false) }),
                DocRow(title: L("Charger target voltage"), value: c?.chargingVoltage.map { Format.volts(millivolts: $0, digits: 3) }),
                DocRow(title: L("Input"), value: BatteryDetailText.input(b.powerTelemetry)),
                DocRow(title: L("Not charging reason"), value: BatteryDetailText.notCharging(c?.notChargingReason)),
                DocRow(title: L("Slow charging reason"), value: BatteryDetailText.hex(c?.slowChargingReason),
                       tone: (c?.slowChargingReason ?? 0) != 0 ? .bad : nil),
                DocRow(title: L("Charger inhibit reason"), value: BatteryDetailText.hex(c?.chargerInhibitReason),
                       tone: (c?.chargerInhibitReason ?? 0) != 0 ? .bad : nil),
                DocRow(title: L("Thermally limited"), value: c?.timeChargingThermallyLimited.map { Format.number(Double($0)) },
                       tone: (c?.timeChargingThermallyLimited ?? 0) != 0 ? .bad : nil),
            ], labelWidth: nil),
            .caption(L("Reason codes are Apple's undocumented bit fields, shown as reported. 0 means none.")),
        ])
    }

    private func powerDelivery(_ b: BatteryInfo) -> Block {
        guard let pd = b.powerDelivery, let active = pd.activeProfile ?? pd.contract?.sourceObject else {
            return .group(L("USB-C Power Delivery"), [.secondary(L("No USB-C Power Delivery contract."))])
        }
        var blocks: [Block] = []
        if b.externalConnected != true { blocks.append(.caption(L("No power adapter — last contract:"))) }
        var rows = [DocRow(title: L("Contract"), value: BatteryDetailText.profile(active, position: pd.activePosition))]
        if let contract = pd.consistentContract {
            rows.append(DocRow(title: L("Requested"), value: BatteryDetailText.requested(contract)))
        }
        blocks.append(.rows(rows, labelWidth: nil))
        if pd.consistentContract?.capabilityMismatch == true {
            blocks.append(.status(L("The Mac reported that the adapter cannot supply what it needs."), .bad))
        }
        blocks.append(.secondary(L("Adapter offers")))
        let offers = pd.offeredProfiles.enumerated().map { index, pdo in
            ["\(index + 1).", BatteryDetailText.pdo(pdo), index + 1 == pd.activePosition ? L("in use") : ""]
        }
        let tones: [[Tone?]] = offers.map { _ in [.neutral, nil, .good] }
        blocks.append(.table(header: nil, rows: offers, tones: tones, leading: true))
        blocks.append(.rows([
            DocRow(title: L("Plug-ins / removals"), value: BatteryDetailText.counts(pd)),
            DocRow(title: L("Hard resets"), value: pd.hardResetCount.map { Format.number(Double($0)) }),
        ], labelWidth: nil))
        return .group(L("USB-C Power Delivery"), blocks)
    }
}

// MARK: - Panic and shutdown history

final class LegacyCrashHistory {
    private let core: MonitorCore
    private var panics: [PanicReport] = []
    private var shutdowns: [ShutdownEvent] = []
    private var loadingShutdowns = true
    private var expanded: String?
    private(set) var window: LegacyToolWindow!

    init(core: MonitorCore) {
        self.core = core
        window = LegacyToolWindow(title: L("Panic and shutdown history"), contentWidth: 640, height: 600) { [unowned self] in
            blocks()
        }
        window.onOpen = { [unowned self] in load() }
    }

    private func load() {
        // Reuse a recent scan: searching 30 days of the system log takes about a minute.
        if let scan = core.lastCrashScan, Date().timeIntervalSince(scan.date) < 600 {
            panics = scan.panics
            shutdowns = scan.shutdowns
            loadingShutdowns = false
            return
        }
        panics = CrashHistory.panics()
        loadingShutdowns = true
        background({ CrashHistory.shutdownEvents(days: 30) }, done: { [weak self] events in
            guard let self else { return }
            shutdowns = events
            loadingShutdowns = false
            core.lastCrashScan = CrashScan(panics: panics, shutdowns: events)
            window.reload()
        })
    }

    private func blocks() -> [Block] {
        var blocks: [Block] = [.section(L("Previous shutdown causes (last 30 days)"))]
        if loadingShutdowns {
            blocks.append(.progress(L("Searching the system log — this can take about a minute.")))
        } else if shutdowns.isEmpty {
            blocks.append(.secondary(L("No shutdown causes in the system log. macOS records one at every start; older entries are removed after a while.")))
        } else {
            let rows = shutdowns.map { [Format.dateTime($0.date), String($0.code), CrashText.shutdownMeaning($0.meaning)] }
            let tones: [[Tone?]] = shutdowns.map { [$0.isFault ? .bad : .good, nil, $0.meaning == nil ? .neutral : nil] }
            blocks.append(.table(header: nil, rows: rows, tones: tones, leading: true))
        }
        blocks.append(.caption(L("Code meanings come from the repair community, not from Apple, and can differ between models.")))
        blocks.append(.section(L("Kernel panics")))
        if panics.isEmpty {
            blocks.append(.status(L("No kernel panic reports found."), .good))
        }
        for panic in panics {
            var inner: [Block] = [.headline(Format.dateTime(panic.date) + (panic.area.map { "  ·  " + CrashText.area($0) } ?? ""),
                                            panic.area == nil ? nil : .bad),
                                  .mono(panic.summary)]
            if let process = panic.panickedProcess { inner.append(.caption(process)) }
            let isExpanded = expanded == panic.id
            if isExpanded { inner.append(.mono(panic.panicString)) }
            var actions = [DocAction(title: isExpanded ? L("Less") : L("Full text"), link: true) { [unowned self] in
                expanded = isExpanded ? nil : panic.id
                window.reload()
            }]
            if isExpanded {
                actions.append(DocAction(title: L("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(panic.panicString, forType: .string)
                })
            }
            inner.append(.actions(actions))
            blocks.append(.group(nil, inner))
        }
        return blocks
    }
}

// MARK: - Sleep and wake

final class LegacySleep {
    private let core: MonitorCore
    private(set) var window: LegacyToolWindow!

    init(core: MonitorCore) {
        self.core = core
        window = LegacyToolWindow(title: L("Sleep and wake"), contentWidth: 680, height: 720) { [unowned self] in blocks() }
        window.onOpen = { [unowned self] in reload() }
    }

    private func reload() {
        background({ SleepAnalysis.read() }, done: { [weak self] analysis in
            self?.core.lastSleepAnalysis = analysis
            self?.window.reload()
        })
    }

    private func blocks() -> [Block] {
        guard let a = core.lastSleepAnalysis else { return [.progress("")] }
        var blocks: [Block] = []
        var top: [DocAction] = []
        top.append(DocAction(title: L("Refresh")) { [unowned self] in reload() })
        if let from = a.from, let to = a.to {
            blocks.append(.secondary(L("Power log from %@ to %@", Format.dateTime(from), Format.dateTime(to))))
        }
        blocks.append(.actions(top))
        blocks.append(.tiles([
            (L("Sleeps"), Format.number(Double(a.sleeps.count))),
            (L("Wakes"), Format.number(Double(a.wakes.count))),
            (L("Dark wakes"), Format.number(Double(a.darkWakes.count))),
            (L("Drain while asleep"), a.sleepDrain.map { SleepText.drain($0.percentPerHour) } ?? "–"),
            (L("Battery ran empty"), Format.number(Double(a.lowPowerSleeps))),
            (L("Sleep / wake failures"), Format.number(Double(a.failures.count))),
            (L("Average wake time"), a.averageWakeTime.map { Format.seconds($0) } ?? "–"),
            (L("Low battery warnings"), Format.number(Double(a.lowBatteryWarnings))),
        ], columns: 4))

        let off = core.offPeriods(a)
        let findings = SleepText.findings(a) + SleepText.offFindings(off)
        if findings.isEmpty {
            blocks.append(.headline(L("No sleep or wake problems found."), .good))
        }
        blocks.append(.list(findings.map { .status($0, .bad) }))

        blocks.append(.columns([countList(L("Wake reasons"), a.reasons(.wake)),
                                countList(L("Dark wake reasons"), a.reasons(.darkWake))]))
        blocks += offSection(off)

        if !a.preventingNow.isEmpty || !a.preventers.isEmpty {
            blocks.append(.section(L("What keeps the Mac awake")))
            if !a.preventingNow.isEmpty {
                blocks.append(.text(L("Now: %@", a.preventingNow.joined(separator: ", "))))
            }
            blocks.append(.rows(a.preventers.map {
                DocRow(title: $0.process, value: L("%lld times, longest %@", $0.count, Format.duration(Double($0.longestSeconds))))
            }, labelWidth: 220))
        }
        if !a.slowDrivers.isEmpty {
            blocks.append(.section(L("Slow drivers during sleep / wake")))
            blocks.append(.rows(a.slowDrivers.map {
                DocRow(title: $0.driver, value: L("%lld× · up to %@ ms", $0.count, Format.number(Double($0.maxMilliseconds))))
            }, labelWidth: 220))
        }
        blocks.append(.section(L("Settings")))
        blocks.append(.rows(SleepText.settingRows(a.settings).map { DocRow(title: $0.0, value: $0.1) }, labelWidth: 220))

        blocks.append(.section(L("Recent events")))
        let events = Array(a.events.suffix(40).reversed())
        blocks.append(.table(header: nil, rows: events.map { e in
            [Format.dateTime(e.date), SleepText.kind(e.kind), String(SleepText.describe(e.reason).prefix(40)),
             [e.charge.map { Format.percent(Double($0)) },
              e.onBattery.map { $0 ? L("battery") : L("adapter") }].compactMap { $0 }.joined(separator: " · "),
             e.duration.map { Format.duration(Double($0)) } ?? ""]
        }, tones: events.map { _ in [.neutral, nil, nil, .neutral, .neutral] }, leading: true))
        return blocks
    }

    private func countList(_ title: String, _ counts: [SleepAnalysis.Count]) -> [Block] {
        var items: [Block] = [.section(title)]
        if counts.isEmpty { items.append(.secondary(L("none"))) }
        for c in counts {
            let category = SleepText.category(c.name)
            items.append(.item("\(c.count)×  " + (category ?? c.name), detail: category != nil ? c.name : nil))
        }
        return [.list(items)]
    }

    private func offSection(_ periods: [OffPeriod]) -> [Block] {
        var blocks: [Block] = [.section(L("While shut down"))]
        if let summary = OffStateDrain.summary(periods) {
            blocks.append(.headline(SleepText.offSummary(summary), nil))
        }
        if periods.isEmpty {
            blocks.append(.secondary(L("No shutdowns with a known charge in the log yet.")))
        } else {
            let list = Array(periods.reversed())
            blocks.append(.table(header: nil, rows: list.map { p in
                [Format.dateTime(p.shutdown), Format.duration(p.hours * 3600), SleepText.chargeChange(p),
                 p.averageCurrent.map { SleepText.milliamps($0) } ?? "", SleepText.source(p)]
            }, tones: list.map { p in p.isUsable ? [.neutral, nil, nil, nil, .neutral] : [.neutral, .neutral, .neutral, .neutral, .neutral] },
               leading: true))
        }
        blocks.append(.caption(L("Measured: FixStat saved the battery gauge at power off and read it after the boot (needs FixStat to open at login). From log: whole percentages from the power log, so short periods are rough.")))
        return blocks
    }
}
