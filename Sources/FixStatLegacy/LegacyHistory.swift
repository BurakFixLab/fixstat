import AppKit
import MacSensors
import FixStatCore

/// Battery history window of the AppKit interface: charge, current and health charts drawn
/// by hand (Swift Charts needs macOS 13), with the same ranges, hover cards and export as
/// the SwiftUI `HistoryView`.
final class LegacyHistory {
    private let core: MonitorCore
    private var range = HistoryRange.day
    private var samples: [BatteryHistorySample] = []
    private var health: [BatteryHealthRecord] = []
    private(set) var window: LegacyToolWindow!

    private let rangeControl: NSSegmentedControl
    private let exportButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let chargeChart = ChargeChartView()
    private let currentChart = CurrentChartView()
    private let healthChart = HealthChartView()

    init(core: MonitorCore, initialRange: HistoryRange = .day) {
        self.core = core
        range = initialRange
        rangeControl = NSSegmentedControl(labels: HistoryRange.allCases.map(\.title), trackingMode: .selectOne,
                                          target: nil, action: nil)
        rangeControl.selectedSegment = range.rawValue
        rangeControl.target = self
        rangeControl.action = #selector(rangeChanged)

        exportButton.addItem(withTitle: L("Export history"))
        exportButton.menu?.addItem(LegacyMenuItem(title: L("CSV…")) { [unowned self] in export(csv: true) })
        exportButton.menu?.addItem(LegacyMenuItem(title: L("JSON…")) { [unowned self] in export(csv: false) })

        // The charge and current charts share the time under the pointer.
        for chart in [chargeChart, currentChart] as [TimeChartView] {
            chart.onHover = { [unowned self] date in
                chargeChart.hoverDate = date
                currentChart.hoverDate = date
            }
        }
        healthChart.onHover = { [unowned self] date in healthChart.hoverDate = date }

        window = LegacyToolWindow(title: L("Battery history"), contentWidth: 640, height: 700) { [unowned self] in blocks() }
        // Reload when the range changes and every minute (new samples).
        window.onOpen = { [unowned self] in window.refresh(every: MonitorCore.historyInterval) }
        window.onReload = { [unowned self] in load() }
    }

    @objc private func rangeChanged() {
        range = HistoryRange(rawValue: rangeControl.selectedSegment) ?? .day
        window.reload()
    }

    private func load() {
        samples = HistoryData.samples(core.history, range: range)
        health = core.history.healthRecords()
        let now = Date()
        let domain = now.addingTimeInterval(-range.duration)...now
        for chart in [chargeChart, currentChart] as [TimeChartView] {
            chart.range = range
            chart.xDomain = domain
            chart.samples = samples
        }
        healthChart.records = health
    }

    private func blocks() -> [Block] {
        var blocks: [Block] = [.view(hStack([rangeControl, makeSpacer(), exportButton]))]
        if samples.isEmpty {
            blocks.append(.headline(L("No battery history yet"), nil))
            blocks.append(.secondary(L("FixStat records the battery once a minute while it is running. Samples are kept for 30 days, daily health values indefinitely.")))
        } else {
            let summary = HistoryData.summary(samples)
            blocks.append(.tiles([
                (L("Average charge current"), summary.charge.map { Format.milliamps(Int($0)) } ?? "–"),
                (L("Average discharge current"), summary.discharge.map { Format.milliamps(Int($0)) } ?? "–"),
                (L("Highest temperature"), summary.temperature.map { Format.temperature($0) } ?? "–"),
            ], columns: 3))
            blocks.append(.section(L("Charge")))
            blocks.append(.view(sized(chargeChart, height: 150)))
            blocks.append(.view(hStack([makeSectionTitle(L("Current")), makeSpacer(),
                                        legend(LegacyStyle.cool, L("Charging")), legend(LegacyStyle.hot, L("Discharging"))])))
            blocks.append(.view(sized(currentChart, height: 130)))
        }
        var healthHeader: [NSView] = [makeSectionTitle(L("Health")), makeSpacer()]
        if let first = health.first?.date {
            healthHeader.append(makeLabel(L("Since %@", Format.date(first)), size: LegacyStyle.caption, color: .secondaryLabelColor))
        }
        blocks.append(.view(hStack(healthHeader)))
        if health.contains(where: { $0.date != nil }) {
            blocks.append(.view(sized(healthChart, height: 110)))
        } else {
            blocks.append(.secondary(L("No health values recorded yet.")))
        }
        return blocks
    }

    private func sized(_ view: NSView, height: CGFloat) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        if view.constraints.first(where: { $0.firstAttribute == .height }) == nil {
            view.heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        return view
    }

    private func legend(_ color: NSColor, _ title: String) -> NSView {
        let dot = DotView(size: 6)
        dot.color = color
        return hStack([dot, makeLabel(title, size: LegacyStyle.caption, color: .secondaryLabelColor)], spacing: 4)
    }

    private func export(csv: Bool) {
        let samples = core.history.samples(since: Date().addingTimeInterval(-range.duration))
        guard let data = csv ? HistoryData.csv(samples)
                : HistoryData.json(model: core.system.model, samples: samples, health: core.history.healthRecords())
        else { return }
        LegacySave.run(data, name: HistoryData.fileName(model: core.system.model, csv: csv), fileExtension: csv ? "csv" : "json")
    }
}

/// Save panel for exported files.
enum LegacySave {
    static func run(_ data: Data, name: String, fileExtension: String) {
        let panel = NSSavePanel()
        panel.allowedFileTypes = [fileExtension]
        panel.nameFieldStringValue = name
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

// MARK: - Charts

/// A chart with a date x axis, a numeric y axis, grid lines, labels and a hover rule.
class TimeChartView: NSView {
    var xDomain: ClosedRange<Date> = Date()...Date() { didSet { needsDisplay = true } }
    var range = HistoryRange.day
    var samples: [BatteryHistorySample] = [] { didSet { needsDisplay = true } }
    var hoverDate: Date? { didSet { if hoverDate != oldValue { needsDisplay = true } } }
    var onHover: ((Date?) -> Void)?

    private var trackingArea: NSTrackingArea?
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    override var isFlipped: Bool { true }

    /// Plot area inside the axis labels.
    var plot: NSRect {
        NSRect(x: bounds.minX + 58, y: bounds.minY + 6, width: bounds.width - 66, height: bounds.height - 24)
    }

    // Subclass hooks
    var yDomain: ClosedRange<Double> { 0...1 }
    var yTicks: [Double] { [] }
    func yLabel(_ value: Double) -> String { "" }
    var xTicks: [Date] { Self.ticks(in: xDomain, step: range.tick) }
    func xLabel(_ date: Date) -> String { range.tick >= 86_400 ? Format.dayMonth(date) : Format.time(date) }
    func drawContent() {}
    /// Card lines for the hover position (first line bold), nil for no card.
    func card(at date: Date) -> [String]? { nil }
    /// Snap the hover rule to this date (nearest sample).
    func snap(_ date: Date) -> Date? { nearestSample(date)?.time }

    func x(_ date: Date) -> CGFloat {
        let span = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound)
        guard span > 0 else { return plot.minX }
        return plot.minX + plot.width * CGFloat(date.timeIntervalSince(xDomain.lowerBound) / span)
    }

    func y(_ value: Double) -> CGFloat {
        let span = yDomain.upperBound - yDomain.lowerBound
        guard span > 0 else { return plot.maxY }
        return plot.maxY - plot.height * CGFloat((value - yDomain.lowerBound) / span)
    }

    func nearestSample(_ date: Date) -> BatteryHistorySample? {
        samples.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let grid = NSColor.labelColor.withAlphaComponent(0.1)
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: NSColor.secondaryLabelColor]
        for tick in yTicks {
            let ty = y(tick)
            grid.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: ty))
            line.line(to: NSPoint(x: plot.maxX, y: ty))
            line.lineWidth = 0.5
            line.stroke()
            let text = yLabel(tick) as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: plot.minX - size.width - 6, y: ty - size.height / 2), withAttributes: attributes)
        }
        for tick in xTicks {
            let tx = x(tick)
            guard tx >= plot.minX - 1, tx <= plot.maxX + 1 else { continue }
            grid.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: tx, y: plot.minY))
            line.line(to: NSPoint(x: tx, y: plot.maxY))
            line.lineWidth = 0.5
            line.stroke()
            let text = xLabel(tick) as NSString
            let size = text.size(withAttributes: attributes)
            let lx = min(max(tx - size.width / 2, plot.minX - 20), bounds.maxX - size.width)
            text.draw(at: NSPoint(x: lx, y: plot.maxY + 4), withAttributes: attributes)
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot.insetBy(dx: -3, dy: -3)).addClip()
        drawContent()
        NSGraphicsContext.restoreGraphicsState()
        if let hover = hoverDate {
            let hx = x(hover)
            NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
            let rule = NSBezierPath()
            rule.move(to: NSPoint(x: hx, y: plot.minY))
            rule.line(to: NSPoint(x: hx, y: plot.maxY))
            rule.lineWidth = 1
            rule.stroke()
            if let lines = card(at: hover) { drawCard(lines, at: hx) }
        }
    }

    private func drawCard(_ lines: [String], at hx: CGFloat) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let bold = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let texts = lines.enumerated().map { index, line in
            NSAttributedString(string: line, attributes: [.font: index == 0 ? bold : font, .foregroundColor: NSColor.labelColor])
        }
        let width = (texts.map { $0.size().width }.max() ?? 0) + 16
        let lineHeight: CGFloat = 13
        let height = CGFloat(texts.count) * lineHeight + 10
        var cx = hx + 8
        if cx + width > plot.maxX { cx = hx - 8 - width }
        let rect = NSRect(x: max(plot.minX, cx), y: plot.minY + 2, width: width, height: height)
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.15).setStroke()
        path.lineWidth = 1
        path.stroke()
        for (index, text) in texts.enumerated() {
            text.draw(at: NSPoint(x: rect.minX + 8, y: rect.minY + 5 + CGFloat(index) * lineHeight))
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard plot.width > 0 else { return }
        let fraction = Double(min(max((point.x - plot.minX) / plot.width, 0), 1))
        let span = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound)
        onHover?(snap(xDomain.lowerBound.addingTimeInterval(span * fraction)))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    // MARK: Scales

    /// Ticks every `step` seconds, aligned to local midnight.
    static func ticks(in domain: ClosedRange<Date>, step: TimeInterval) -> [Date] {
        guard step > 0 else { return [] }
        var tick = Calendar.current.startOfDay(for: domain.lowerBound)
        var ticks: [Date] = []
        while tick <= domain.upperBound {
            if tick >= domain.lowerBound { ticks.append(tick) }
            tick = tick.addingTimeInterval(step)
        }
        return ticks
    }

    /// About four round values (1, 2, 5 × 10ⁿ steps) covering the domain.
    static func niceTicks(_ domain: ClosedRange<Double>) -> [Double] {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return [domain.lowerBound] }
        let raw = span / 4
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1.0, 2, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? raw
        var value = (domain.lowerBound / step).rounded(.up) * step
        var ticks: [Double] = []
        while value <= domain.upperBound + step * 0.001 {
            ticks.append(value)
            value += step
        }
        return ticks
    }
}

final class ChargeChartView: TimeChartView {
    override var yDomain: ClosedRange<Double> { 0...100 }
    override var yTicks: [Double] { [0, 25, 50, 75, 100] }
    override func yLabel(_ value: Double) -> String { Format.percent(value) }

    override func drawContent() {
        guard let first = samples.first else { return }
        let accent = LegacyStyle.accent
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x(first.time), y: y(first.stateOfCharge)))
        for sample in samples.dropFirst() {
            line.line(to: NSPoint(x: x(sample.time), y: y(sample.stateOfCharge)))
        }
        if let last = samples.last {
            let area = line.copy() as! NSBezierPath
            area.line(to: NSPoint(x: x(last.time), y: y(0)))
            area.line(to: NSPoint(x: x(first.time), y: y(0)))
            area.close()
            accent.withAlphaComponent(0.15).setFill()
            area.fill()
        }
        accent.setStroke()
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        line.stroke()
        // A line needs two points; show the samples themselves while there are few.
        if samples.count < 30 {
            accent.setFill()
            for sample in samples {
                NSBezierPath(ovalIn: NSRect(x: x(sample.time) - 2.5, y: y(sample.stateOfCharge) - 2.5, width: 5, height: 5)).fill()
            }
        }
        if let hover = hoverDate, let sample = nearestSample(hover) {
            accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: x(sample.time) - 4, y: y(sample.stateOfCharge) - 4, width: 8, height: 8)).fill()
        }
    }

    override func card(at date: Date) -> [String]? {
        guard let sample = nearestSample(date) else { return nil }
        var lines = [range.showsDate ? Format.dayMonthTime(sample.time) : Format.time(sample.time),
                     L("Charge") + "  " + Format.percent(sample.stateOfCharge),
                     L("Current") + "  " + Format.milliamps(sample.amperage)]
        if let temperature = sample.temperature {
            lines.append(L("Temperature") + "  " + Format.temperature(temperature))
        }
        lines.append(HistoryData.state(sample))
        return lines
    }
}

final class CurrentChartView: TimeChartView {
    override var yDomain: ClosedRange<Double> {
        let values = samples.map { Double($0.amperage) }
        let low = min(0, values.min() ?? 0), high = max(0, values.max() ?? 0)
        let pad = max((high - low) * 0.1, 100)
        return (low < 0 ? low - pad : 0)...(high > 0 ? high + pad : pad)
    }

    override var yTicks: [Double] { Self.niceTicks(yDomain) }
    override func yLabel(_ value: Double) -> String { Format.milliamps(Int(value)) }

    override func drawContent() {
        let width = max(1, plot.width * CGFloat(range.bucket / range.duration))
        for sample in samples {
            (sample.amperage >= 0 ? LegacyStyle.cool : LegacyStyle.hot).setFill()
            let top = y(Double(max(sample.amperage, 0)))
            let bottom = y(Double(min(sample.amperage, 0)))
            NSBezierPath(rect: NSRect(x: x(sample.time) - width / 2, y: top, width: width, height: max(bottom - top, 0.5))).fill()
        }
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke()
        let zero = NSBezierPath()
        zero.move(to: NSPoint(x: plot.minX, y: y(0)))
        zero.line(to: NSPoint(x: plot.maxX, y: y(0)))
        zero.stroke()
    }
}

final class HealthChartView: TimeChartView {
    var records: [BatteryHealthRecord] = [] {
        didSet {
            points = records.compactMap { record in record.date.map { ($0, record) } }
            xDomain = HistoryData.healthDomain(points.map(\.0))
            needsDisplay = true
        }
    }

    private var points: [(Date, BatteryHealthRecord)] = []

    override var yDomain: ClosedRange<Double> { HistoryData.healthFloor(points.map(\.1.health))...100 }
    override var yTicks: [Double] { Self.niceTicks(yDomain) }
    override func yLabel(_ value: Double) -> String { Format.percent(value) }

    override var xTicks: [Date] {
        let days = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound) / 86_400
        return Self.ticks(in: xDomain, step: max(1, (days / 6).rounded(.up)) * 86_400)
    }

    override func xLabel(_ date: Date) -> String { Format.dayMonth(date) }

    override func drawContent() {
        guard let first = points.first else { return }
        let accent = LegacyStyle.accent
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x(first.0), y: y(first.1.health)))
        for point in points.dropFirst() {
            line.line(to: NSPoint(x: x(point.0), y: y(point.1.health)))
        }
        accent.setStroke()
        line.lineWidth = 1.5
        line.stroke()
        accent.setFill()
        for point in points {
            NSBezierPath(ovalIn: NSRect(x: x(point.0) - 2.5, y: y(point.1.health) - 2.5, width: 5, height: 5)).fill()
        }
    }

    private func nearest(_ date: Date) -> (Date, BatteryHealthRecord)? {
        points.min { abs($0.0.timeIntervalSince(date)) < abs($1.0.timeIntervalSince(date)) }
    }

    override func snap(_ date: Date) -> Date? { nearest(date)?.0 }

    override func card(at date: Date) -> [String]? {
        guard let (day, record) = nearest(date) else { return nil }
        var lines = [Format.date(day), L("Health") + "  " + Format.percent(record.health, digits: 1)]
        if let cycles = record.cycleCount {
            lines.append(L("Cycles") + "  " + Format.number(Double(cycles)))
        }
        return lines
    }
}
