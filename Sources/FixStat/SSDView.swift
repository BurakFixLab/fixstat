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
