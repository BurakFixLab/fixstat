import AppKit
import MacSensors
import FixStatCore

/// Content of one hardware check item. The window activates the pane while it is shown.
protocol LegacyCheckPane: AnyObject {
    var view: NSView { get }
    func activate()
    func deactivate()
}

/// A pane that renders blocks and rebuilds them on `refresh()`.
class BlockPane: LegacyCheckPane {
    let core: MonitorCore
    private let document = LegacyDocumentView(contentWidth: 580, padding: 0)
    var view: NSView { document }

    init(core: MonitorCore) {
        self.core = core
    }

    func blocks() -> [Block] { [] }
    func activate() { refresh() }
    func deactivate() {}

    func refresh() {
        document.show(blocks())
    }
}

/// Hardware checklist window: one test per component, each marked passed / failed /
/// skipped by the technician. Tests that measure something fill in the evidence and
/// mark the item passed on their own; the technician can always override.
final class LegacyHardwareCheck: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, LegacySnapshotStartable {
    private let core: MonitorCore
    private(set) var window: LegacyToolWindow!
    private let table = NSTableView()
    private let summary = makeLabel("", size: LegacyStyle.caption, color: .secondaryLabelColor)
    private let resetButton = NSButton()
    private let detail = NSStackView()
    private let titleLabel = makeLabel("", font: .systemFont(ofSize: 17, weight: .semibold))
    private let instructions = NSTextField(wrappingLabelWithString: "")
    private let paneContainer = NSView()
    private let evidence = NSTextField(wrappingLabelWithString: "")
    private var markButtons: [HardwareCheck.Status: NSButton] = [:]
    private let note = NSTextField(string: "")
    private var panes: [HardwareCheck.Item: LegacyCheckPane] = [:]
    private var current: HardwareCheck.Item?
    private var shownStatuses: [HardwareCheck.Status] = []
    private var items: [HardwareCheck.Item] { core.hardwareCheck.items }
    /// Item selected on first opening (`--item NAME` for snapshots); nil: the first item
    /// that applies to this Mac.
    static var initialItem: HardwareCheck.Item?

    init(core: MonitorCore) {
        self.core = core
        super.init()
        let content = buildContent()
        window = LegacyToolWindow(title: L("Hardware check"), view: content, size: NSSize(width: 900, height: 680))
        window.onOpen = { [unowned self] in
            if let current {
                panes[current]?.activate()
            } else if let first = Self.initialItem.flatMap({ items.contains($0) ? $0 : nil }) ?? items.first {
                select(first)
            }
            updateStatus()
            // The note field would take the focus, and the keyboard test ignores keys typed there.
            DispatchQueue.main.async { [weak self] in self?.window.window?.makeFirstResponder(nil) }
        }
        window.onClose = { [unowned self] in
            if let current { panes[current]?.deactivate() }
        }
        core.onHardwareCheckChange = { [weak self] in self?.updateStatus() }
    }

    // MARK: Layout

    private func buildContent() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.width = 230
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.dataSource = self
        table.delegate = self
        if #available(macOS 11.0, *) { table.style = .sourceList }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        resetButton.title = L("Reset")
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(reset)
        let sidebarFooter = vStack([summary, hStack([resetButton, makeSpacer(), LegacyExport.menuButton(core: core)])], spacing: 8)
        let sidebar = NSStackView(views: [scroll, sidebarFooter])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
        scroll.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        sidebarFooter.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        sidebarFooter.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        for view in sidebarFooter.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: sidebarFooter.widthAnchor, constant: -24).isActive = true
        }
        sidebar.widthAnchor.constraint(equalToConstant: 250).isActive = true

        instructions.font = .systemFont(ofSize: LegacyStyle.body)
        instructions.textColor = .secondaryLabelColor
        instructions.preferredMaxLayoutWidth = 600
        evidence.font = .systemFont(ofSize: LegacyStyle.body)
        evidence.textColor = .secondaryLabelColor
        evidence.preferredMaxLayoutWidth = 600

        var buttons: [NSView] = []
        for status in [HardwareCheck.Status.passed, .failed, .skipped] {
            let button = ActionButton(title: HardwareText.status(status)) { [unowned self] in mark(status) }
            button.setButtonType(.pushOnPushOff)
            markButtons[status] = button
            buttons.append(button)
        }
        note.placeholderString = L("Note")
        note.delegate = self
        let resultBar = vStack([makeSeparator(), evidence, hStack(buttons + [note], spacing: 8)], spacing: 8)

        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 12
        detail.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [titleLabel, instructions, paneContainer, resultBar] {
            detail.addArrangedSubview(view)
        }
        for view in [paneContainer, resultBar] {
            view.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -40).isActive = true
        }
        for view in resultBar.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: resultBar.widthAnchor).isActive = true
        }
        paneContainer.setContentHuggingPriority(.init(1), for: .vertical)
        paneContainer.setContentCompressionResistancePriority(.init(1), for: .vertical)

        let root = NSStackView(views: [sidebar, detail])
        root.orientation = .horizontal
        root.alignment = .top
        root.spacing = 0
        sidebar.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
        detail.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
        // The detail column takes the rest of the window, whatever the pane contains.
        detail.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -250).isActive = true
        return root
    }

    // MARK: Selection

    private func select(_ item: HardwareCheck.Item) {
        if let current, current != item { panes[current]?.deactivate() }
        current = item
        if let row = items.firstIndex(of: item), table.selectedRow != row {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        titleLabel.stringValue = HardwareText.title(item)
        instructions.stringValue = HardwareText.instructions(item)
        let pane = panes[item] ?? makePane(item)
        panes[item] = pane
        paneContainer.subviews.forEach { $0.removeFromSuperview() }
        let view = pane.view
        view.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor),
        ])
        pane.activate()
        updateStatus()
        window?.window?.makeFirstResponder(nil)
    }

    private func makePane(_ item: HardwareCheck.Item) -> LegacyCheckPane {
        switch item {
        case .keyboard:
            let pane = LegacyKeyboardPane(core: core)
            pane.isFocused = { [weak self] in
                guard let window = self?.window.window, NSApp.keyWindow === window else { return false }
                return !(window.firstResponder is NSText)
            }
            return pane
        case .touchBar: return LegacyTouchBarPane(core: core)
        case .trackpad: return LegacyTrackpadPane(core: core)
        case .display: return LegacyDisplayPane(core: core)
        case .ambientLight: return LegacyAmbientLightPane(core: core)
        case .speakers: return LegacySpeakerPane(core: core)
        case .microphone: return LegacyMicrophonePane(core: core)
        case .camera: return LegacyCameraPane(core: core)
        case .sensors: return LegacySensorCheckPane(core: core)
        case .fans: return LegacyFanPane(core: core)
        case .wifi: return LegacyWiFiPane(core: core)
        case .bluetooth: return LegacyBluetoothPane(core: core)
        case .ports: return LegacyPortsPane(core: core)
        case .lid: return LegacyLidPane(core: core)
        }
    }

    /// `--start-test SECONDS` (snapshots): starts the test of the pane on screen, if it has one.
    func start(seconds: TimeInterval) {
        guard let current, let pane = panes[current] as? LegacySnapshotStartable else { return }
        pane.start(seconds: seconds)
    }

    // MARK: Status

    private func updateStatus() {
        let check = core.hardwareCheck
        summary.stringValue = L("%lld passed · %lld failed · %lld not tested",
                                check.count(.passed), check.count(.failed), check.count(.untested))
        resetButton.isEnabled = !check.isEmpty
        // Tests report evidence many times a second; the list only changes with a status.
        let statuses = items.map { check[$0].status }
        if statuses != shownStatuses {
            shownStatuses = statuses
            table.reloadData()
            if let current, let row = items.firstIndex(of: current) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        guard let current else { return }
        let entry = check[current]
        evidence.stringValue = entry.detail ?? ""
        evidence.isHidden = entry.detail == nil
        for (status, button) in markButtons {
            button.state = entry.status == status ? .on : .off
            if #available(macOS 10.14, *) {
                button.contentTintColor = entry.status == status ? (status == .failed ? LegacyStyle.hot : LegacyStyle.cool) : nil
            }
        }
        if note.currentEditor() == nil { note.stringValue = entry.note }
    }

    private func mark(_ status: HardwareCheck.Status) {
        guard let current else { return }
        core.hardwareCheck[current].status = core.hardwareCheck[current].status == status ? .untested : status
        core.hardwareCheck[current].date = Date()
        updateStatus()
    }

    @objc private func reset() {
        core.resetHardwareCheck()
        updateStatus()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let current else { return }
        core.hardwareCheck[current].note = note.stringValue
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let status = core.hardwareCheck[item].status
        let symbol: (String, NSColor)
        switch status {
        case .untested: symbol = ("○", .tertiaryLabelColor)
        case .passed: symbol = ("✓", LegacyStyle.cool)
        case .failed: symbol = ("✗", LegacyStyle.hot)
        case .skipped: symbol = ("–", .secondaryLabelColor)
        }
        let icon = makeLabel(symbol.0, color: symbol.1)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        let cell = NSTableCellView()
        let stack = hStack([makeLabel(HardwareText.title(item), size: 13), makeSpacer(), icon])
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < items.count, items[row] != current else { return }
        select(items[row])
    }
}

// MARK: - Display

final class LegacyDisplayPane: BlockPane {
    private var shown: Set<Int> = []
    private let swatches = PatternSwatches()

    override func blocks() -> [Block] {
        swatches.shown = shown
        var blocks: [Block] = []
        if let screen = DisplayInfo.builtInScreen() {
            blocks.append(.headline(DisplayInfo.describe(screen), nil))
        }
        blocks.append(.view(hStack([swatches, makeSpacer()])))
        blocks.append(.actions([DocAction(title: L("Start full-screen test")) { [unowned self] in
            LegacyDisplayTestWindow.show { [weak self] index in
                guard let self else { return }
                shown.insert(index)
                if let screen = DisplayInfo.builtInScreen() {
                    core.recordCheck(.display, detail: DisplayInfo.describe(screen) + " · " + DisplayInfo.patternsShown(shown.count))
                }
                refresh()
            }
        }]))
        return blocks
    }
}

/// The seven test colours; the ones already shown carry a check mark.
final class PatternSwatches: NSView {
    var shown: Set<Int> = [] { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(DisplayInfo.patternCount) * 36 - 6, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        for index in 0..<DisplayInfo.patternCount {
            let rect = NSRect(x: CGFloat(index) * 36, y: 0, width: 30, height: 20)
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            if let gradient = LegacyDisplayTestWindow.gradient(index) {
                gradient.draw(in: path, angle: 0)
            } else {
                LegacyDisplayTestWindow.color(index).setFill()
                path.fill()
            }
            NSColor.labelColor.withAlphaComponent(0.2).setStroke()
            path.stroke()
            if shown.contains(index) {
                let mark = "✓" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11),
                                                                 .foregroundColor: NSColor.gray]
                let size = mark.size(withAttributes: attributes)
                mark.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            }
        }
    }
}

/// Borderless full-screen window on the built-in display cycling through the patterns.
final class LegacyDisplayTestWindow: NSWindow {
    private static var current: LegacyDisplayTestWindow?
    private var index = 0
    private var onShow: ((Int) -> Void)?
    private let pattern = PatternView()

    static func color(_ index: Int) -> NSColor {
        switch index {
        case 0: return .black
        case 1: return .white
        case 2: return NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        case 3: return NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        case 4: return NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        default: return NSColor(white: 0.5, alpha: 1)
        }
    }

    static func gradient(_ index: Int) -> NSGradient? {
        index == 6 ? NSGradient(starting: .black, ending: .white) : nil
    }

    static func show(onShow: @escaping (Int) -> Void) {
        guard current == nil, let screen = DisplayInfo.builtInScreen() else { return }
        let window = LegacyDisplayTestWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered,
                                             defer: false, screen: screen)
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.onShow = onShow
        window.contentView = window.pattern
        window.setFrame(screen.frame, display: true)
        window.showPattern(0, hint: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.hide()
        current = window
    }

    override var canBecomeKey: Bool { true }

    private func showPattern(_ i: Int, hint: Bool = false) {
        index = i
        pattern.index = i
        pattern.hint = hint ? L("Click or → next colour · ← back · esc ends") : nil
        if hint {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.pattern.hint = nil }
        }
        onShow?(i)
    }

    private func step(_ delta: Int) {
        let next = index + delta
        if next >= DisplayInfo.patternCount { finish() }
        else if next >= 0 { showPattern(next) }
    }

    private func finish() {
        NSCursor.unhide()
        orderOut(nil)
        Self.current = nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: finish() // esc
        case 123: step(-1) // ←
        default: step(1)
        }
    }

    override func mouseDown(with event: NSEvent) { step(1) }
    override func rightMouseDown(with event: NSEvent) { step(-1) }

    private final class PatternView: NSView {
        var index = 0 { didSet { needsDisplay = true } }
        var hint: String? { didSet { needsDisplay = true } }

        override func draw(_ dirtyRect: NSRect) {
            if let gradient = LegacyDisplayTestWindow.gradient(index) {
                gradient.draw(in: bounds, angle: 0)
            } else {
                LegacyDisplayTestWindow.color(index).setFill()
                bounds.fill()
            }
            guard let hint else { return }
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17),
                                                             .foregroundColor: NSColor.black]
            let size = (hint as NSString).size(withAttributes: attributes)
            let box = NSRect(x: bounds.midX - size.width / 2 - 12, y: bounds.midY - size.height / 2 - 12,
                             width: size.width + 24, height: size.height + 24)
            NSColor(white: 0.92, alpha: 0.95).setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
            (hint as NSString).draw(at: NSPoint(x: box.minX + 12, y: box.minY + 12), withAttributes: attributes)
        }
    }
}

// MARK: - Wi-Fi

final class LegacyWiFiPane: BlockPane {
    private var link: WiFiLink?
    private var scan: WiFiScan?
    private var scanning = false
    private var timer: Timer?

    override func activate() {
        link = WiFiLink.read()
        super.activate()
        timer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.link = WiFiLink.read()
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func deactivate() {
        timer?.invalidate()
        timer = nil
    }

    override func blocks() -> [Block] {
        var blocks: [Block] = []
        if let link {
            blocks.append(.rows(link.rows.map { DocRow(title: $0.0, value: $0.1) }, labelWidth: 160))
        } else {
            blocks.append(.status(L("No Wi-Fi interface found."), .bad))
        }
        let button = ActionButton(title: scanning ? L("Scanning…") : L("Scan for networks")) { [unowned self] in runScan() }
        button.isEnabled = !scanning && link?.powerOn == true
        var row: [NSView] = [button]
        if let scan { row.append(makeLabel(scan.summary)) }
        blocks.append(.view(hStack(row + [makeSpacer()])))
        return blocks
    }

    private func runScan() {
        scanning = true
        refresh()
        background({ WiFiScan.run() }, done: { [weak self] result in
            guard let self else { return }
            scan = result
            scanning = false
            if let result {
                core.recordCheck(.wifi, detail: result.summary, passed: result.count > 0 && link?.connected == true)
            }
            refresh()
        })
    }
}

// MARK: - Bluetooth

final class LegacyBluetoothPane: BlockPane {
    private var controller: BluetoothController?
    private var loaded = false
    private let scanner = BluetoothScan()

    override init(core: MonitorCore) {
        super.init(core: core)
        scanner.onChange = { [weak self] in
            guard let self else { return }
            if scanner.state == .finished {
                core.recordCheck(.bluetooth, detail: ([controller?.chipset].compactMap { $0 } + [scanner.summary])
                    .joined(separator: " · "), passed: scanner.devices > 0)
            }
            refresh()
        }
    }

    override func activate() {
        super.activate()
        guard !loaded else { return }
        loaded = true
        background({ BluetoothController.read() }, done: { [weak self] controller in
            self?.controller = controller
            self?.refresh()
        })
    }

    override func deactivate() {
        scanner.stop()
    }

    override func blocks() -> [Block] {
        var blocks: [Block] = []
        if let controller {
            blocks.append(.rows(controller.rows.map { DocRow(title: $0.0, value: $0.1) }, labelWidth: 160))
        } else {
            blocks.append(.progress(""))
        }
        if scanner.state == .unauthorized {
            blocks.append(.status(L("FixStat has no Bluetooth access. Allow it in System Settings › Privacy & Security › Bluetooth."), .bad))
        }
        let scanning = scanner.state == .scanning
        let button = ActionButton(title: scanning ? L("Scanning…") : L("Scan for devices")) { [unowned self] in
            scanner.scan(seconds: 10)
        }
        button.isEnabled = !scanning
        var row: [NSView] = [button]
        if scanning || scanner.state == .finished { row.append(makeLabel(scanner.summary)) }
        blocks.append(.view(hStack(row + [makeSpacer()])))
        return blocks
    }
}

// MARK: - Ports

final class LegacyPortsPane: BlockPane, LegacySnapshotStartable {
    private var ports: [PortStatus] = []
    private var volumes: [USBVolume] = []
    private var history = PortHistory()
    private var timer: Timer?
    private var reading = false
    /// `--start-test` (snapshots): test the first USB drive once the volumes are read.
    private var startWhenReady = false
    private lazy var speed: USBSpeedRunner = {
        let runner = USBSpeedRunner(monitor: core)
        runner.onChange = { [weak self] in
            guard let self else { return }
            if runner.state == .finished { recordCheck() }
            refresh()
        }
        return runner
    }()

    override func activate() {
        super.activate()
        poll()
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func deactivate() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard !reading else { return }
        reading = true
        background({ (PortReader.read(), USBVolumes.mounted()) }, done: { [weak self] current, mounted in
            guard let self else { return }
            reading = false
            let changed = current != ports || mounted != volumes
            ports = current
            volumes = mounted
            if history.update(current) { recordCheck() }
            if startWhenReady, let volume = volumes.first {
                startWhenReady = false
                speed.start(volume, port: volume.port(in: ports))
            }
            if changed { refresh() }
        })
    }

    func start(seconds: TimeInterval) {
        startWhenReady = true
    }

    private func recordCheck() {
        let speeds = core.usbSpeedResults
        core.recordCheck(.ports, detail: history.detail(ports, speeds: speeds), passed: history.passed(ports, speeds: speeds))
    }

    override func blocks() -> [Block] {
        if ports.isEmpty {
            return [.secondary(L("This Mac does not publish its port state (IOPort). Check the ports by hand.")), speedGroup()]
        }
        return ports.map(card) + [speedGroup()]
    }

    /// USB drive speed: write–verify a scratch file on a USB drive, per port.
    private func speedGroup() -> Block {
        var blocks: [Block] = [
            .secondary(L("Writes 256 MB to the free space of a USB drive, reads it back and compares every byte; the drive's files are not touched. Test the same drive in each port: a port that is clearly slower or gives errors points to its connector or USB 3 lane.")),
        ]
        if volumes.isEmpty {
            blocks.append(.secondary(L("Plug in a USB memory stick or SSD to test the ports' speed.")))
        }
        let running = speed.state == .running
        for volume in volumes {
            let port = volume.port(in: ports)
            let details = [port.map(PortText.name), volume.device.name, volume.device.megabitsPerSecond.map(PortText.speed),
                           L("%@ free", Format.bytes(Double(volume.availableBytes)))].compactMap { $0 }
            var row: [NSView] = [makeLabel(volume.name + "  ·  " + details.joined(separator: " · ")), makeSpacer()]
            if USBSpeedRunner.hasSpace(volume) {
                let button = ActionButton(title: L("Test speed")) { [unowned self] in speed.start(volume, port: port) }
                button.isEnabled = !running
                row.append(button)
            } else {
                row.append(makeLabel(L("not enough free space"), color: .secondaryLabelColor))
            }
            blocks.append(.view(hStack(row)))
        }
        if running {
            let phase = speed.phase == .write ? L("Writing…") : L("Reading and verifying…")
            blocks.append(.progress(phase + " " + Format.percent(speed.fraction * 100)))
            blocks.append(.actions([DocAction(title: L("Stop")) { [unowned self] in speed.stop() }]))
        }
        let results = core.usbSpeedResults
        if !results.isEmpty {
            let rows = results.map(USBSpeedText.row)
            blocks.append(.table(header: USBSpeedText.header, rows: rows, tones: rows.map { $0.map { _ in nil } }, leading: true))
            for finding in USBSpeedText.findings(results) { blocks.append(.status(finding, .bad)) }
        }
        return .group(L("USB drive speed"), blocks)
    }

    private func card(_ port: PortStatus) -> Block {
        let seen = history.seen[port.id] ?? []
        var blocks: [Block] = [
            .headline(PortText.name(port) + "  ·  " + (port.connected ? L("Connected") : L("Empty")), port.connected ? .good : nil),
            .status(L("Tested: ") + PortText.seenSummary(seen), seen.isEmpty ? .neutral : .good),
        ]
        if port.connected, !PortText.activity(port).isEmpty { blocks.append(.text(PortText.activity(port))) }
        if let slow = history.slowLane(port) { blocks.append(.status(PortText.slowLane(slow), .bad)) }
        for device in port.devices {
            blocks.append(.text("• " + (device.name ?? L("USB device"))
                                + (device.megabitsPerSecond.map { " · " + PortText.speed($0) } ?? "")))
        }
        var counters: [DocRow] = []
        if let count = port.overcurrentCount { counters.append(counter(L("Overcurrent"), count)) }
        if let count = port.enumerationFailures { counters.append(counter(L("USB enumeration failures"), count)) }
        if let c = port.controller {
            counters += [counter(L("Short circuit detections"), c.shortDetect), counter(L("PD hard resets"), c.hardReset),
                         counter(L("Input FET failures"), c.inputFETFailures), counter(L("I²C errors"), c.i2cErrors)]
        }
        if !counters.isEmpty { blocks.append(.rows(counters, labelWidth: 220)) }
        if let count = port.connectionCount {
            blocks.append(.caption(L("Plug-ins since start: %lld", count)))
        }
        return .group(nil, blocks)
    }

    private func counter(_ title: String, _ count: Int) -> DocRow {
        DocRow(title: title, value: Format.number(Double(count)), tone: count > 0 ? .bad : nil)
    }
}

// MARK: - Lid

final class LegacyLidPane: BlockPane {
    private let watcher = LidWatcher()

    override init(core: MonitorCore) {
        super.init(core: core)
        watcher.onChange = { [weak self] in
            guard let self else { return }
            if let event = watcher.detected { core.recordCheck(.lid, detail: event, passed: true) }
            refresh()
        }
    }

    override func activate() {
        watcher.start()
        super.activate()
    }

    override func deactivate() {
        watcher.stop()
    }

    override func blocks() -> [Block] {
        var blocks: [Block] = []
        if let closed = watcher.closed {
            blocks.append(.headline(closed ? L("Lid closed") : L("Lid open"), nil))
        } else {
            blocks.append(.secondary(L("This Mac has no lid sensor.")))
        }
        if let event = watcher.detected {
            blocks.append(.status(event, .good))
        } else {
            blocks.append(.secondary(L("Waiting for the lid to close…")))
        }
        return blocks
    }
}

/// Fan test: live speeds, then load and the verdict (core `FanTestRunner`).
// MARK: - Temperature sensors

final class LegacySensorCheckPane: BlockPane, LegacySnapshotStartable {
    private lazy var runner = SensorCheckRunner(monitor: core)
    private let loadBox = NSButton(checkboxWithTitle: L("Also under CPU and GPU load (45 s)"), target: nil, action: nil)

    override init(core: MonitorCore) {
        super.init(core: core)
        runner.onChange = { [weak self] in self?.refresh() }
        let stored = UserDefaults.standard.object(forKey: "sensorCheck.underLoad") as? Bool ?? true
        loadBox.state = stored ? .on : .off
        loadBox.target = self
        loadBox.action = #selector(loadChanged)
    }

    @objc private func loadChanged() {
        UserDefaults.standard.set(loadBox.state == .on, forKey: "sensorCheck.underLoad")
    }

    override func deactivate() {
        runner.stop()
    }

    /// `--start-test SECONDS` (snapshots): a shortened run (that long idle and under load).
    func start(seconds: TimeInterval) {
        runner.stop()
        runner.shortened = seconds
        start()
    }

    private func start() {
        runner.underLoad = loadBox.state == .on
        runner.start()
    }

    override func blocks() -> [Block] {
        var blocks: [Block] = []
        if runner.state == .running {
            let left = Format.duration(runner.remaining.rounded(.up))
            blocks.append(.progress(runner.phase == .load ? L("Under load… %@", left) : L("Watching the sensors… %@", left)))
            blocks.append(.actions([DocAction(title: L("Stop")) { [unowned self] in runner.stop() }]))
        } else {
            let button = ActionButton(title: core.lastSensorCheck == nil ? L("Check sensors") : L("Check again")) {
                [unowned self] in start()
            }
            blocks.append(.view(hStack([button, loadBox, makeSpacer()], spacing: 16)))
        }
        guard let result = core.lastSensorCheck else { return blocks }
        blocks.append(.status(SensorCheckText.verdict(result), result.passed ? .good : .bad))
        if !result.known.isEmpty {
            blocks.append(.group(L("Suspicious sensors"),
                                 result.known.map { .status(SensorCheckText.fault($0, name: result.names[$0.uid]), .bad) }))
        }
        let symptoms = SensorCheckText.symptoms(result)
        if !symptoms.isEmpty {
            blocks.append(.group(L("What the Mac does"), symptoms.map { .status($0, .bad) }))
        }
        if !result.unclear.isEmpty {
            blocks.append(.group(L("Unclear"), [.secondary(SensorCheckText.unclearNote)]
                + result.unclear.map { .text("• " + SensorCheckText.fault($0, name: result.names[$0.uid])) }))
        }
        return blocks
    }
}

final class LegacyFanPane: BlockPane, LegacySnapshotStartable {
    private lazy var runner = FanTestRunner(monitor: core)

    override init(core: MonitorCore) {
        super.init(core: core)
        runner.onChange = { [weak self] in self?.refresh() }
    }

    override func activate() {
        runner.prepare()
        super.activate()
    }

    override func deactivate() {
        runner.stop()
    }

    /// `--start-test SECONDS` (snapshots): a shortened run.
    func start(seconds: TimeInterval) {
        runner.loadSeconds = seconds * 0.7
        runner.coolSeconds = seconds * 0.2
        runner.start()
    }

    override func blocks() -> [Block] {
        guard !runner.fans.isEmpty else { return [.secondary(L("This Mac has no fans."))] }
        var blocks: [Block] = [.rows(runner.fans.map { fan in
            DocRow(title: L("Fan %lld", fan.index + 1),
                   value: [fan.actual.map(Format.rpm), FanText.live(fan)].compactMap { $0 }.joined(separator: " · "))
        }, labelWidth: 90)]
        if let cpu = runner.cpuTemperature {
            blocks.append(.secondary(L("CPU %@", Format.temperature(cpu))))
        }
        if let progress = runner.progress {
            blocks.append(.progress(progress))
            blocks.append(.actions([DocAction(title: L("Stop")) { [unowned self] in runner.cancel() }]))
        } else {
            if runner.state == .finished {
                let verdict = runner.check.verdict
                let tone: Tone
                switch verdict {
                case .passed: tone = .good
                case .stalled, .belowTarget: tone = .bad
                case .notAsked: tone = .neutral
                }
                blocks.append(.status(FanText.verdict(verdict), tone, detail: FanText.detail(runner.check)))
            }
            blocks.append(.actions([DocAction(title: runner.state == .finished ? L("Test again") : L("Start fan test")) {
                [unowned self] in runner.start()
            }]))
        }
        return blocks
    }
}

/// Touch Bar: touch cells and solid colours on the bar (core `TouchBarTester`).
final class LegacyTouchBarPane: BlockPane {
    private let tester = TouchBarTester()

    override init(core: MonitorCore) {
        super.init(core: core)
        tester.onChange = { [weak self] in
            guard let self else { return }
            if tester.mode == .touch {
                core.recordCheck(.touchBar, detail: TouchBarText.progress(tester), passed: tester.allTouched)
            }
            refresh()
        }
    }

    override func deactivate() {
        tester.stop()
    }

    override func blocks() -> [Block] {
        var blocks: [Block] = [.view(TouchBarMirrorView(touched: tester.touched)), .secondary(TouchBarText.progress(tester))]
        if tester.mode != .off, !tester.fullWidth {
            blocks.append(.status(L("The Touch Bar could not be shown full width: keep this window in front."), .neutral))
        }
        var actions = [DocAction(title: L("Start touch test")) { [unowned self] in tester.startTouchTest() }]
        actions += TouchBarTester.colours.indices.map { index in
            DocAction(title: TouchBarText.colourName(index)) { [unowned self] in tester.showColour(index) }
        }
        if tester.mode != .off {
            actions.append(DocAction(title: L("Stop")) { [unowned self] in tester.stop() })
        }
        blocks.append(.actions(actions))
        return blocks
    }
}

/// The Touch Bar's cells in the window: green where it registered a touch.
final class TouchBarMirrorView: NSView {
    private let touched: Set<Int>

    init(touched: Set<Int>) {
        self.touched = touched
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        widthAnchor.constraint(equalToConstant: 560).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let count = TouchBarTester.cellCount
        let width = bounds.width / CGFloat(count)
        for index in 0..<count {
            let cell = NSRect(x: CGFloat(index) * width + 1, y: 2, width: width - 2, height: bounds.height - 4)
            (touched.contains(index) ? LegacyStyle.cool : NSColor.labelColor.withAlphaComponent(0.12)).setFill()
            NSBezierPath(roundedRect: cell, xRadius: 3, yRadius: 3).fill()
        }
    }
}
