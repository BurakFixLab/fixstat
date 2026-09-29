import Charts
import MacSensors
import SwiftUI

/// Runs the SSD write–verify test on a background thread and publishes progress.
@MainActor
@Observable
final class SSDTestRunner {
    enum State: Equatable { case idle, running, finished }

    private(set) var state = State.idle
    private(set) var phase = SSDStressTest.Phase.write
    private(set) var fraction = 0.0
    /// MB/s per chunk, in chunk order.
    private(set) var writeSpeeds: [Double] = []
    private(set) var readSpeeds: [Double] = []
    private(set) var result: SSDStressTest.Result?

    @ObservationIgnored private var test: SSDStressTest?
    @ObservationIgnored private let monitor: Monitor
    @ObservationIgnored private var activity: NSObjectProtocol?

    init(monitor: Monitor) {
        self.monitor = monitor
    }

    func start(gigabytes: Double) {
        guard state != .running else { return }
        let test = SSDStressTest()
        self.test = test
        state = .running
        phase = .write
        fraction = 0
        writeSpeeds = []
        readSpeeds = []
        result = nil
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "SSD stress test")
        let bytes = Int64(gigabytes * 1_000_000_000)
        let directory = FileManager.default.temporaryDirectory
        Thread.detachNewThread { [weak self] in
            let result = test.run(bytes: bytes, directory: directory) { progress in
                Task { @MainActor in self?.update(progress) }
            }
            Task { @MainActor in self?.finish(result) }
        }
    }

    func stop() {
        test?.cancel()
    }

    private func update(_ progress: SSDStressTest.Progress) {
        phase = progress.phase
        let done = Double(progress.chunk) / Double(max(progress.chunkCount, 1))
        fraction = progress.phase == .write ? done / 2 : 0.5 + done / 2
        switch progress.phase {
        case .write: writeSpeeds = writeSpeeds + [progress.throughput]
        case .verify: readSpeeds = readSpeeds + [progress.throughput]
        }
    }

    private func finish(_ result: SSDStressTest.Result) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        test = nil
        self.result = result
        monitor.lastSSDResult = result
        state = .finished
    }
}

/// SSD identity, NVMe health and the write–verify stress test.
struct SSDView: View {
    static let windowID = "ssd"

    @Environment(SSDTestRunner.self) private var runner
    @State private var info = SSDInfo.read()
    @State private var gigabytes = 8.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let info {
                    identity(info)
                    if let health = info.health {
                        HealthCard(health: health)
                    } else {
                        Text("SMART data is not available for this SSD.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No internal NVMe SSD found.").foregroundStyle(.secondary)
                }
                stressTest
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 600)
        .monospacedDigit()
        .onChange(of: runner.state) { _, state in
            if state == .finished { info = SSDInfo.read() }
        }
    }

    private func identity(_ info: SSDInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: info.model ?? "SSD").font(.headline)
            Text(verbatim: [info.capacity.map { Format.bytes($0) },
                            [info.nandVendor, info.nandType].compactMap { $0 }.joined(separator: " "),
                            info.bitsPerCell.map { String(localized: "\($0) bits per cell") },
                            info.firmware.map { "FW \($0)" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Stress test

    private var stressTest: some View {
        let available = Double(SSDStressTest.availableBytes(in: FileManager.default.temporaryDirectory)) / 1_000_000_000
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Write–verify stress test")
            Text("Writes a test file to free space, reads it back and compares every byte. Finds data corruption, I/O errors and stalling areas that point to failing NAND. Only free space can be tested, and the test uses some of the SSD's write endurance.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Picker("Size", selection: $gigabytes) {
                    ForEach([2.0, 8.0, 16.0, 32.0], id: \.self) { size in
                        Text(verbatim: Format.bytes(size * 1_000_000_000)).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(runner.state == .running)
                Text("\(Format.bytes(available * 1_000_000_000)) usable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if runner.state == .running {
                    Button("Stop", role: .cancel) { runner.stop() }
                } else {
                    Button("Start test") { runner.start(gigabytes: gigabytes) }
                        .buttonStyle(.borderedProminent)
                        .disabled(available < 1)
                }
            }
            if runner.state == .running {
                ProgressView(value: runner.fraction) {
                    Text(runner.phase == .write ? "Writing…" : "Reading and verifying…").font(.caption)
                }
            }
            if !runner.writeSpeeds.isEmpty {
                speedChart
            }
            if let result = runner.result {
                SSDResultView(result: result)
            }
        }
    }

    static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, !values.isEmpty else { return values }
        var result: [Double] = []
        result.reserveCapacity(values.count)
        var sum = 0.0
        for (index, value) in values.enumerated() {
            sum += value
            if index >= window { sum -= values[index - window] }
            result.append(sum / Double(min(index + 1, window)))
        }
        return result
    }

    private var speedChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Speed per 8 MB block").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Label("Write", systemImage: "circle.fill").foregroundStyle(TemperatureColor.hot)
                Label("Read", systemImage: "circle.fill").foregroundStyle(TemperatureColor.cool)
            }
            .font(.caption)
            Chart {
                // The SSD's own cache makes single write blocks spiky; show a moving average.
                ForEach(Array(Self.movingAverage(runner.writeSpeeds, window: 8).enumerated()), id: \.offset) { index, speed in
                    LineMark(x: .value("Block", index), y: .value("MB/s", speed), series: .value("Phase", "write"))
                        .foregroundStyle(TemperatureColor.hot)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                ForEach(Array(runner.readSpeeds.enumerated()), id: \.offset) { index, speed in
                    LineMark(x: .value("Block", index), y: .value("MB/s", speed), series: .value("Phase", "read"))
                        .foregroundStyle(TemperatureColor.cool)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { Text(Format.speed(megabytesPerSecond: value.as(Double.self) ?? 0)) }
                }
            }
            .frame(height: 150)
        }
    }
}

/// SMART values with an assessment.
private struct HealthCard: View {
    let health: NVMeHealth

    var body: some View {
        let findings = SSDText.healthFindings(health)
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Health (SMART)")
            if findings.isEmpty {
                Label("SSD health is good.", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(TemperatureColor.cool)
            } else {
                ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                    Label(finding, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(TemperatureColor.hot)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                ForEach(Array(SSDText.healthRows(health).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(verbatim: row.0).foregroundStyle(.secondary)
                        Text(verbatim: row.1).font(.callout.monospaced())
                    }
                }
            }
            .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SSDResultView: View {
    let result: SSDStressTest.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let problems = result.findings.filter { $0 != .stoppedEarly }
            if problems.isEmpty {
                Label("No problems found", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(TemperatureColor.cool)
            } else {
                Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(TemperatureColor.hot)
            }
            ForEach(Array(result.findings.enumerated()), id: \.offset) { _, finding in
                Text(verbatim: "• " + SSDText.finding(finding)).font(.callout)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                ForEach(Array(SSDText.resultRows(result).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(verbatim: row.0).foregroundStyle(.secondary)
                        Text(verbatim: row.1).font(.callout.monospaced())
                    }
                }
            }
            .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Localized SSD texts (window and PDF report).
enum SSDText {
    static let usedWarning = 80
    static let usedCritical = 100

    static func healthFindings(_ h: NVMeHealth) -> [String] {
        var findings: [String] = []
        if h.criticalWarning != 0 {
            findings.append(String(localized: "The SSD reports a critical warning (code \(h.criticalWarning))."))
        }
        if h.percentageUsed >= usedCritical {
            findings.append(String(localized: "Rated endurance used up (\(h.percentageUsed) %)."))
        } else if h.percentageUsed >= usedWarning {
            findings.append(String(localized: "Most of the rated endurance is used (\(h.percentageUsed) %)."))
        }
        if h.availableSpare < h.availableSpareThreshold {
            findings.append(String(localized: "Spare blocks below threshold (\(h.availableSpare) %)."))
        }
        if h.mediaErrors > 0 {
            findings.append(String(localized: "\(Format.number(h.mediaErrors)) media / data integrity errors recorded."))
        }
        return findings
    }

    static func healthRows(_ h: NVMeHealth) -> [(String, String)] {
        [
            (String(localized: "Endurance used"), Format.percent(Double(h.percentageUsed))),
            (String(localized: "Available spare"), Format.percent(Double(h.availableSpare))),
            (String(localized: "Data written"), Format.bytes(h.bytesWritten)),
            (String(localized: "Data read"), Format.bytes(h.bytesRead)),
            (String(localized: "Power-on hours"), Format.number(h.powerOnHours)),
            (String(localized: "Power cycles"), Format.number(h.powerCycles)),
            (String(localized: "Unsafe shutdowns"), Format.number(h.unsafeShutdowns)),
            (String(localized: "Media errors"), Format.number(h.mediaErrors)),
            (String(localized: "Error log entries"), Format.number(h.errorLogEntries)),
            (String(localized: "Temperature"), h.temperature.map { Format.temperature($0, digits: 0) } ?? "–"),
        ]
    }

    static func finding(_ f: SSDStressTest.Result.Finding) -> String {
        switch f {
        case let .dataMismatch(chunks, first):
            return String(localized: "Data read back did not match in \(chunks) blocks (first at \(Format.bytes(Double(first) * 8_388_608))) — failing NAND or controller")
        case let .ioErrors(count):
            return String(localized: "\(count) read / write errors")
        case let .slowChunks(count, worst):
            return String(localized: "\(count) blocks were very slow (worst \(Format.number(worst * 1000)) ms) — possible weak NAND or retries")
        case let .smartMediaErrorsIncreased(by):
            return String(localized: "SMART media errors increased by \(Format.number(by)) during the test")
        case let .smartErrorLogIncreased(by):
            return String(localized: "SMART error log grew by \(Format.number(by)) entries during the test")
        case .stoppedEarly:
            return String(localized: "Test was stopped before the planned duration")
        case .notEnoughSpace:
            return String(localized: "Not enough free space for the test")
        }
    }

    static func resultRows(_ r: SSDStressTest.Result) -> [(String, String)] {
        var rows: [(String, String)] = [
            (String(localized: "Tested"), Format.bytes(r.testedBytes)),
            (String(localized: "Write speed"), r.writeSpeed.map { Format.speed(megabytesPerSecond: $0) } ?? "–"),
            (String(localized: "Read speed"), r.readSpeed.map { Format.speed(megabytesPerSecond: $0) } ?? "–"),
        ]
        let writes = r.timings.map(\.write).sorted()
        let reads = r.timings.compactMap(\.read).sorted()
        if let worst = writes.last {
            rows.append((String(localized: "Slowest block write"), "\(Format.number(worst * 1000)) ms"))
        }
        if let worst = reads.last {
            rows.append((String(localized: "Slowest block read"), "\(Format.number(worst * 1000)) ms"))
        }
        return rows
    }
}
