import Charts
import MacSensors
import SwiftUI
import FixStatCore

/// SwiftUI view of the core `SSDRunner` (write–verify test).
@available(macOS 14.0, *)
@MainActor
@Observable
final class SSDTestRunner {
    typealias State = SSDRunner.State

    private(set) var state = State.idle
    private(set) var phase = SSDStressTest.Phase.write
    private(set) var fraction = 0.0
    /// MB/s per chunk, in chunk order.
    private(set) var writeSpeeds: [Double] = []
    private(set) var readSpeeds: [Double] = []
    private(set) var result: SSDStressTest.Result?

    @ObservationIgnored private let runner: SSDRunner
    @ObservationIgnored private let monitor: Monitor

    init(monitor: Monitor) {
        self.monitor = monitor
        runner = SSDRunner(monitor: monitor.core)
        runner.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    func start(gigabytes: Double) { runner.start(gigabytes: gigabytes) }
    func stop() { runner.stop() }

    private func sync() {
        if runner.state != state { state = runner.state }
        if runner.phase != phase { phase = runner.phase }
        fraction = runner.fraction
        if runner.writeSpeeds != writeSpeeds { writeSpeeds = runner.writeSpeeds }
        if runner.readSpeeds != readSpeeds { readSpeeds = runner.readSpeeds }
        if runner.result != result {
            result = runner.result
            monitor.lastSSDResult = runner.result
        }
    }
}

/// SSD identity, NVMe health and the write–verify stress test.
@available(macOS 14.0, *)
struct SSDView: View {
    static let windowID = "ssd"

    @Environment(SSDTestRunner.self) private var runner
    @Environment(FullSSDTestRunner.self) private var fullRunner
    @State private var info = SSDInfo.read()
    @State private var gigabytes = 8.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let info {
                    identity(info)
                    if let health = info.health {
                        HealthCard(summary: SSDText.healthSummary(info), findings: SSDText.healthFindings(health),
                                   rows: SSDText.healthRows(health), attributes: nil)
                    } else if let ata = info.ata {
                        HealthCard(summary: SSDText.healthSummary(info), findings: SSDText.ataFindings(ata),
                                   rows: SSDText.ataRows(ata), attributes: SSDText.ataTable(ata))
                    } else {
                        Text("SMART data is not available for this SSD.")
                            .foregroundStyle(.secondary)
                        if SSDText.needsFullDiskAccess(info) {
                            Label(SSDText.fullDiskAccessHint, systemImage: "lock.shield")
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open System Settings") { FullSSDTestRunner.openFullDiskAccessSettings() }
                        }
                        if let problem = info.smartProblem {
                            Text(verbatim: problem).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if !info.otherDrives.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionTitle(title: "Other internal drives")
                            ForEach(Array(info.otherDrives.enumerated()), id: \.offset) { _, drive in
                                let problems = drive.health.map(SSDText.ataFindings)?.isEmpty == false
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(drive.model ?? "–", systemImage: problems ? "exclamationmark.triangle.fill" : "internaldrive")
                                        .fontWeight(.medium)
                                        .foregroundStyle(problems ? TemperatureColor.hot : .primary)
                                    Text(verbatim: SSDText.driveSummary(drive)).foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                    }
                } else {
                    Text("No internal SSD found.").foregroundStyle(.secondary)
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
            Text(verbatim: SSDText.identity(info))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let space = info.space {
                Text(verbatim: SSDText.space(space)).font(.callout).foregroundStyle(.secondary)
            }
            if let io = info.io {
                if let finding = SSDText.ioFinding(io) {
                    Label(finding, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(TemperatureColor.hot)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(verbatim: SSDText.io(io)).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Stress test

    private var stressTest: some View {
        let available = Double(SSDRunner.availableBytes) / 1_000_000_000
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
                        .disabled(available < 1 || fullRunner.isRunning)
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
            Divider().padding(.vertical, 6)
            FullSSDTestSection(writeVerifyGigabytes: gigabytes)
        }
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
                ForEach(Array(SSDRunner.movingAverage(runner.writeSpeeds, window: 8).enumerated()), id: \.offset) { index, speed in
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
@available(macOS 14.0, *)
private struct HealthCard: View {
    let summary: String?
    let findings: [String]
    let rows: [(String, String)]
    /// ATA SMART attribute table (technician detail), nil for NVMe.
    let attributes: [[String]]?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Health (SMART)")
            if let summary {
                Text(verbatim: summary).font(.title3.weight(.semibold))
            }
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
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(verbatim: row.0).foregroundStyle(.secondary)
                        Text(verbatim: row.1).font(.callout.monospaced())
                    }
                }
            }
            .font(.callout)
            if let attributes {
                DisclosureGroup("All SMART attributes") {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                        GridRow {
                            ForEach(SSDText.ataTableHeader, id: \.self) { Text(verbatim: $0).foregroundStyle(.secondary) }
                        }
                        ForEach(Array(attributes.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(verbatim: cell) }
                            }
                        }
                    }
                    .font(.caption.monospaced())
                    .padding(.top, 4)
                }
                .font(.callout)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

@available(macOS 14.0, *)
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
