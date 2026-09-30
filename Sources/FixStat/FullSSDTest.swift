import AppKit
import Charts
import MacSensors
import SwiftUI
import FixStatCore

/// SwiftUI view of the core `FullSSDRunner`.
@available(macOS 14.0, *)
@MainActor
@Observable
final class FullSSDTestRunner {
    typealias State = FullSSDRunner.State
    typealias Result = FullSSDResult

    private(set) var state = State.idle
    private(set) var surface: SurfaceScanResult?
    private(set) var writeFraction = 0.0
    private(set) var result: Result?

    @ObservationIgnored private let runner: FullSSDRunner
    @ObservationIgnored private let monitor: Monitor

    init(monitor: Monitor) {
        self.monitor = monitor
        runner = FullSSDRunner(monitor: monitor.core)
        runner.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
        runner.bringToFront = {
            MainActor.assumeIsolated { Self.bringWindowToFront() }
        }
    }

    var isRunning: Bool { state == .scanning || state == .writeVerify }

    static var hasFullDiskAccess: Bool { FullSSDRunner.hasFullDiskAccess }

    /// Opens System Settings at Privacy & Security › Full Disk Access.
    static func openFullDiskAccessSettings() {
        if let url = FullSSDRunner.fullDiskAccessSettingsURL { NSWorkspace.shared.open(url) }
    }

    func start(writeVerifyGigabytes: Double) { runner.start(writeVerifyGigabytes: writeVerifyGigabytes) }
    func stop() { runner.stop() }

    private func sync() {
        if runner.state != state { state = runner.state }
        if runner.surface != surface { surface = runner.surface }
        writeFraction = runner.writeFraction
        if runner.result == nil { result = nil }
        if let finished = runner.result, result == nil || state == .finished {
            result = finished
            monitor.lastFullSSDResult = finished
        }
    }

    /// Brings FixStat and the SSD window to the front after the password dialog.
    static func bringWindowToFront() {
        NSApp.activate()
        NSApp.windows.first { $0.identifier?.rawValue.contains(SSDView.windowID) == true }?
            .makeKeyAndOrderFront(nil)
    }
}

/// Section of the SSD window for the full test.
@available(macOS 14.0, *)
struct FullSSDTestSection: View {
    @Environment(FullSSDTestRunner.self) private var runner
    @Environment(SSDTestRunner.self) private var quickRunner
    let writeVerifyGigabytes: Double
    @State private var askForFullDiskAccess = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Full test (administrator permission required)")
            Text("Reads the entire SSD — including used space and the system partitions — and maps unreadable and slow areas, then runs the write–verify test on free space. The scan only reads. macOS asks for an administrator password; FixStat never sees or stores it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("Also needs Full Disk Access: if the scan does not start, allow FixStat in System Settings › Privacy & Security › Full Disk Access.",
                  systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if runner.isRunning {
                    Button("Stop", role: .cancel) { runner.stop() }
                } else {
                    Button("Start full test") {
                        if FullSSDTestRunner.hasFullDiskAccess {
                            runner.start(writeVerifyGigabytes: writeVerifyGigabytes)
                        } else {
                            askForFullDiskAccess = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(quickRunner.state == .running)
                }
                Spacer()
            }
            switch runner.state {
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(TemperatureColor.hot)
            case .scanning:
                ProgressView(value: runner.surface?.fraction ?? 0) {
                    Text("Reading the whole SSD… \(Format.bytes(Double(runner.surface?.bytesRead ?? 0))) / \(Format.bytes(Double(runner.surface?.deviceSize ?? 0)))")
                        .font(.caption)
                }
            case .writeVerify:
                ProgressView(value: runner.writeFraction) {
                    Text("Write–verify on free space…").font(.caption)
                }
            default:
                EmptyView()
            }
            if let surface = runner.surface, !surface.regions.isEmpty {
                surfaceChart(surface)
            }
            if let result = runner.result {
                FullSSDResultView(result: result)
            }
        }
        .alert("FixStat needs Full Disk Access", isPresented: $askForFullDiskAccess) {
            Button("Open System Settings") { FullSSDTestRunner.openFullDiskAccessSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To read the whole SSD, turn on FixStat in Privacy & Security › Full Disk Access, then quit and reopen FixStat and start the test again.")
        }
    }

    private func surfaceChart(_ surface: SurfaceScanResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Read speed across the disk").font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(Array(surface.regions.enumerated()), id: \.offset) { _, region in
                    BarMark(x: .value("Position", Double(region.offset) / 1e9), y: .value("MB/s", region.speed),
                            width: .ratio(0.9))
                        .foregroundStyle(TemperatureColor.cool)
                }
                ForEach(Array(surface.badRanges.enumerated()), id: \.offset) { _, bad in
                    RuleMark(x: .value("Position", Double(bad.offset) / 1e9))
                        .foregroundStyle(TemperatureColor.hot)
                }
            }
            .chartXScale(domain: 0...max(Double(surface.deviceSize) / 1e9, 1))
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { Text(Format.bytes((value.as(Double.self) ?? 0) * 1e9)) }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { Text(Format.speed(megabytesPerSecond: value.as(Double.self) ?? 0)) }
                }
            }
            .frame(height: 130)
        }
    }
}

@available(macOS 14.0, *)
struct FullSSDResultView: View {
    let result: FullSSDTestRunner.Result

    var body: some View {
        let findings = FullSSDText.findings(result)
        VStack(alignment: .leading, spacing: 8) {
            if findings.isEmpty {
                Label("No problems found", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(TemperatureColor.cool)
            } else {
                Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(TemperatureColor.hot)
                ForEach(Array(findings.enumerated()), id: \.offset) { _, text in
                    Text(verbatim: "• " + text).font(.callout)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                ForEach(Array(FullSSDText.rows(result).enumerated()), id: \.offset) { _, row in
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
