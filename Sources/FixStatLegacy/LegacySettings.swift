import AppKit
import MacSensors
import FixStatCore

/// Settings window of the AppKit interface: General, Thresholds and Sensors, like the
/// SwiftUI `SettingsView`. Controls are bound to UserDefaults, so both interfaces share
/// the same preferences.
final class LegacySettingsController: NSWindowController, NSWindowDelegate {
    private let core: MonitorCore
    private let tabs = NSTabView()
    private var updaters: [() -> Void] = []
    private var defaultsObserver: NSObjectProtocol?
    private let sensorTable = LegacySensorTable()

    private static let width: CGFloat = 540
    private static let formWidth: CGFloat = 480

    init(core: MonitorCore) {
        self.core = core
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L("Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        tabs.addTabViewItem(item(L("General"), generalTab()))
        tabs.addTabViewItem(item(L("Thresholds"), thresholdTab()))
        tabs.addTabViewItem(item(L("Sensors"), sensorTab()))
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            content.widthAnchor.constraint(equalToConstant: Self.width),
            content.heightAnchor.constraint(equalToConstant: 600),
        ])
        window.contentView = content
        window.center()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    func select(tab: Int) {
        guard tab >= 0, tab < tabs.numberOfTabViewItems else { return }
        tabs.selectTabViewItem(at: tab)
    }

    override func showWindow(_ sender: Any?) {
        sensorTable.reload(core: core)
        super.showWindow(sender)
        // No text field focused on opening (like the SwiftUI Settings window).
        window?.makeFirstResponder(nil)
    }

    private func refresh() {
        for update in updaters { update() }
    }

    private func item(_ title: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        // Scrolls when a tab is taller than the window (small screens, more settings).
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(view)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 18),
            view.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -18),
            view.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            view.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        item.view = scroll
        return item
    }

    // MARK: General

    private func generalTab() -> NSView {
        var rows: [NSView] = [makeSectionTitle(L("Menu bar"))]
        if core.profile.hasBattery {
            rows += [checkbox(L("Battery icon"), key: Pref.menuBarBatteryIcon),
                     checkbox(L("Battery percentage"), key: Pref.menuBarBatteryPercent)]
        }
        rows += [checkbox(L("CPU temperature"), key: Pref.menuBarCPUTemperature), spacer()]
        if #available(macOS 10.14, *) {
            rows += [labeled(L("Appearance"), appearanceControl()), spacer()]
        }
        rows += [
            checkbox(L("Always show the Dock icon"), key: Pref.showInDock),
            makeNote(L("Otherwise the Dock icon appears while a FixStat window is open, so windows do not get lost behind other apps."),
                     width: Self.formWidth),
            spacer(),
            checkbox(L("Technician mode"), key: Pref.technicianMode),
            makeNote(L("Shows raw battery data, cell voltages and every sensor with its raw key."), width: Self.formWidth),
            spacer(),
            labeled(L("Update interval"), intervalPopup()),
            loginItemCheckbox(),
            loginError,
            makeNote(L("While the menu is closed, values refresh at most every 5 seconds to save energy."), width: Self.formWidth),
            spacer(),
            makeSectionTitle(L("PDF report")),
            labeled(L("Shop name"), textField(key: Pref.reportShopName, placeholder: L("Optional"))),
            labeled(L("Note at the bottom"), textField(key: Pref.reportNote,
                                                       placeholder: L("Optional, e.g. phone or warranty terms"))),
            checkbox(L("Show full serial numbers in reports"), key: Pref.reportFullSerial),
            makeNote(L("Applies to PDF, CSV and JSON. Reports often reach customers or the internet, and a serial number reveals ownership and warranty details: keep it masked in reports you share publicly, e.g. in bug reports."),
                     width: Self.formWidth),
            spacer(),
            labeled(L("Version"), makeLabel("\(AboutInfo.version) (\(AboutInfo.build))")),
            hStack([ActionButton(title: L("About FixStat")) { AboutInfo.show() }, makeSpacer(),
                    ActionButton.link(L("Project page")) { NSWorkspace.shared.open(AboutInfo.repositoryURL) }]),
        ]
        return form(rows)
    }

    @available(macOS 10.14, *)
    private func appearanceControl() -> NSView {
        let values = ["system", "light", "dark"]
        let control = NSSegmentedControl(labels: [L("System"), L("Light"), L("Dark")], trackingMode: .selectOne,
                                         target: self, action: #selector(appearanceChanged(_:)))
        updaters.append {
            let current = UserDefaults.standard.string(forKey: Pref.appearance) ?? "system"
            control.selectedSegment = values.firstIndex(of: current) ?? 0
        }
        return control
    }

    @objc private func appearanceChanged(_ sender: NSSegmentedControl) {
        let values = ["system", "light", "dark"]
        UserDefaults.standard.set(values[max(0, sender.selectedSegment)], forKey: Pref.appearance)
    }

    private func intervalPopup() -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.second]
        formatter.unitsStyle = .full
        for seconds in Pref.intervals {
            popup.addItem(withTitle: formatter.string(from: seconds) ?? "\(seconds)")
            popup.lastItem?.representedObject = seconds
        }
        popup.target = self
        popup.action = #selector(intervalChanged(_:))
        updaters.append {
            let current = UserDefaults.standard.double(forKey: Pref.updateInterval)
            popup.selectItem(at: Pref.intervals.firstIndex(of: current) ?? Pref.intervals.firstIndex(of: Pref.defaultInterval) ?? 0)
        }
        return popup
    }

    @objc private func intervalChanged(_ sender: NSPopUpButton) {
        guard let seconds = sender.selectedItem?.representedObject as? Double else { return }
        UserDefaults.standard.set(seconds, forKey: Pref.updateInterval)
    }

    // MARK: Thresholds

    private func thresholdTab() -> NSView {
        let defaults = UserDefaults.standard
        let warm = stepper(key: Pref.warmThreshold, step: 1,
                           range: { 30...(defaults.double(forKey: Pref.hotThreshold) - 1) },
                           text: { Format.temperature($0, digits: 0) })
        let hot = stepper(key: Pref.hotThreshold, step: 1,
                          range: { (defaults.double(forKey: Pref.warmThreshold) + 1)...100 },
                          text: { Format.temperature($0, digits: 0) })
        let imbalance = stepper(key: Pref.cellImbalanceThreshold, step: 5, range: { 5...500 },
                                text: { Format.millivolts(Int($0)) })
        let legend = hStack([legendItem(LegacyStyle.cool, L("Cool")), legendItem(nil, L("Warm")),
                             legendItem(LegacyStyle.hot, L("Hot"))], spacing: 12)
        let restore = ActionButton(title: L("Restore defaults")) {
            defaults.set(Pref.defaultWarm, forKey: Pref.warmThreshold)
            defaults.set(Pref.defaultHot, forKey: Pref.hotThreshold)
            defaults.set(Pref.defaultCellImbalance, forKey: Pref.cellImbalanceThreshold)
        }
        var rows: [NSView] = [
            makeSectionTitle(L("Temperature colours")),
            labeled(L("Warm from"), warm),
            labeled(L("Hot from"), hot),
            legend,
            spacer(),
        ]
        if core.profile.hasBattery {
            rows += [makeSectionTitle(L("Cell voltage spread")),
                     labeled(L("Warn above"), imbalance),
                     makeNote(L("Difference between the highest and lowest cell voltage."), width: Self.formWidth),
                     spacer()]
        }
        return form(rows + notificationRows() + [
            spacer(),
            restore,
        ])
    }

    // MARK: Notifications

    private var authorized: Bool?
    private let authorizationLabel = makeLabel("", size: LegacyStyle.caption)

    private func notificationRows() -> [NSView] {
        let enabled = NSButton(checkboxWithTitle: L("Show notifications"), target: self, action: #selector(alertsToggled(_:)))
        enabled.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values.\(Pref.alertsEnabled)", options: nil)
        let kinds: [(String, AlertManager.Kind)] = [
            (L("CPU / GPU temperature"), .chipTemperature),
            (L("Battery temperature above 45 °C"), .batteryTemperature),
            (L("Cell spread above the warning threshold (on battery)"), .cellImbalance),
            (L("Power adapter connected but not charging"), .chargingStopped),
            (L("Mac turned off unexpectedly (possible battery problem)"), .unexpectedShutdown),
        ].filter { core.profile.hasBattery || !$0.1.needsBattery }
        let toggles = kinds.map { title, kind -> NSButton in
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            // Unset means on, like the SwiftUI @AppStorage default.
            box.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values.\(kind.enabledKey)",
                     options: [.nullPlaceholder: true])
            return box
        }
        let limit = stepper(key: Pref.alertChipTemperature, step: 1, range: { 60...110 },
                            text: { Format.temperature($0, digits: 0) })
        updaters.append { [weak self] in
            let on = UserDefaults.standard.bool(forKey: Pref.alertsEnabled)
            toggles.forEach { $0.isEnabled = on }
            self?.updateAuthorizationLabel()
        }
        LegacyNotifications.checkAuthorization { [weak self] allowed in
            self?.authorized = allowed
            self?.updateAuthorizationLabel()
        }
        var rows: [NSView] = [makeSectionTitle(L("Notifications")), enabled, authorizationLabel, toggles[0],
                              labeled(L("Alert above"), limit)]
        rows += toggles.dropFirst().map { $0 as NSView }
        rows.append(makeNote(L("A notification is sent when a condition lasts from 30 seconds to 3 minutes, and repeated at most every 15 minutes."),
                             width: Self.formWidth))
        return rows
    }

    @objc private func alertsToggled(_ sender: NSButton) {
        guard sender.state == .on else { return }
        LegacyNotifications.requestAuthorization { [weak self] allowed in
            self?.authorized = allowed
            self?.updateAuthorizationLabel()
        }
    }

    private func updateAuthorizationLabel() {
        let on = UserDefaults.standard.bool(forKey: Pref.alertsEnabled)
        authorizationLabel.isHidden = !on || authorized == nil
        if authorized == true {
            authorizationLabel.stringValue = "✓ " + L("Notifications are allowed.")
            authorizationLabel.textColor = .secondaryLabelColor
        } else {
            authorizationLabel.stringValue = L("Notifications are turned off for FixStat. Allow them in System Settings › Notifications.")
            authorizationLabel.textColor = LegacyStyle.hot
        }
    }

    // MARK: Login item

    private lazy var loginError: NSTextField = {
        let label = makeNote("", width: Self.formWidth)
        label.isHidden = true
        return label
    }()

    private func loginItemCheckbox() -> NSButton {
        let box = NSButton(checkboxWithTitle: L("Open at login"), target: self, action: #selector(loginToggled(_:)))
        box.state = LegacyLoginItem.isEnabled ? .on : .off
        return box
    }

    @objc private func loginToggled(_ sender: NSButton) {
        if let error = LegacyLoginItem.set(sender.state == .on) {
            loginError.stringValue = error
            loginError.isHidden = false
            sender.state = LegacyLoginItem.isEnabled ? .on : .off
        } else {
            loginError.isHidden = true
        }
    }

    private func legendItem(_ color: NSColor?, _ title: String) -> NSView {
        let dot = DotView(size: 8)
        if let color {
            dot.color = color
        } else {
            updaters.append { dot.color = LegacyStyle.warm(in: dot) }
        }
        return hStack([dot, makeLabel(title, size: LegacyStyle.caption)], spacing: 4)
    }

    /// Value label and stepper bound to a numeric preference.
    private func stepper(key: String, step: Double, range: @escaping () -> ClosedRange<Double>,
                         text: @escaping (Double) -> String) -> NSView {
        let label = makeLabel("")
        label.alignment = .right
        let control = LegacyStepper { value in UserDefaults.standard.set(value, forKey: key) }
        control.increment = step
        control.valueWraps = false
        updaters.append {
            let value = UserDefaults.standard.double(forKey: key)
            let bounds = range()
            control.minValue = bounds.lowerBound
            control.maxValue = bounds.upperBound
            control.doubleValue = value
            label.stringValue = text(value)
        }
        return hStack([label, control], spacing: 6)
    }

    // MARK: Sensors

    private func sensorTab() -> NSView {
        let path = MonitorCore.userMapURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let pathLabel = makeLabel(path, color: .tertiaryLabelColor, font: LegacyStyle.mono(LegacyStyle.caption))
        pathLabel.isSelectable = true
        let table = sensorTable.makeView(core: core)
        table.heightAnchor.constraint(equalToConstant: 440).isActive = true
        let stack = vStack([
            makeNote(L("Hide sensors or give them your own name. Names are saved in your sensor map."), width: Self.formWidth),
            table,
            pathLabel,
        ], spacing: 8)
        table.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    // MARK: Helpers

    private func form(_ rows: [NSView]) -> NSView {
        let stack = vStack(rows, spacing: 8)
        stack.widthAnchor.constraint(equalToConstant: Self.formWidth).isActive = true
        return stack
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 4).isActive = true
        return view
    }

    private func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = makeLabel(title)
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        return hStack([label, control], spacing: 8)
    }

    private func checkbox(_ title: String, key: String) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values.\(key)", options: nil)
        return button
    }

    private func textField(key: String, placeholder: String) -> NSTextField {
        let field = NSTextField(string: "")
        field.placeholderString = placeholder
        field.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values.\(key)",
                   options: [.continuouslyUpdatesValue: true, .nullPlaceholder: placeholder])
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return field
    }
}

/// NSStepper that reports its new value through a closure.
final class LegacyStepper: NSStepper {
    private var handler: ((Double) -> Void)?

    convenience init(handler: @escaping (Double) -> Void) {
        self.init(frame: .zero)
        self.handler = handler
        target = self
        action = #selector(changed)
    }

    @objc private func changed() { handler?(doubleValue) }
}

/// Sensor list of the Sensors tab: visibility checkbox, own name, raw key.
final class LegacySensorTable: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var core: MonitorCore?
    private var sensors: [DisplaySensor] = []
    private let table = NSTableView()

    func makeView(core: MonitorCore) -> NSView {
        self.core = core
        for (id, title, width) in [("show", L("Show"), 44.0), ("name", L("Name"), 330.0), ("key", "", 70.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            table.addTableColumn(column)
        }
        table.headerView = nil
        table.rowHeight = 26
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        reload(core: core)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    func reload(core: MonitorCore) {
        sensors = core.sensors.sorted(by: SensorOrder.displayOrder)
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sensors.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let sensor = sensors[row]
        switch tableColumn?.identifier.rawValue {
        case "show":
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
            box.tag = row
            box.state = Self.hidden.contains(sensor.id) ? .off : .on
            return centered(box)
        case "name":
            let field = NSTextField(string: sensor.resolved?.name ?? "")
            field.placeholderString = SensorNames.defaultName(for: sensor)
            field.tag = row
            field.delegate = self
            field.bezelStyle = .roundedBezel
            return centered(field, fill: true)
        default:
            return centered(makeLabel(sensor.descriptor.rawLabel, color: .secondaryLabelColor,
                                      font: LegacyStyle.mono(LegacyStyle.caption)))
        }
    }

    private static var hidden: Set<String> {
        Pref.hiddenSet(UserDefaults.standard.string(forKey: Pref.hiddenSensors) ?? "")
    }

    @objc private func toggle(_ sender: NSButton) {
        guard sender.tag < sensors.count else { return }
        var set = Self.hidden
        let id = sensors[sender.tag].id
        if sender.state == .on { set.remove(id) } else { set.insert(id) }
        UserDefaults.standard.set(Pref.hiddenString(set), forKey: Pref.hiddenSensors)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field.tag < sensors.count, let core else { return }
        let sensor = sensors[field.tag]
        guard field.stringValue != (sensor.resolved?.name ?? "") else { return }
        core.rename(sensor, to: field.stringValue)
        reload(core: core)
    }

    private func centered(_ view: NSView, fill: Bool = false) -> NSView {
        let cell = NSTableCellView()
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
        var constraints = [
            view.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            view.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
        ]
        if fill { constraints.append(view.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4)) }
        NSLayoutConstraint.activate(constraints)
        return cell
    }
}
