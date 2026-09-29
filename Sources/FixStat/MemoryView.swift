import MacSensors
import SwiftUI

/// Runs the memory test on a background thread.
@available(macOS 14.0, *)
@MainActor
@Observable
final class MemoryTestRunner {
    enum State: Equatable { case idle, running, finished }

    private(set) var state = State.idle
    private(set) var fraction = 0.0
    private(set) var pattern: MemoryTest.Pattern?
    private(set) var result: MemoryTest.Result?

    @ObservationIgnored private var test: MemoryTest?
    @ObservationIgnored private let monitor: Monitor
    @ObservationIgnored private var activity: NSObjectProtocol?

    init(monitor: Monitor) {
        self.monitor = monitor
    }

    func start(bytes: UInt64, rounds: Int) {
        guard state != .running else { return }
        let test = MemoryTest()
        self.test = test
        state = .running
        fraction = 0
        pattern = nil
        result = nil
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Memory test")
        Thread.detachNewThread { [weak self] in
            let result = test.run(bytes: bytes, rounds: rounds) { progress in
                Task { @MainActor in
                    self?.fraction = progress.fraction
                    self?.pattern = progress.pattern
                }
            }
            Task { @MainActor in self?.finish(result) }
        }
    }

    func stop() { test?.cancel() }

    private func finish(_ result: MemoryTest.Result) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        test = nil
        self.result = result
        monitor.lastMemoryResult = result
        state = .finished
    }
}

@available(macOS 14.0, *)
struct MemoryView: View {
    static let windowID = "memory"

    @Environment(MemoryTestRunner.self) private var runner
    @State private var info: MemoryInfo?
    @State private var testable: UInt64 = 0
    @State private var gigabytes = 1.0
    @State private var rounds = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let info {
                infoCard(info)
            } else {
                ProgressView().controlSize(.small)
            }
            SectionTitle(title: "Memory test")
            Text("Writes several bit patterns into free memory and reads them back. Finds clear memory faults; it cannot reach memory used by macOS itself, so it does not replace a full diagnostic that runs outside macOS.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Picker("Size", selection: $gigabytes) {
                    ForEach([0.5, 1.0, 2.0, 4.0], id: \.self) { size in
                        Text(verbatim: Format.bytes(size * 1_000_000_000)).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(runner.state == .running)
                Picker("Rounds", selection: $rounds) {
                    ForEach([1, 3, 10], id: \.self) { Text("\($0)×").tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(runner.state == .running)
                Text("\(Format.bytes(Double(testable))) usable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if runner.state == .running {
                    Button("Stop", role: .cancel) { runner.stop() }
                } else {
                    Button("Start test") {
                        let bytes = min(UInt64(gigabytes * 1_000_000_000), testable)
                        runner.start(bytes: bytes, rounds: rounds)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(testable < 100_000_000)
                }
            }
            if runner.state == .running {
                ProgressView(value: runner.fraction) {
                    Text(runner.pattern.map { MemoryText.pattern($0) } ?? "").font(.caption)
                }
            }
            if let result = runner.result {
                MemoryResultView(result: result)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 440)
        .monospacedDigit()
        .task {
            info = await Task.detached { MemoryInfo.read() }.value
            testable = MemoryInfo.testableBytes()
        }
        .onChange(of: runner.state) { _, _ in testable = MemoryInfo.testableBytes() }
    }

    private func infoCard(_ info: MemoryInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: [Format.memory(info.totalBytes), info.type, info.manufacturer]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.headline)
            Text(verbatim: [info.swapUsedBytes.map { String(localized: "Swap used: \(Format.bytes(Double($0)))") },
                            info.compressedBytes.map { String(localized: "Compressed: \(Format.bytes(Double($0)))") }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

@available(macOS 14.0, *)
struct MemoryResultView: View {
    let result: MemoryTest.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if result.allocationFailed {
                Label("Could not reserve memory for the test.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(TemperatureColor.hot)
            } else if result.passed {
                Label("No memory errors found", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(TemperatureColor.cool)
            } else {
                Label("Memory errors found", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(TemperatureColor.hot)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                ForEach(Array(MemoryText.rows(result).enumerated()), id: \.offset) { _, row in
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
enum MemoryText {
    static func pattern(_ p: MemoryTest.Pattern) -> String {
        switch p {
        case .zeros: String(localized: "All zeros")
        case .ones: String(localized: "All ones")
        case .checkerboard: String(localized: "Checkerboard")
        case .walkingOnes: String(localized: "Walking ones")
        case .addressInAddress: String(localized: "Address in address")
        case .random: String(localized: "Random data")
        }
    }

    static func rows(_ r: MemoryTest.Result) -> [(String, String)] {
        var rows: [(String, String)] = [
            (String(localized: "Tested"), Format.bytes(Double(r.bytes))),
            (String(localized: "Patterns"), "\(r.patternsCompleted.count) / \(MemoryTest.Pattern.allCases.count)"),
            (String(localized: "Rounds"), Format.number(Double(r.roundsCompleted))),
            (String(localized: "Errors"), Format.number(Double(r.errorCount))),
            (String(localized: "Duration"), Format.minutesSeconds(r.seconds)),
        ]
        if let t = r.throughput {
            rows.append((String(localized: "Throughput"), Format.speed(megabytesPerSecond: t * 1000)))
        }
        if r.errorCount > 0 {
            rows.append((String(localized: "Flipped bits"), String(format: "0x%016llX", r.flippedBits)))
            rows.append((String(localized: "First failing offsets"),
                         r.firstErrors.prefix(4).map { String(format: "0x%llX", $0) }.joined(separator: ", ")))
        }
        if r.cancelled {
            rows.append((String(localized: "Note"), String(localized: "Test was stopped before the planned duration")))
        }
        return rows
    }
}
