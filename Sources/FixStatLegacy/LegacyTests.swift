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

// MARK: - SSD

final class LegacySSD: LegacySnapshotStartable {
    private let runner: SSDRunner
    private let fullRunner: FullSSDRunner
    private var info: SSDInfo?
    private(set) var window: LegacyToolWindow!

    private let sizes: [Double] = [2, 8, 16, 32]
    private let sizeControl: NSSegmentedControl
    private let progress = NSProgressIndicator()
    private let fullProgress = NSProgressIndicator()
    private let speedChart = NumericChartView()
    private let surfaceChart = NumericChartView()

    init(core: MonitorCore) {
        runner = SSDRunner(monitor: core)
        fullRunner = FullSSDRunner(monitor: core)
        sizeControl = NSSegmentedControl(labels: sizes.map { Format.bytes($0 * 1_000_000_000) }, trackingMode: .selectOne,
                                         target: nil, action: nil)
        sizeControl.selectedSegment = 1
        for bar in [progress, fullProgress] {
            bar.style = .bar
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
        }
        for chart in [speedChart, surfaceChart] {
            chart.translatesAutoresizingMaskIntoConstraints = false
        }
        speedChart.heightAnchor.constraint(equalToConstant: 150).isActive = true
        surfaceChart.heightAnchor.constraint(equalToConstant: 130).isActive = true
        window = LegacyToolWindow(title: L("SSD"), contentWidth: 620, height: 700) { [unowned self] in blocks() }
        window.onOpen = { [unowned self] in info = SSDInfo.read() }
        runner.onChange = { [weak self] in
            guard let self else { return }
            if runner.state == .finished { info = SSDInfo.read() }
            window.reload()
        }
        fullRunner.onChange = { [weak self] in self?.window.reload() }
        fullRunner.bringToFront = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window.window?.makeKeyAndOrderFront(nil)
        }
    }

    private var gigabytes: Double { sizes[max(0, sizeControl.selectedSegment)] }

    /// Snapshots: a 0.5 GB write–verify run.
    func start(seconds: TimeInterval) {
        runner.start(gigabytes: 0.5)
    }

    private func blocks() -> [Block] {
        var blocks: [Block] = []
        if let info {
            blocks.append(.headline(info.model ?? "SSD", nil))
            blocks.append(.secondary([info.capacity.map { Format.bytes($0) },
                                      [info.nandVendor, info.nandType].compactMap { $0 }.joined(separator: " "),
                                      info.bitsPerCell.map { L("%lld bits per cell", $0) },
                                      info.firmware.map { "FW \($0)" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")))
            if let health = info.health {
                blocks.append(healthGroup(health))
            } else {
                blocks.append(.secondary(L("SMART data is not available for this SSD.")))
            }
        } else {
            blocks.append(.secondary(L("No internal NVMe SSD found.")))
        }
        blocks += quickTest()
        blocks.append(.gap)
        blocks += fullTest()
        return blocks
    }

    private func healthGroup(_ health: NVMeHealth) -> Block {
        let findings = SSDText.healthFindings(health)
        var blocks: [Block] = findings.isEmpty
            ? [.headline(L("SSD health is good."), .good)]
            : [.list(findings.map { .status($0, .bad) })]
        blocks.append(.rows(SSDText.healthRows(health).map { DocRow(title: $0.0, value: $0.1) }, labelWidth: 200))
        return .group(L("Health (SMART)"), blocks)
    }

    // MARK: Write–verify

    private func quickTest() -> [Block] {
        let running = runner.state == .running
        let available = Double(SSDRunner.availableBytes)
        sizeControl.isEnabled = !running
        let action: NSView
        if running {
            action = ActionButton(title: L("Stop")) { [unowned self] in runner.stop() }
        } else {
            let start = ActionButton(title: L("Start test")) { [unowned self] in runner.start(gigabytes: gigabytes) }
            start.isEnabled = available >= 1_000_000_000 && !fullRunner.isRunning
            action = start
        }
        var blocks: [Block] = [
            .section(L("Write–verify stress test")),
            .secondary(L("Writes a test file to free space, reads it back and compares every byte. Finds data corruption, I/O errors and stalling areas that point to failing NAND. Only free space can be tested, and the test uses some of the SSD's write endurance.")),
            .view(hStack([sizeControl,
                          fixed(makeLabel(L("%@ usable", Format.bytes(available)), size: LegacyStyle.caption,
                                          color: .secondaryLabelColor)),
                          makeSpacer(), action], spacing: 12)),
        ]
        if running {
            progress.doubleValue = runner.fraction
            blocks.append(.view(progress))
            blocks.append(.caption(runner.phase == .write ? L("Writing…") : L("Reading and verifying…")))
        }
        if !runner.writeSpeeds.isEmpty {
            blocks.append(.view(hStack([makeLabel(L("Speed per 8 MB block"), size: LegacyStyle.caption, color: .secondaryLabelColor),
                                        makeSpacer(), legend(LegacyStyle.hot, L("Write")), legend(LegacyStyle.cool, L("Read"))])))
            let writes = SSDRunner.movingAverage(runner.writeSpeeds, window: 8)
            let count = Double(max(writes.count, runner.readSpeeds.count, 1))
            speedChart.update(series: [
                .init(points: writes.enumerated().map { (Double($0.offset), $0.element) }, color: LegacyStyle.hot, style: .line),
                .init(points: runner.readSpeeds.enumerated().map { (Double($0.offset), $0.element) }, color: LegacyStyle.cool, style: .line),
            ], x: 0...count, xLabel: { Format.number($0) }, yLabel: { Format.speed(megabytesPerSecond: $0) })
            blocks.append(.view(speedChart))
        }
        if let result = runner.result {
            blocks.append(Self.result(result))
        }
        return blocks
    }

    static func result(_ result: SSDStressTest.Result) -> Block {
        let problems = result.findings.filter { $0 != .stoppedEarly }
        return .group(nil, [
            problems.isEmpty ? .headline(L("No problems found"), .good) : .headline(L("Needs attention"), .bad),
            .list(result.findings.map { .text("• " + SSDText.finding($0)) }),
            .rows(SSDText.resultRows(result).map { DocRow(title: $0.0, value: $0.1) }, labelWidth: 200),
        ])
    }

    // MARK: Full test

    private func fullTest() -> [Block] {
        let action: NSView
        if fullRunner.isRunning {
            action = ActionButton(title: L("Stop")) { [unowned self] in fullRunner.stop() }
        } else {
            let start = ActionButton(title: L("Start full test")) { [unowned self] in startFullTest() }
            start.isEnabled = runner.state != .running
            action = start
        }
        var blocks: [Block] = [
            .section(L("Full test (administrator permission required)")),
            .secondary(L("Reads the entire SSD — including used space and the system partitions — and maps unreadable and slow areas, then runs the write–verify test on free space. The scan only reads. macOS asks for an administrator password; FixStat never sees or stores it.")),
            .caption(L("Also needs Full Disk Access: if the scan does not start, allow FixStat in System Settings › Privacy & Security › Full Disk Access.")),
            .view(hStack([action, makeSpacer()])),
        ]
        switch fullRunner.state {
        case .failed(let message):
            blocks.append(.status(message, .bad))
        case .scanning:
            fullProgress.doubleValue = fullRunner.surface?.fraction ?? 0
            blocks.append(.view(fullProgress))
            blocks.append(.caption(L("Reading the whole SSD… %@ / %@", Format.bytes(Double(fullRunner.surface?.bytesRead ?? 0)),
                                     Format.bytes(Double(fullRunner.surface?.deviceSize ?? 0)))))
        case .writeVerify:
            fullProgress.doubleValue = fullRunner.writeFraction
            blocks.append(.view(fullProgress))
            blocks.append(.caption(L("Write–verify on free space…")))
        default:
            break
        }
        if let surface = fullRunner.surface, !surface.regions.isEmpty {
            blocks.append(.caption(L("Read speed across the disk")))
            surfaceChart.update(
                series: [.init(points: surface.regions.map { (Double($0.offset) / 1e9, $0.speed) }, color: LegacyStyle.cool, style: .bars)],
                rules: surface.badRanges.map { (Double($0.offset) / 1e9, LegacyStyle.hot) },
                x: 0...max(Double(surface.deviceSize) / 1e9, 1),
                xLabel: { Format.bytes($0 * 1e9) }, yLabel: { Format.speed(megabytesPerSecond: $0) })
            blocks.append(.view(surfaceChart))
        }
        if let result = fullRunner.result {
            let findings = FullSSDText.findings(result)
            var inner: [Block] = [findings.isEmpty ? .headline(L("No problems found"), .good) : .headline(L("Needs attention"), .bad)]
            inner.append(.list(findings.map { .text("• " + $0) }))
            inner.append(.rows(FullSSDText.rows(result).map { DocRow(title: $0.0, value: $0.1) }, labelWidth: 220))
            blocks.append(.group(nil, inner))
        }
        return blocks
    }

    private func startFullTest() {
        guard FullSSDRunner.hasFullDiskAccess else {
            let alert = NSAlert()
            alert.messageText = L("FixStat needs Full Disk Access")
            alert.informativeText = L("To read the whole SSD, turn on FixStat in Privacy & Security › Full Disk Access, then quit and reopen FixStat and start the test again.")
            alert.addButton(withTitle: L("Open System Settings"))
            alert.addButton(withTitle: L("Cancel"))
            if alert.runModal() == .alertFirstButtonReturn, let url = FullSSDRunner.fullDiskAccessSettingsURL {
                NSWorkspace.shared.open(url)
            }
            return
        }
        fullRunner.start(writeVerifyGigabytes: gigabytes)
    }

    private func legend(_ color: NSColor, _ title: String) -> NSView {
        let dot = DotView(size: 6)
        dot.color = color
        return hStack([dot, makeLabel(title, size: LegacyStyle.caption, color: .secondaryLabelColor)], spacing: 4)
    }
}

// MARK: - Battery capacity test

final class LegacyCapacityTest: LegacySnapshotStartable {
    private let core: MonitorCore
    private let runner: CapacityRunner
    private(set) var window: LegacyToolWindow!

    private let targets: [Double] = [50, 20, 10, 0]
    private let targetControl: NSSegmentedControl
    private let loadControl: NSSegmentedControl
    private let chart = NumericChartView()

    init(core: MonitorCore) {
        self.core = core
        runner = CapacityRunner(monitor: core)
        targetControl = NSSegmentedControl(labels: targets.map { Format.percent($0) }, trackingMode: .selectOne,
                                           target: nil, action: nil)
        targetControl.selectedSegment = 1
        loadControl = NSSegmentedControl(labels: [L("Light load"), L("Medium"), L("Heavy")], trackingMode: .selectOne,
                                         target: nil, action: nil)
        loadControl.selectedSegment = 1
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 160).isActive = true
        window = LegacyToolWindow(title: L("Battery capacity test"), contentWidth: 640, height: 700) { [unowned self] in blocks() }
        runner.onChange = { [weak self] in self?.window.reload() }
        runner.bringToFront = { [weak self] in self?.window.present() }
        // Changing the stop level shows or hides the 0 % note.
        targetControl.target = self
        targetControl.action = #selector(targetChanged)
    }

    @objc private func targetChanged() { window.reload() }

    /// Snapshots: start waiting for the adapter to be unplugged.
    func start(seconds: TimeInterval) {
        runner.start(target: target, load: .light)
    }

    private var target: Double { targets[max(0, targetControl.selectedSegment)] }

    private func blocks() -> [Block] {
        let busy = runner.busy
        targetControl.isEnabled = !busy
        loadControl.isEnabled = !busy
        let action: NSView
        if busy {
            action = ActionButton(title: L("Stop")) { [unowned self] in runner.stop() }
        } else {
            let start = ActionButton(title: L("Start test")) { [unowned self] in
                runner.start(target: target, load: CapacityRunner.Load(rawValue: loadControl.selectedSegment) ?? .medium)
            }
            start.isEnabled = (core.battery?.stateOfCharge ?? 0) > target + 5
            action = start
        }
        var blocks: [Block] = [
            .secondary(L("Discharges the battery under a steady load from the current charge down to the chosen level and compares the charge actually delivered with what the battery gauge reports. Start fully charged; the test takes one to several hours. The Mac stays awake and the display stays on.")),
            .view(hStack([targetControl, loadControl, makeSpacer(), action], spacing: 14)),
            .rows([
                DocRow(title: L("Light load"), value: L("No extra load, display on — like web browsing, writing or watching videos.")),
                DocRow(title: L("Medium"), value: L("Half of the CPU cores busy — like heavy multitasking or photo editing.")),
                DocRow(title: L("Heavy"), value: L("All CPU cores and the GPU busy — like gaming, video export or 3D rendering.")),
            ], labelWidth: 110),
            .status(L("For a reliable result, close other apps and keep the display brightness the same during the test. Other apps add load and change the power and the duration; the measured capacity stays valid, but only tests with the same load and brightness can be compared."), .neutral),
        ]
        if target == 0 && !busy {
            blocks.append(.status(L("At 0 % macOS puts the Mac to sleep or turns it off by itself. The measurements are saved while the test runs; if the Mac turns off — also early, as a weak battery does — the result appears here the next time FixStat opens. Full discharges wear the battery, so use them sparingly."), .neutral))
        }
        switch runner.state {
        case .waitingForUnplug:
            blocks.append(.headline(L("Unplug the power adapter to start."), nil))
        case .settling:
            blocks.append(.progress(L("Measuring the idle voltage…")))
            blocks += live()
        case .running:
            blocks += live()
        default:
            break
        }
        if let result = runner.result {
            blocks.append(Self.result(result))
            blocks.append(.actions([DocAction(title: L("Save samples (CSV)…")) { [unowned self] in
                LegacySave.run(runner.csv(), name: CapacityRunner.csvFileName(), fileExtension: "csv")
            }]))
        }
        return blocks
    }

    private func live() -> [Block] {
        let live = runner.live
        let last = runner.samples.last
        var blocks: [Block] = [.tiles([
            (L("Charge"), last?.percent.map { Format.percent($0) } ?? "–"),
            (L("Elapsed"), Format.duration(runner.elapsed)),
            (L("Delivered"), Format.milliampHours(Int(live.deliveredMAh))),
            (L("Energy"), Format.watthours(live.deliveredWh)),
            (L("Power"), last.map { Format.watts(Double($0.voltage) * Double(-$0.amperage) / 1_000_000, digits: 1) } ?? "–"),
            (L("Voltage"), last.map { Format.volts(millivolts: $0.voltage) } ?? "–"),
            (L("Temperature"), last?.temperature.map { Format.temperature($0) } ?? "–"),
            (L("Time to stop level"), runner.remaining(live).map { Format.duration($0) } ?? "–"),
        ], columns: 4)]
        let loaded = runner.samples.filter { !$0.idle }
        if loaded.count > 2 {
            let points = loaded.map { (x: $0.time / 60, y: Double($0.voltage) / 1000) }
            chart.update(series: [.init(points: points, color: LegacyStyle.cool, style: .line)],
                         x: (points.first?.x ?? 0)...(points.last?.x ?? 1), includesZero: false,
                         xLabel: { Format.number($0) }, yLabel: { Format.number($0, digits: 2) + " V" })
            blocks.append(.caption(L("minutes")))
            blocks.append(.view(chart))
        }
        return blocks
    }

    static func result(_ result: CapacityResult) -> Block {
        var blocks: [Block] = []
        if result.findings.isEmpty {
            blocks.append(.headline(L("Delivered charge matches the battery gauge."), .good))
        }
        blocks.append(.list(result.findings.map { .status(CapacityText.finding($0), $0 == .tooShort ? .neutral : .bad) }))
        blocks.append(.rows(CapacityText.rows(result).map { DocRow(title: $0.0, value: $0.1) }, labelWidth: 240))
        return .group(nil, blocks)
    }
}
