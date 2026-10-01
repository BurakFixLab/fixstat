import AppKit
import MacSensors
import FixStatCore

/// Content of the menu bar popover: the default panel (design A) or the technician
/// panel (design B), built with AppKit to match the SwiftUI panels.
///
/// The view tree is rebuilt only when its structure changes (sensors, fans, cells,
/// mode, expanded lists); otherwise `update()` just refreshes the values in place.
final class LegacyPanelController: NSViewController {
    private let core: MonitorCore
    private let openSettings: () -> Void
    /// Tools menu; nil hides it.
    var tools: LegacyTools?
    /// Closes the popover before a tool window opens.
    var closePanel: (() -> Void)?
    /// Called after the content changed size (the popover follows it).
    var onResize: ((NSSize) -> Void)?
    /// Tallest the panel may be (the screen below the menu bar). The technician panel is
    /// taller than the 768 px screen of an 11" MacBook Air; the sensor list gives way.
    var maxHeight: CGFloat? {
        didSet { if maxHeight != oldValue { structureKey = "" } }
    }

    private let root = NSStackView()
    private var updaters: [() -> Void] = []
    private var structureKey = ""
    private var showAll = false
    private var showUnmatched = false
    /// Height of the scrolling sensor list, shortened when the panel does not fit.
    private var listHeight: NSLayoutConstraint?

    private let rowHeight: CGFloat = 22
    private let techRowHeight: CGFloat = 29

    init(core: MonitorCore, openSettings: @escaping () -> Void) {
        self.core = core
        self.openSettings = openSettings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        let p = LegacyStyle.padding
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: p),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -p),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: p),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -p),
            root.widthAnchor.constraint(equalToConstant: LegacyStyle.panelWidth),
        ])
        view = container
        update()
    }

    private var technicianMode: Bool { UserDefaults.standard.bool(forKey: Pref.technicianMode) }
    private var hidden: Set<String> { Pref.hiddenSet(UserDefaults.standard.string(forKey: Pref.hiddenSensors) ?? "") }

    /// Sensors that are not hidden and have a plausible value.
    private var shownSensors: [DisplaySensor] {
        let hidden = self.hidden
        return core.sensors.filter { !hidden.contains($0.id) && core.value(of: $0) != nil }
    }

    func update() {
        guard isViewLoaded else { return }
        let key = currentStructureKey()
        if key != structureKey {
            structureKey = key
            rebuild()
        }
        for update in updaters { update() }
    }

    private func currentStructureKey() -> String {
        let shown = shownSensors
        var parts = [technicianMode ? "tech" : "default", core.battery == nil ? "nobattery" : "battery",
                     "fans \(core.fans.count)", "all \(showAll)", "unmatched \(showUnmatched)"]
        if technicianMode {
            parts.append("cells \(core.battery?.cellVoltages?.count ?? 0)")
            parts.append("charging \(core.battery?.isCharging == true)")
            parts.append(shown.map(\.id).joined(separator: ","))
        } else if showAll {
            parts.append(shown.map(\.id).joined(separator: ","))
        } else {
            parts.append(SensorSummary.rows(sensors: core.sensors, values: core.values, hidden: hidden)
                .map(\.title).joined(separator: ","))
        }
        return parts.joined(separator: "|")
    }

    private func rebuild() {
        updaters = []
        listHeight = nil
        for view in root.arrangedSubviews {
            root.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let sections = technicianMode ? technicianSections() : defaultSections()
        for section in sections {
            root.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        view.layoutSubtreeIfNeeded()
        if let maxHeight, let listHeight {
            let overflow = view.fittingSize.height - maxHeight
            if overflow > 0 {
                listHeight.constant = max(3 * techRowHeight, listHeight.constant - overflow)
                view.layoutSubtreeIfNeeded()
            }
        }
        onResize?(view.fittingSize)
    }

    // MARK: - Default panel

    private func defaultSections() -> [NSView] {
        var sections: [NSView] = []
        if core.battery != nil {
            sections += [batterySection(), makeSeparator()]
        }
        sections += [sensorSection(), makeSeparator(), fanAndSystemSection(), makeSeparator(), footer(small: false)]
        return sections
    }

    private func batterySection() -> NSView {
        let state = makeLabel("", size: LegacyStyle.caption, color: .secondaryLabelColor)
        let percent = makeLabel("", size: 34, weight: .semibold)
        let time = makeLabel("", color: .secondaryLabelColor)
        let bar = LevelBar(height: 5)
        bar.color = LegacyStyle.accent
        let health = valueTile(L("Health"))
        let cycles = valueTile(L("Cycles"))
        let temperature = valueTile(L("Temperature"))
        let tiles = hStack([health.view, cycles.view, temperature.view])
        tiles.distribution = .fillEqually

        updaters.append { [unowned self] in
            guard let b = core.battery else { return }
            state.stringValue = BatteryText.state(b)
            percent.stringValue = b.stateOfCharge.map { Format.percent($0) } ?? "–"
            time.stringValue = BatteryText.time(b) ?? ""
            bar.fraction = (b.stateOfCharge ?? 0) / 100
            health.value.stringValue = b.healthPercent.map { Format.percent($0) } ?? "–"
            cycles.value.stringValue = b.cycleCount.map { Format.number(Double($0)) } ?? "–"
            temperature.value.stringValue = b.temperature.map { Format.degrees($0) } ?? "–"
        }
        return column([
            hStack([makeSectionTitle(L("Battery")), makeSpacer(), state]),
            hStack([percent, time, makeSpacer()], alignment: .firstBaseline),
            bar,
            tiles,
        ], spacing: 8)
    }

    private func valueTile(_ title: String) -> (view: NSView, value: NSTextField) {
        let value = makeLabel("–", weight: .semibold)
        let content = vStack([makeLabel(title, size: LegacyStyle.caption, color: .secondaryLabelColor), value], spacing: 2)
        return (TileView(content: content), value)
    }

    private func sensorSection() -> NSView {
        let shown = shownSensors
        let toggle = ActionButton.link(showAll ? L("Less") : L("All (%lld)", shown.count)) { [unowned self] in
            showAll.toggle()
            update()
        }
        var rows: [NSView] = [hStack([makeSectionTitle(L("Sensors")), makeSpacer(), toggle])]
        if showAll {
            let list = shown.sorted(by: SensorOrder.displayOrder).map { sensor in
                sensorRow(title: sensor.name) { [unowned self] in core.value(of: sensor) }
            }
            rows.append(scrollList(list, spacing: 5, height: min(CGFloat(shown.count) * rowHeight, 280)))
        } else {
            let summaries = SensorSummary.rows(sensors: core.sensors, values: core.values, hidden: hidden)
            if summaries.isEmpty {
                rows.append(makeLabel(L("No temperature sensors found"), color: .secondaryLabelColor))
            }
            for (index, summary) in summaries.enumerated() {
                rows.append(sensorRow(title: summary.title) { [unowned self] in
                    let current = SensorSummary.rows(sensors: core.sensors, values: core.values, hidden: hidden)
                    return index < current.count ? current[index].value : nil
                })
            }
        }
        updaters.append { toggle.setLinkTitle(self.showAll ? L("Less") : L("All (%lld)", self.shownSensors.count)) }
        return column(rows, spacing: 6)
    }

    private func sensorRow(title: String, value: @escaping () -> Double?) -> NSView {
        let name = makeLabel(title)
        let bar = LevelBar(height: 4, width: 56)
        let label = makeLabel("–")
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let row = hStack([name, makeSpacer(), bar, label], spacing: 10)
        updaters.append {
            let v = value()
            bar.fraction = v.map { ($0 - 20) / 80 } ?? 0
            bar.color = LegacyStyle.temperatureColor(v, in: row)
            label.stringValue = v.map { Format.degrees($0) } ?? "–"
        }
        return row
    }

    private func fanAndSystemSection() -> NSView {
        var fanRows: [NSView] = [makeSectionTitle(L("Fans"))]
        if core.fans.isEmpty {
            fanRows.append(makeLabel(L("No fans"), color: .secondaryLabelColor))
        }
        for (i, fan) in core.fans.enumerated() {
            fanRows.append(valueRow(L("Fan %lld", fan.index + 1)) { [unowned self] in
                i < core.fans.count ? core.fans[i].actual.map(Format.rpm) : nil
            })
        }
        let system = vStack([
            makeSectionTitle(L("System")),
            valueRow(L("CPU")) { [unowned self] in core.cpuUsage.map { Format.percent($0 * 100) } },
            valueRow(L("Memory")) { [unowned self] in
                core.memory.map { memory in
                    L("%@ / %@", Format.number(Double(memory.used) / 1_073_741_824, digits: 1),
                      Format.gigabytes(memory.total, digits: 0))
                }
            },
        ], spacing: 4)
        for view in system.arrangedSubviews.dropFirst() {
            view.widthAnchor.constraint(equalTo: system.widthAnchor).isActive = true
        }
        let fans = vStack(fanRows, spacing: 4)
        for view in fans.arrangedSubviews.dropFirst() {
            view.widthAnchor.constraint(equalTo: fans.widthAnchor).isActive = true
        }
        let columns = hStack([fans, system], spacing: 16, alignment: .top)
        columns.distribution = .fillEqually
        return columns
    }

    private func valueRow(_ title: String, value: @escaping () -> String?) -> NSView {
        let label = makeLabel("–")
        label.alignment = .right
        updaters.append { label.stringValue = value() ?? "–" }
        return hStack([makeLabel(title), makeSpacer(), label])
    }

    private func footer(small: Bool) -> NSView {
        let settings = ActionButton(title: L("Settings…"), handler: openSettings)
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        let quit = ActionButton(title: L("Quit")) { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        if small {
            for button in [settings, quit] {
                button.controlSize = .small
                button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            }
        }
        var buttons: [NSView] = [settings]
        if let tools {
            buttons.append(tools.makeMenuButton(small: small) { [weak self] in self?.closePanel?() })
        }
        var trailing: [NSView] = [quit]
        // The technician panel also exports the report, like the SwiftUI one.
        if small {
            trailing.insert(LegacyExport.menuButton(core: core, small: true) { [weak self] in self?.closePanel?() }, at: 0)
        }
        return hStack(buttons + [makeSpacer()] + trailing, spacing: 6)
    }

    // MARK: - Technician panel

    private func technicianSections() -> [NSView] {
        var sections: [NSView] = [technicianHeader()]
        if let battery = core.battery {
            sections.append(batteryGrid(battery))
            if let cells = battery.cellVoltages, !cells.isEmpty {
                sections.append(cellSection(count: cells.count))
            }
        }
        sections += [technicianSensors(), fanRow(), footer(small: true)]
        return sections
    }

    private func technicianHeader() -> NSView {
        let system = core.system
        let name = makeLabel(system.marketingName ?? system.model, weight: .semibold,
                             font: .systemFont(ofSize: 13, weight: .semibold))
        let model = makeLabel([system.model, system.boardTarget, system.chip].compactMap { $0 }.joined(separator: " · "),
                              color: .secondaryLabelColor, font: LegacyStyle.mono(LegacyStyle.caption))
        let adapter = makeLabel("", size: LegacyStyle.caption, color: .secondaryLabelColor)
        updaters.append { [unowned self] in adapter.stringValue = BatteryText.adapter(core.battery) }
        // Desktops have an internal power supply, not an adapter.
        adapter.isHidden = !core.profile.hasBattery
        let badge = TileView(content: makeLabel(L("Technician"), size: 10, weight: .medium), horizontal: 6, vertical: 2)
        badge.cornerRadius = 4
        return hStack([vStack([name, model, adapter], spacing: 2), makeSpacer(), badge], alignment: .top)
    }

    private func batteryGrid(_ battery: BatteryInfo) -> NSView {
        typealias Cell = (String, (BatteryInfo) -> String?)
        let charging = battery.isCharging == true
        let rows: [[Cell]] = [
            [(L("Design cap."), { $0.designCapacity.map(Format.milliampHours) }),
             (L("Max cap."), { $0.rawMaxCapacity.map(Format.milliampHours) })],
            [(L("Health"), { $0.healthPercent.map { Format.percent($0, digits: 1) } }),
             (L("Cycles"), { $0.cycleCount.map { Format.number(Double($0)) } })],
            [(L("Current"), { $0.amperage.map { Format.milliamps($0) } }),
             (L("Voltage"), { $0.voltage.map { Format.volts(millivolts: $0) } })],
            [(L("Temperature"), { $0.temperature.map { Format.temperature($0) } }),
             charging ? (L("Full in"), { $0.timeToFull.map(Format.minutes) })
                      : (L("Remaining"), { ($0.timeToEmpty ?? $0.timeRemaining).map(Format.minutes) })],
        ]
        var views: [NSView] = [hStack([makeSectionTitle(L("Battery")), makeSpacer()])]
        for row in rows {
            let cells = row.map { title, value -> NSView in
                let label = makeLabel("–", font: LegacyStyle.mono(LegacyStyle.body))
                label.alignment = .right
                label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
                updaters.append { [unowned self] in label.stringValue = core.battery.flatMap(value) ?? "–" }
                return TileView(content: hStack([makeLabel(title, color: .secondaryLabelColor), makeSpacer(), label], spacing: 4))
            }
            let line = hStack(cells, spacing: 6)
            line.distribution = .fillEqually
            views.append(line)
        }
        return column(views, spacing: 6)
    }

    private func cellSection(count: Int) -> NSView {
        let badgeLabel = makeLabel("", size: LegacyStyle.caption, weight: .medium)
        let badge = TileView(content: badgeLabel, horizontal: 6, vertical: 2)
        badge.cornerRadius = 4
        var views: [NSView] = [hStack([makeSectionTitle(L("Cell voltages")), makeSpacer(), badge])]
        updaters.append { [unowned self] in
            let cells = core.battery?.cellVoltages ?? []
            let spread = (cells.max() ?? 0) - (cells.min() ?? 0)
            let balanced = spread <= UserDefaults.standard.integer(forKey: Pref.cellImbalanceThreshold)
            let color = balanced ? LegacyStyle.cool : LegacyStyle.hot
            badgeLabel.stringValue = (balanced ? "✓ " : "⚠︎ ") + (balanced
                ? L("Spread %@ · balanced", Format.millivolts(spread))
                : L("Spread %@ · imbalanced", Format.millivolts(spread)))
            badgeLabel.textColor = color
            badge.fillColor = color.withAlphaComponent(0.15)
        }
        for index in 0..<count {
            let title = makeLabel(L("Cell %lld", index + 1))
            title.widthAnchor.constraint(equalToConstant: 64).isActive = true
            let bar = LevelBar(height: 4)
            let value = makeLabel("–", font: LegacyStyle.mono(LegacyStyle.body))
            value.alignment = .right
            value.widthAnchor.constraint(equalToConstant: 72).isActive = true
            updaters.append { [unowned self] in
                let cells = core.battery?.cellVoltages ?? []
                guard index < cells.count else { return }
                bar.fraction = (Double(cells[index]) - 3000) / 1350 // 3.0 V … 4.35 V
                value.stringValue = Format.volts(millivolts: cells[index], digits: 3)
            }
            views.append(hStack([title, bar, value], spacing: 10))
        }
        return column(views, spacing: 5)
    }

    private func technicianSensors() -> NSView {
        let shown = shownSensors
        let matched = shown.filter(\.isMatched).sorted(by: SensorOrder.displayOrder)
        let unmatched = shown.filter { !$0.isMatched }.sorted { $0.name < $1.name }
        let count = makeLabel(L("%lld / %lld matched on this model", shown.filter(\.isModelMatch).count, shown.count),
                              size: LegacyStyle.caption, color: .secondaryLabelColor)

        var rows: [NSView] = []
        for sensor in matched {
            rows.append(techSensorRow(sensor))
            rows.append(makeSeparator())
        }
        if !unmatched.isEmpty {
            let disclosure = ActionButton(title: L("Unmatched sensors (%lld)", unmatched.count)) { [unowned self] in
                showUnmatched.toggle()
                update()
            }
            disclosure.bezelStyle = .disclosure
            disclosure.setButtonType(.pushOnPushOff)
            disclosure.title = ""
            disclosure.state = showUnmatched ? .on : .off
            rows.append(hStack([disclosure, makeLabel(L("Unmatched sensors (%lld)", unmatched.count))], spacing: 4))
            if showUnmatched {
                rows += unmatched.map(techSensorRow)
            }
        }
        let height = min(CGFloat(matched.count + (unmatched.isEmpty ? 0 : 1)) * techRowHeight, 300)
        return column([
            hStack([makeSectionTitle(L("Sensors")), makeSpacer(), count]),
            scrollList(rows, spacing: 0, height: height),
        ], spacing: 6)
    }

    private func techSensorRow(_ sensor: DisplaySensor) -> NSView {
        let dot = DotView()
        var views: [NSView] = [dot, makeLabel(sensor.name)]
        if sensor.isMatched && sensor.isEstimated {
            let tag = makeLabel(L("estimated"), size: 10)
            let badge = TileView(content: tag, horizontal: 4, vertical: 1)
            badge.cornerRadius = 3
            views.append(badge)
            updaters.append {
                let warm = LegacyStyle.warm(in: badge)
                tag.textColor = warm
                badge.fillColor = warm.withAlphaComponent(0.15)
            }
        }
        let raw = makeLabel(sensor.descriptor.rawLabel, color: .tertiaryLabelColor, font: LegacyStyle.mono(LegacyStyle.caption))
        raw.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let value = makeLabel("–", font: LegacyStyle.mono(LegacyStyle.body))
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 52).isActive = true
        views += [makeSpacer(), raw, value]
        let row = hStack(views, spacing: 8)
        row.heightAnchor.constraint(equalToConstant: techRowHeight - 1).isActive = true
        updaters.append { [unowned self] in
            let v = core.value(of: sensor)
            dot.color = LegacyStyle.temperatureColor(v, in: row)
            value.stringValue = v.map { Format.degrees($0, digits: 1) } ?? "–"
        }
        return row
    }

    private func fanRow() -> NSView {
        var views: [NSView] = []
        if core.fans.isEmpty {
            views.append(makeLabel(L("No fans"), color: .secondaryLabelColor))
        }
        for (i, fan) in core.fans.enumerated() {
            let value = makeLabel("–", font: LegacyStyle.mono(LegacyStyle.body))
            updaters.append { [unowned self] in
                value.stringValue = i < core.fans.count ? core.fans[i].actual.map(Format.rpm) ?? "–" : "–"
            }
            views += [makeLabel(L("Fan %lld", fan.index + 1), color: .secondaryLabelColor), value]
            if i < core.fans.count - 1 { views.append(makeSpacer()) }
        }
        views.append(makeSpacer())
        return TileView(content: hStack(views), horizontal: 10, vertical: 7)
    }

    // MARK: - Helpers

    /// Vertical list in a scroll view of fixed height (like the SwiftUI panels).
    private func scrollList(_ rows: [NSView], spacing: CGFloat, height: CGFloat) -> NSView {
        let list = vStack(rows, spacing: spacing)
        for row in rows {
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        let document = FlippedView()
        list.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        let heightConstraint = scroll.heightAnchor.constraint(equalToConstant: max(height, 1))
        heightConstraint.isActive = true
        listHeight = heightConstraint
        return scroll
    }

    /// Vertical stack whose children all take its full width.
    private func column(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let stack = vStack(views, spacing: spacing)
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }
}
