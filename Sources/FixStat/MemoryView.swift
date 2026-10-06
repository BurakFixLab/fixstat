import MacSensors
import SwiftUI
import FixStatCore

/// SwiftUI view of the core `MemoryRunner`.
@available(macOS 14.0, *)
@MainActor
@Observable
final class MemoryTestRunner {
    typealias State = MemoryRunner.State

    private(set) var state = State.idle
    private(set) var fraction = 0.0
    private(set) var pattern: MemoryTest.Pattern?
    private(set) var result: MemoryTest.Result?

    @ObservationIgnored private let runner: MemoryRunner
    @ObservationIgnored private let monitor: Monitor

    init(monitor: Monitor) {
        self.monitor = monitor
        runner = MemoryRunner(monitor: monitor.core)
        runner.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    func start(bytes: UInt64, rounds: Int) { runner.start(bytes: bytes, rounds: rounds) }
    func stop() { runner.stop() }

    private func sync() {
        if runner.state != state { state = runner.state }
        fraction = runner.fraction
        if runner.pattern != pattern { pattern = runner.pattern }
        if runner.result != result {
            result = runner.result
            monitor.lastMemoryResult = runner.result
        }
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
        VStack(alignment: .leading, spacing: 12) {
            if let info {
                infoCard(info)
            } else {
                ProgressView().controlSize(.small)
            }
            Card {
                CardHeader("Memory test", systemImage: "memorychip")
                Text("Writes several bit patterns into free memory and reads them back. Finds clear memory faults; it cannot reach memory used by macOS itself, so it does not replace a full diagnostic that runs outside macOS.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Two rows: the pickers, then what can be tested and the button, so no label
                // is squeezed at the minimum window width.
                HStack(spacing: 16) {
                    Picker("Size", selection: $gigabytes) {
                        ForEach([0.5, 1.0, 2.0, 4.0], id: \.self) { size in
                            Text(verbatim: Format.bytes(size * 1_000_000_000)).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Picker("Rounds", selection: $rounds) {
                        ForEach([1, 3, 10], id: \.self) { Text("\($0)×").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Spacer(minLength: 0)
                }
                .disabled(runner.state == .running)
                .padding(.top, 4)
                HStack {
                    Text("\(Format.bytes(Double(testable))) usable")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Spacer()
                    if runner.state == .running {
                        Button("Stop", role: .cancel) { runner.stop() }
                    } else {
                        Button("Start test") {
                            let bytes = min(UInt64(gigabytes * 1_000_000_000), testable)
                            runner.start(bytes: bytes, rounds: rounds)
                        }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                        .disabled(testable < 100_000_000)
                    }
                }
                if runner.state == .running {
                    ProgressView(value: runner.fraction) {
                        Text(runner.pattern.map { MemoryText.pattern($0) } ?? "").font(.caption)
                    }
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
        .background(Design.cardFill, in: RoundedRectangle(cornerRadius: Design.cardRadius))
    }
}
