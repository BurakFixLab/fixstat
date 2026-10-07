import AppKit
import FixStatCore
import MacSensors

/// Live monitor for the AppKit interface: a searchable channel list with check boxes on the
/// left, one chart per chosen channel on the right (drawn by hand: Swift Charts needs macOS 13).
final class LegacyLiveMonitor: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case header(String)
        case channel(LiveMonitor.Channel)
    }

    private let monitor: LiveMonitor
    private(set) var window: LegacyToolWindow!
    private var rows: [Row] = []
    private var chartIDs: [String] = []
    private var charts: [LiveChartView] = []

    private let search = NSSearchField()
    private let table = NSTableView()
    private let chartStack = NSStackView()
    private let rate = NSPopUpButton()
    private let recordButton = NSButton()
    private let saveButton = NSButton()
    private let status = makeLabel("", color: .secondaryLabelColor)
    private let placeholder = makeLabel(L("Pick up to six values on the left."), color: .secondaryLabelColor)

    init(core: MonitorCore) {
        monitor = LiveMonitor(monitor: core)
        super.init()
        window = LegacyToolWindow(title: L("Live monitor"), view: makeContent(), size: NSSize(width: 940, height: 680))
        window.onOpen = { [unowned self] in monitor.start() }
        window.onClose = { [unowned self] in monitor.stop() }
        monitor.onChange = { [unowned self] in update() }
    }

    // MARK: Layout

    private func makeContent() -> NSView {
        search.placeholderString = L("Search")
        search.target = self
        search.action = #selector(searchChanged)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("channel"))
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 2)
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true

        let left = vStack([search, tableScroll], spacing: 8)
        left.translatesAutoresizingMaskIntoConstraints = false
        left.widthAnchor.constraint(equalToConstant: 280).isActive = true
        tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        for (title, value) in [(L("4 per second"), 0.25), (L("2 per second"), 0.5), (L("1 per second"), 1.0)] {
            rate.addItem(withTitle: title)
            rate.lastItem?.representedObject = value
        }
        rate.selectItem(at: 1)
        rate.target = self
        rate.action = #selector(rateChanged)
        let mark = ActionButton(title: L("Mark")) { [unowned self] in monitor.addMarker() }
        mark.toolTip = L("Adds a numbered marker (M1, M2 …) to the charts and the CSV, e.g. when you plug in the charger.")
        saveButton.bezelStyle = .rounded
        saveButton.title = L("Save as CSV…")
        saveButton.toolTip = L("Saves the last ten minutes shown here.")
        saveButton.target = self
        saveButton.action = #selector(saveWindow)
        recordButton.bezelStyle = .rounded
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        let toolbar = hStack([makeLabel(L("Rate")), rate, mark, makeSpacer(), status, saveButton, recordButton])

        chartStack.orientation = .vertical
        chartStack.alignment = .leading
        chartStack.spacing = 8
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        chartStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(chartStack)
        let chartScroll = NSScrollView()
        chartScroll.drawsBackground = false
        chartScroll.hasVerticalScroller = true
        chartScroll.autohidesScrollers = true
        chartScroll.documentView = document
        NSLayoutConstraint.activate([
            chartStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            chartStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            chartStack.topAnchor.constraint(equalTo: document.topAnchor),
            chartStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: chartScroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: chartScroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: chartScroll.contentView.widthAnchor),
        ])
        let note = makeNote(L("Values as the SMC reports them, a few times a second: slow changes show, microsecond dips and ripple do not (that needs an oscilloscope)."),
                            width: 600)
        let right = vStack([toolbar, placeholder, chartScroll, note], spacing: 10)
        chartScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        let root = hStack([left, right], spacing: 16, alignment: .top)
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            left.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            right.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        return container
    }

    // MARK: Updates

    private func update() {
        if rows.isEmpty || rowCount() != rows.count { rebuildRows() }
        if chartIDs != monitor.selected { rebuildCharts() }
        for chart in charts {
            chart.samples = monitor.samples
            chart.markers = monitor.markers
        }
        if let started = monitor.recordingStarted {
            status.stringValue = L("Recording %@", Format.minutesSeconds(Date().timeIntervalSince(started)))
            recordButton.title = L("Stop and save…")
        } else {
            status.stringValue = ""
            recordButton.title = L("Record")
        }
        saveButton.isHidden = monitor.recordingStarted != nil
        saveButton.isEnabled = !monitor.samples.isEmpty
        placeholder.isHidden = !monitor.selected.isEmpty
    }

    /// Number of rows the current filter gives (headers included).
    private func rowCount() -> Int { makeRows().count }

    private func makeRows() -> [Row] {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        var rows: [Row] = []
        for group in LiveMonitor.Group.allCases {
            let channels = monitor.channels.filter { channel in
                channel.group == group && (query.isEmpty || channel.title.localizedCaseInsensitiveContains(query)
                    || (channel.detail?.localizedCaseInsensitiveContains(query) ?? false))
            }
            guard !channels.isEmpty else { continue }
            rows.append(.header(LiveMonitor.groupTitle(group)))
            rows += channels.map { .channel($0) }
        }
        return rows
    }

    private func rebuildRows() {
        rows = makeRows()
        table.reloadData()
    }

    private func rebuildCharts() {
        chartIDs = monitor.selected
        for view in chartStack.arrangedSubviews {
            chartStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        charts = monitor.selected.compactMap(monitor.channel).map { channel in
            let chart = LiveChartView(channel: channel)
            chart.translatesAutoresizingMaskIntoConstraints = false
            chart.heightAnchor.constraint(equalToConstant: 150).isActive = true
            return chart
        }
        for chart in charts {
            chartStack.addArrangedSubview(chart)
            chart.widthAnchor.constraint(equalTo: chartStack.widthAnchor).isActive = true
        }
        table.reloadData()
    }

    // MARK: Actions

    @objc private func searchChanged() { rebuildRows() }

    @objc private func rateChanged() {
        if let value = rate.selectedItem?.representedObject as? Double { monitor.setInterval(value) }
    }

    @objc private func toggleRecording() {
        if monitor.recordingStarted != nil {
            save(monitor.stopRecording(), name: "live-recording")
        } else {
            monitor.startRecording()
        }
    }

    @objc private func saveWindow() { save(monitor.windowCSV(), name: "live-window") }

    private func save(_ csv: String?, name: String) {
        guard let csv else { return }
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["csv"]
        panel.nameFieldStringValue = "fixstat-\(name)-\(Format.isoDay(Date())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .header(title):
            return makeLabel(title, size: LegacyStyle.caption, weight: .semibold, color: .secondaryLabelColor)
        case let .channel(channel):
            let isOn = monitor.selected.contains(channel.id)
            let box = ActionButton(title: channel.title) { [unowned self] in monitor.toggle(channel.id) }
            box.setButtonType(.switch)
            box.state = isOn ? .on : .off
            box.isEnabled = isOn || monitor.selected.count < LiveMonitor.maximumChannels
            box.lineBreakMode = .byTruncatingTail
            var views: [NSView] = [box, makeSpacer()]
            if let detail = channel.detail {
                let label = makeLabel(detail, size: 10, color: .tertiaryLabelColor)
                // monospacedSystemFont needs 10.15.
                label.font = NSFont(name: "Menlo", size: 10) ?? label.font
                views.append(label)
            }
            return hStack(views, spacing: 6)
        }
    }
}

/// One channel: title, current value, range and the line over the shown window.
final class LiveChartView: NSView {
    let channel: LiveMonitor.Channel
    var samples: [LiveMonitor.Sample] = [] { didSet { needsDisplay = true } }
    var markers: [Date] = []

    init(channel: LiveMonitor.Channel) {
        self.channel = channel
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()

        let points = samples.compactMap { sample in sample.values[channel.id].map { (sample.time, $0) } }
        let values = points.map(\.1)
        let small = NSFont.systemFont(ofSize: 10)
        let secondary: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: NSColor.secondaryLabelColor]
        func draw(_ text: String, _ attributes: [NSAttributedString.Key: Any], at point: NSPoint, right: Bool = false) {
            let string = NSAttributedString(string: text, attributes: attributes)
            let size = string.size()
            string.draw(at: NSPoint(x: right ? point.x - size.width : point.x, y: point.y))
        }
        draw(channel.title, [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor],
             at: NSPoint(x: 12, y: 8))
        let current = values.last.map { LiveMonitor.format($0, channel.unit) } ?? "–"
        draw(current, [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor],
             at: NSPoint(x: bounds.maxX - 12, y: 6), right: true)

        let plot = NSRect(x: 60, y: 34, width: bounds.width - 76, height: bounds.height - 56)
        guard let low = values.min(), let high = values.max(), let first = points.first?.0, let last = points.last?.0 else { return }
        let pad = high > low ? (high - low) * 0.1 : max(abs(high) * 0.02, 0.5)
        let y0 = low - pad, y1 = high + pad
        let span = max(last.timeIntervalSince(first), 1)
        func x(_ date: Date) -> CGFloat { plot.minX + CGFloat(date.timeIntervalSince(first) / span) * plot.width }
        func y(_ value: Double) -> CGFloat { plot.maxY - CGFloat((value - y0) / (y1 - y0)) * plot.height }

        NSColor.gridColor.setStroke()
        for value in [y0, y1] {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX, y: y(value)))
            path.line(to: NSPoint(x: plot.maxX, y: y(value)))
            path.lineWidth = 0.5
            path.stroke()
            draw(LiveMonitor.axisLabel(value, channel.unit), secondary, at: NSPoint(x: plot.minX - 6, y: y(value) - 7), right: true)
        }
        draw(Format.timeWithSeconds(first), secondary, at: NSPoint(x: plot.minX, y: plot.maxY + 4))
        draw(Format.timeWithSeconds(last), secondary, at: NSPoint(x: plot.maxX, y: plot.maxY + 4), right: true)

        for (index, marker) in markers.enumerated() where marker >= first {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x(marker), y: plot.minY))
            path.line(to: NSPoint(x: x(marker), y: plot.maxY))
            path.setLineDash([3, 3], count: 2, phase: 0)
            LegacyStyle.warm(in: self).setStroke()
            path.stroke()
            draw("M\(index + 1)", [.font: small, .foregroundColor: LegacyStyle.warm(in: self)],
                 at: NSPoint(x: x(marker) + 3, y: plot.minY - 2))
        }

        let line = NSBezierPath()
        for (index, point) in points.enumerated() {
            let p = NSPoint(x: x(point.0), y: y(point.1))
            if index == 0 { line.move(to: p) } else { line.line(to: p) }
        }
        line.lineWidth = 1.5
        LegacyStyle.accent.setStroke()
        line.stroke()
    }
}
