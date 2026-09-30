import AppKit
import Charts
import MacSensors
import SwiftUI
import FixStatCore

/// Full SSD test: read-only surface scan of the whole disk (root, through the
/// macOS administrator prompt), then the write–verify test on free space.
@available(macOS 14.0, *)
@MainActor
@Observable
final class FullSSDTestRunner {
    enum State: Equatable {
        case idle, scanning, writeVerify, finished
        case failed(String)
    }

    struct Result {
        var surface: SurfaceScanResult
        var writeVerify: SSDStressTest.Result?
        var healthBefore: NVMeHealth?
        var healthAfter: NVMeHealth?
    }

    private(set) var state = State.idle
    private(set) var surface: SurfaceScanResult?
    private(set) var writeFraction = 0.0
    private(set) var result: Result?

    @ObservationIgnored private let monitor: Monitor
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var workDirectory: URL?
    @ObservationIgnored private var writeTest: SSDStressTest?
    @ObservationIgnored private var activity: NSObjectProtocol?

    init(monitor: Monitor) {
        self.monitor = monitor
    }

    var isRunning: Bool { state == .scanning || state == .writeVerify }

    /// macOS has no request dialog for Full Disk Access. The TCC database can only be
    /// opened by processes that have it, which makes it a reliable check.
    nonisolated static var hasFullDiskAccess: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    /// Opens System Settings at Privacy & Security › Full Disk Access.
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func start(writeVerifyGigabytes: Double) {
        guard !isRunning else { return }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "fixstat-diskscan") else {
            state = .failed(String(localized: "The disk scan helper is missing from the app."))
            return
        }
        guard let disk = InternalDisk.find() else {
            state = .failed(String(localized: "The internal SSD could not be identified."))
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fixstat-scan-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workDirectory = directory
        let out = directory.appendingPathComponent("scan.jsonl")
        let cancel = directory.appendingPathComponent("cancel")
        result = nil
        surface = nil
        writeFraction = 0
        state = .scanning
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Full SSD test")
        let before = SSDInfo.readHealth()

        let poll = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readProgress(out) }
        }
        RunLoop.main.add(poll, forMode: .common)
        self.poll = poll

        let prompt = String(localized: "FixStat needs administrator rights to read the whole SSD. The scan only reads; nothing is written to the disk.")
        // sudo runs as a child of FixStat, so macOS attributes the raw disk access to
        // FixStat and its Full Disk Access applies. (The administrator prompt of
        // `osascript … with administrator privileges` starts the command through a
        // system trampoline instead, and Full Disk Access is then missing.)
        // The password dialog is sudo's askpass: the password goes to sudo only.
        let askpass = directory.appendingPathComponent("askpass")
        // The prompt is embedded as a UTF-8 literal: `system attribute` decodes an
        // environment variable as Mac Roman and garbles non-ASCII text.
        let appleScript = "text returned of (display dialog \(Self.appleScriptString(prompt)) default answer \"\" "
            + "with hidden answer with title \"FixStat\" with icon caution)"
        let askpassScript = "#!/bin/sh\nexec /usr/bin/osascript -e \(Self.shellQuote(appleScript))\n"
        FileManager.default.createFile(atPath: askpass.path, contents: Data(askpassScript.utf8),
                                       attributes: [.posixPermissions: 0o700])
        let arguments = ["-A", "--", helper.path, "--device", disk.rawDevice, "--size", String(disk.size),
                         "--out", out.path, "--cancel", cancel.path]
        let bytes = Int64(writeVerifyGigabytes * 1_000_000_000)

        Thread.detachNewThread { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["SUDO_ASKPASS"] = askpass.path
            process.environment = environment
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch {}
            process.waitUntilExit()
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let status = process.terminationStatus
            Task { @MainActor in
                self?.scanFinished(out: out, status: status, message: message, before: before, writeBytes: bytes)
            }
        }
    }

    func stop() {
        switch state {
        case .scanning:
            if let directory = workDirectory {
                FileManager.default.createFile(atPath: directory.appendingPathComponent("cancel").path, contents: nil)
            }
        case .writeVerify:
            writeTest?.cancel()
        default:
            break
        }
    }

    private func readProgress(_ out: URL) {
        guard let data = FileManager.default.contents(atPath: out.path) else { return }
        let parsed = SurfaceScanResult.parse(String(decoding: data, as: UTF8.self))
        // The helper creates the file once sudo has accepted the password; focus went
        // to the askpass dialog and then to another app.
        if surface == nil { Self.bringWindowToFront() }
        if parsed != surface { surface = parsed }
    }

    private func scanFinished(out: URL, status: Int32, message: String, before: NVMeHealth?, writeBytes: Int64) {
        poll?.invalidate()
        Self.bringWindowToFront()
        poll = nil
        readProgress(out)
        guard status == 0, let surface, surface.finished else {
            if message.contains("-128") || message.contains("no password was provided")
                || message.contains("a password is required") || message.contains("incorrect password") {
                state = .failed(String(localized: "Administrator permission was not given."))
            } else if message.contains("errno 1") {
                // Raw disk access needs Full Disk Access for the app, even as root.
                state = .failed(String(localized: "macOS blocked reading the disk. Allow FixStat in System Settings › Privacy & Security › Full Disk Access, then start the test again."))
            } else {
                let detail = message.components(separatedBy: "fixstat-diskscan: ").last?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                state = .failed(String(localized: "The disk scan did not complete.") + (detail.isEmpty ? "" : " (\(detail))"))
            }
            cleanUp()
            return
        }
        if surface.cancelled {
            finish(Result(surface: surface, writeVerify: nil, healthBefore: before, healthAfter: SSDInfo.readHealth()))
            return
        }
        // Second part: write–verify on free space (no root needed).
        state = .writeVerify
        let test = SSDStressTest()
        writeTest = test
        let directory = FileManager.default.temporaryDirectory
        Thread.detachNewThread { [weak self] in
            let written = test.run(bytes: writeBytes, directory: directory) { progress in
                let done = Double(progress.chunk) / Double(max(progress.chunkCount, 1))
                Task { @MainActor in self?.writeFraction = progress.phase == .write ? done / 2 : 0.5 + done / 2 }
            }
            Task { @MainActor in
                self?.finish(Result(surface: surface, writeVerify: written, healthBefore: before,
                                    healthAfter: SSDInfo.readHealth()))
            }
        }
    }

    private func finish(_ result: Result) {
        self.result = result
        monitor.lastFullSSDResult = result
        state = .finished
        cleanUp()
    }

    /// Brings FixStat and the SSD window to the front after the password dialog.
    static func bringWindowToFront() {
        NSApp.activate()
        NSApp.windows.first { $0.identifier?.rawValue.contains(SSDView.windowID) == true }?
            .makeKeyAndOrderFront(nil)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func cleanUp() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        writeTest = nil
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
        workDirectory = nil
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

@available(macOS 14.0, *)
enum FullSSDText {
    static func findings(_ r: FullSSDTestRunner.Result) -> [String] {
        var findings: [String] = []
        let s = r.surface
        if !s.badRanges.isEmpty {
            let bytes = s.badRanges.reduce(0) { $0 + $1.length }
            findings.append(String(localized: "\(s.badRanges.count) unreadable areas (\(Format.bytes(Double(bytes)))) — failing NAND"))
        }
        if !s.slowChunks.isEmpty {
            findings.append(String(localized: "\(s.slowChunks.count) blocks were very slow (worst \(Format.number(s.slowestChunkMs)) ms) — possible weak NAND or retries"))
        }
        if s.cancelled { findings.append(String(localized: "Test was stopped before the planned duration")) }
        for f in r.writeVerify?.findings ?? [] where f != .stoppedEarly {
            findings.append(SSDText.finding(f))
        }
        if let before = r.healthBefore, let after = r.healthAfter {
            if after.mediaErrors > before.mediaErrors {
                findings.append(SSDText.finding(.smartMediaErrorsIncreased(by: after.mediaErrors - before.mediaErrors)))
            }
            if after.errorLogEntries > before.errorLogEntries {
                findings.append(SSDText.finding(.smartErrorLogIncreased(by: after.errorLogEntries - before.errorLogEntries)))
            }
        }
        return Array(NSOrderedSet(array: findings).array as? [String] ?? findings)
    }

    static func rows(_ r: FullSSDTestRunner.Result) -> [(String, String)] {
        let s = r.surface
        var rows: [(String, String)] = [
            (String(localized: "Surface scanned"), "\(Format.bytes(Double(s.bytesRead))) / \(Format.bytes(Double(s.deviceSize)))"),
            (String(localized: "Average read speed"), s.averageSpeed.map { Format.speed(megabytesPerSecond: $0) } ?? "–"),
            (String(localized: "Slowest block read"), "\(Format.number(s.slowestChunkMs)) ms"),
            (String(localized: "Unreadable areas"), Format.number(Double(s.badRanges.count))),
        ]
        if let w = r.writeVerify {
            rows += SSDText.resultRows(w).map { (String(localized: "Free space: \($0.0)"), $0.1) }
        }
        return rows
    }
}
