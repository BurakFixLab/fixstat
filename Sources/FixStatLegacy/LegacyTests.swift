import AppKit
import MacSensors
import FixStatCore

// Test windows of the AppKit interface. The runners live in the core and are shared
// with the SwiftUI windows; these classes only build the content.

/// A test window that snapshots can start without clicking (`--start-test SECONDS`).
protocol LegacySnapshotStartable: AnyObject {
    func start(seconds: TimeInterval)
}

// MARK: - Post-repair test

final class LegacyStressTest: LegacySnapshotStartable {
    private let core: MonitorCore
    private let runner: StressTestRunner
    private(set) var window: LegacyToolWindow!

    private let durations: [Double] = [2, 5, 10]
    private let durationControl: NSSegmentedControl
    private let cpuBox = NSButton(checkboxWithTitle: L("CPU"), target: nil, action: nil)
    private let gpuBox = NSButton(checkboxWithTitle: L("GPU"), target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let chart = StressChartView()

    init(core: MonitorCore) {
        self.core = core
        runner = StressTestRunner(monitor: core)
        durationControl = NSSegmentedControl(labels: durations.map { Format.minutes(Int($0)) }, trackingMode: .selectOne,
                                             target: nil, action: nil)
        durationControl.selectedSegment = 1
        cpuBox.state = .on
        gpuBox.state = .on
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        window = LegacyToolWindow(title: L("Post-repair test"), contentWidth: 600, height: 640) { [unowned self] in blocks() }
        runner.onChange = { [weak self] in self?.window.reload() }
    }

    /// Snapshots: a short test without clicking.
    func start(seconds: TimeInterval) {
        runner.start(duration: seconds, cpu: true, gpu: true)
    }

    private func blocks() -> [Block] {
        let running = runner.state == .running
        for control in [durationControl, cpuBox, gpuBox] as [NSControl] { control.isEnabled = !running }
        let action: NSView = running
            ? ActionButton(title: L("Stop")) { [unowned self] in runner.stop() }
            : ActionButton(title: L("Start test")) { [unowned self] in
                let minutes = durations[max(0, durationControl.selectedSegment)]
                runner.start(duration: minutes * 60, cpu: cpuBox.state == .on, gpu: gpuBox.state == .on)
            }
        var blocks: [Block] = [
            .secondary(L("Loads the CPU and GPU for a few minutes and checks temperatures, cell voltages and power delivery. Run it after a repair with the case closed, on a desk.")),
            .view(hStack([durationControl, cpuBox, gpuBox, makeSpacer(), action], spacing: 14)),
        ]
        if runner.state != .idle {
            let last = runner.samples.last
            if running {
                progress.doubleValue = min(runner.elapsed / runner.duration, 1)
                blocks.append(.view(progress))
                blocks.append(.caption(L("%@ remaining", Format.minutesSeconds(max(runner.duration - runner.elapsed, 0)))))
            }
            blocks.append(.tiles([
                (L("CPU"), last?.cpu.map { Format.temperature($0) } ?? "–"),
                (L("GPU"), last?.gpu.map { Format.temperature($0) } ?? "–"),
                (L("Battery"), last?.battery.map { Format.temperature($0) } ?? "–"),
                (L("Current"), last?.amperage.map { Format.milliamps($0) } ?? "–"),
            ], columns: 4))
            blocks.append(.view(hStack([makeSectionTitle(L("Temperature")), makeSpacer(),
                                        legend(LegacyStyle.hot, L("CPU")), legend(LegacyStyle.cool, L("GPU"))])))
            chart.update(samples: runner.samples, duration: runner.duration)
            if chart.constraints.first(where: { $0.firstAttribute == .height }) == nil {
                chart.translatesAutoresizingMaskIntoConstraints = false
                chart.heightAnchor.constraint(equalToConstant: 160).isActive = true
            }
            blocks.append(.view(chart))
        }
        if let result = runner.result {
            blocks.append(Self.result(result))
        }
        return blocks
    }

    private func legend(_ color: NSColor, _ title: String) -> NSView {
        let dot = DotView(size: 6)
        dot.color = color
        return hStack([dot, makeLabel(title, size: LegacyStyle.caption, color: .secondaryLabelColor)], spacing: 4)
    }

    /// Summary and findings after a test.
    static func result(_ result: StressTestResult) -> Block {
        let problems = result.findings.filter { $0 != .stoppedEarly }
        var blocks: [Block] = [problems.isEmpty
            ? .headline(L("No problems found"), .good)
            : .headline(L("Needs attention"), .bad)]
        blocks.append(.list(result.findings.map { .text("• " + TestText.finding($0)) }))
        blocks.append(.rows(TestText.summaryRows(result).map { DocRow(title: $0.0, value: $0.1) }, labelWidth: 240))
        return .group(nil, blocks)
    }
}

/// CPU / GPU temperature over the test time, with the hot threshold as a dashed line.
final class StressChartView: TimeChartView {
    private let origin = Date(timeIntervalSinceReferenceDate: 0)
    private var points: [StressSample] = []
    private var testDuration: TimeInterval = 300

    func update(samples: [StressSample], duration: TimeInterval) {
        points = samples
        testDuration = max(duration, 1)
        xDomain = origin...origin.addingTimeInterval(testDuration)
        needsDisplay = true
    }

    private var hot: Double {
        let value = UserDefaults.standard.double(forKey: Pref.hotThreshold)
        return value > 0 ? value : Pref.defaultHot
    }

    override var yDomain: ClosedRange<Double> {
        let values = points.flatMap { [$0.cpu, $0.gpu].compactMap { $0 } } + [hot]
        let low = ((values.min() ?? 30) - 5).rounded(.down), high = ((values.max() ?? 60) + 5).rounded(.up)
        return low...max(high, low + 10)
    }

    override var yTicks: [Double] { Self.niceTicks(yDomain) }
    override func yLabel(_ value: Double) -> String { Format.degrees(value) }

    override var xTicks: [Date] {
        let step: TimeInterval = testDuration > 360 ? 120 : 60
        return stride(from: 0, through: testDuration, by: step).map { origin.addingTimeInterval($0) }
    }

    override func xLabel(_ date: Date) -> String { Format.minutesSeconds(date.timeIntervalSince(origin)) }
    override func snap(_ date: Date) -> Date? { nil }

    override func drawContent() {
        drawLine(points.compactMap { sample in sample.cpu.map { (sample.time, $0) } }, color: LegacyStyle.hot)
        drawLine(points.compactMap { sample in sample.gpu.map { (sample.time, $0) } }, color: LegacyStyle.cool)
        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: plot.minX, y: y(hot)))
        rule.line(to: NSPoint(x: plot.maxX, y: y(hot)))
        rule.setLineDash([4, 3], count: 2, phase: 0)
        LegacyStyle.warm(in: self).withAlphaComponent(0.6).setStroke()
        rule.stroke()
    }

    private func drawLine(_ values: [(Double, Double)], color: NSColor) {
        guard let first = values.first else { return }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x(origin.addingTimeInterval(first.0)), y: y(first.1)))
        for value in values.dropFirst() {
            path.line(to: NSPoint(x: x(origin.addingTimeInterval(value.0)), y: y(value.1)))
        }
        color.setStroke()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        path.stroke()
    }
}

// MARK: - Memory test

final class LegacyMemoryTest: LegacySnapshotStartable {
    private let runner: MemoryRunner
    private var info: MemoryInfo?
    private var testable: UInt64 = 0
    private(set) var window: LegacyToolWindow!

    private let sizes: [Double] = [0.5, 1, 2, 4]
    private let roundCounts = [1, 3, 10]
    private let sizeControl: NSSegmentedControl
    private let roundControl: NSSegmentedControl
    private let progress = NSProgressIndicator()

    init(core: MonitorCore) {
        runner = MemoryRunner(monitor: core)
        sizeControl = NSSegmentedControl(labels: sizes.map { Format.bytes($0 * 1_000_000_000) }, trackingMode: .selectOne,
                                         target: nil, action: nil)
        sizeControl.selectedSegment = 1
        roundControl = NSSegmentedControl(labels: roundCounts.map { L("%lld×", $0) }, trackingMode: .selectOne,
                                          target: nil, action: nil)
        roundControl.selectedSegment = 1
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        window = LegacyToolWindow(title: L("Memory test"), contentWidth: 600, height: 480) { [unowned self] in blocks() }
        window.onOpen = { [unowned self] in
            background({ (MemoryInfo.read(), MemoryInfo.testableBytes()) }, done: { [weak self] values in
                self?.info = values.0
                self?.testable = values.1
                self?.window.reload()
            })
        }
        runner.onChange = { [weak self] in
            guard let self else { return }
            if runner.state == .finished { testable = MemoryInfo.testableBytes() }
            window.reload()
        }
    }

    private func blocks() -> [Block] {
        let running = runner.state == .running
        var blocks: [Block] = []
        if let info {
            blocks.append(.headline([Format.memory(info.totalBytes), info.type, info.manufacturer]
                .compactMap { $0 }.joined(separator: " · "), nil))
            blocks.append(.secondary([info.swapUsedBytes.map { L("Swap used: %@", Format.bytes(Double($0))) },
                                      info.compressedBytes.map { L("Compressed: %@", Format.bytes(Double($0))) }]
                .compactMap { $0 }.joined(separator: " · ")))
        } else {
            blocks.append(.progress(""))
        }
        sizeControl.isEnabled = !running
        roundControl.isEnabled = !running
        let action: NSView
        if running {
            action = ActionButton(title: L("Stop")) { [unowned self] in runner.stop() }
        } else {
            let start = ActionButton(title: L("Start test")) { [unowned self] in
                let gigabytes = sizes[max(0, sizeControl.selectedSegment)]
                let rounds = roundCounts[max(0, roundControl.selectedSegment)]
                runner.start(bytes: min(UInt64(gigabytes * 1_000_000_000), testable), rounds: rounds)
            }
            start.isEnabled = testable >= 100_000_000
            action = start
        }
        blocks += [
            .section(L("Memory test")),
            .secondary(L("Writes several bit patterns into free memory and reads them back. Finds clear memory faults; it cannot reach memory used by macOS itself, so it does not replace a full diagnostic that runs outside macOS.")),
            .view(hStack([sizeControl, roundControl,
                          fixed(makeLabel(L("%@ usable", Format.bytes(Double(testable))), size: LegacyStyle.caption,
                                          color: .secondaryLabelColor)),
                          makeSpacer(), action], spacing: 12)),
        ]
        if running {
            progress.doubleValue = runner.fraction
            blocks.append(.view(progress))
            blocks.append(.caption(runner.pattern.map { MemoryText.pattern($0) } ?? ""))
        }
        if let result = runner.result {
            blocks.append(Self.result(result))
        }
        return blocks
    }

    /// Snapshots: 200 MB, one round.
    func start(seconds: TimeInterval) {
        runner.start(bytes: 200_000_000, rounds: 1)
    }

    static func result(_ result: MemoryTest.Result) -> Block {
        let headline: Block
        if result.allocationFailed {
            headline = .status(L("Could not reserve memory for the test."), .bad)
        } else if result.passed {
            headline = .headline(L("No memory errors found"), .good)
        } else {
            headline = .headline(L("Memory errors found"), .bad)
        }
        return .group(nil, [headline,
                            .rows(MemoryText.rows(result).map { DocRow(title: $0.0, value: $0.1) }, labelWidth: 200)])
    }
}
