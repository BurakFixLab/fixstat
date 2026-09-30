import Foundation
import MacSensors

/// Result of the full SSD test (for the window and reports).
public struct FullSSDResult {
    public var surface: SurfaceScanResult
    public var writeVerify: SSDStressTest.Result?
    public var healthBefore: NVMeHealth?
    public var healthAfter: NVMeHealth?

    public init(surface: SurfaceScanResult, writeVerify: SSDStressTest.Result?, healthBefore: NVMeHealth?,
                healthAfter: NVMeHealth?) {
        self.surface = surface
        self.writeVerify = writeVerify
        self.healthBefore = healthBefore
        self.healthAfter = healthAfter
    }
}

/// Full SSD test: read-only surface scan of the whole disk (root, through sudo with an
/// askpass dialog), then the write–verify test on free space. Main thread; `onChange`
/// after every step. Its state is only touched on the main thread.
public final class FullSSDRunner: @unchecked Sendable {
    public enum State: Equatable {
        case idle, scanning, writeVerify, finished
        case failed(String)
    }

    public private(set) var state = State.idle
    public private(set) var surface: SurfaceScanResult?
    public private(set) var writeFraction = 0.0
    public private(set) var result: FullSSDResult?
    public var onChange: (() -> Void)?
    /// Brings the SSD window to the front after the password dialog took the focus.
    public var bringToFront: (() -> Void)?

    private let monitor: MonitorCore
    private var poll: Timer?
    private var workDirectory: URL?
    private var writeTest: SSDStressTest?
    private var activity: NSObjectProtocol?

    public init(monitor: MonitorCore) {
        self.monitor = monitor
    }

    public var isRunning: Bool { state == .scanning || state == .writeVerify }

    /// macOS has no request dialog for Full Disk Access. The TCC database can only be
    /// opened by processes that have it, which makes it a reliable check.
    public static var hasFullDiskAccess: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    /// System Settings (System Preferences) at Privacy & Security › Full Disk Access.
    public static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

    public func start(writeVerifyGigabytes: Double) {
        guard !isRunning else { return }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "fixstat-diskscan") else {
            fail(L("The disk scan helper is missing from the app."))
            return
        }
        guard let disk = InternalDisk.find() else {
            fail(L("The internal SSD could not be identified."))
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
        onChange?()

        let poll = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.readProgress(out)
        }
        RunLoop.main.add(poll, forMode: .common)
        self.poll = poll

        let prompt = L("FixStat needs administrator rights to read the whole SSD. The scan only reads; nothing is written to the disk.")
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
            DispatchQueue.main.async {
                self?.scanFinished(out: out, status: status, message: message, before: before, writeBytes: bytes)
            }
        }
    }

    public func stop() {
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

    private func fail(_ message: String) {
        state = .failed(message)
        onChange?()
    }

    private func readProgress(_ out: URL) {
        guard let data = FileManager.default.contents(atPath: out.path) else { return }
        let parsed = SurfaceScanResult.parse(String(decoding: data, as: UTF8.self))
        // The helper creates the file once sudo has accepted the password; focus went
        // to the askpass dialog and then to another app.
        if surface == nil { bringToFront?() }
        if parsed != surface {
            surface = parsed
            onChange?()
        }
    }

    private func scanFinished(out: URL, status: Int32, message: String, before: NVMeHealth?, writeBytes: Int64) {
        poll?.invalidate()
        bringToFront?()
        poll = nil
        readProgress(out)
        guard status == 0, let surface, surface.finished else {
            if message.contains("-128") || message.contains("no password was provided")
                || message.contains("a password is required") || message.contains("incorrect password") {
                state = .failed(L("Administrator permission was not given."))
            } else if message.contains("errno 1") {
                // Raw disk access needs Full Disk Access for the app, even as root.
                state = .failed(L("macOS blocked reading the disk. Allow FixStat in System Settings › Privacy & Security › Full Disk Access, then start the test again."))
            } else {
                let detail = message.components(separatedBy: "fixstat-diskscan: ").last?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                state = .failed(L("The disk scan did not complete.") + (detail.isEmpty ? "" : " (\(detail))"))
            }
            cleanUp()
            onChange?()
            return
        }
        if surface.cancelled {
            finish(FullSSDResult(surface: surface, writeVerify: nil, healthBefore: before, healthAfter: SSDInfo.readHealth()))
            return
        }
        // Second part: write–verify on free space (no root needed).
        state = .writeVerify
        onChange?()
        let test = SSDStressTest()
        writeTest = test
        let directory = FileManager.default.temporaryDirectory
        Thread.detachNewThread { [weak self] in
            let written = test.run(bytes: writeBytes, directory: directory) { progress in
                let done = Double(progress.chunk) / Double(max(progress.chunkCount, 1))
                DispatchQueue.main.async {
                    self?.writeFraction = progress.phase == .write ? done / 2 : 0.5 + done / 2
                    self?.onChange?()
                }
            }
            DispatchQueue.main.async {
                self?.finish(FullSSDResult(surface: surface, writeVerify: written, healthBefore: before,
                                           healthAfter: SSDInfo.readHealth()))
            }
        }
    }

    private func finish(_ result: FullSSDResult) {
        self.result = result
        monitor.lastFullSSDResult = result
        state = .finished
        cleanUp()
        onChange?()
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

/// Texts of the full SSD test (window and reports).
public enum FullSSDText {
    public static func findings(_ r: FullSSDResult) -> [String] {
        var findings: [String] = []
        let s = r.surface
        if !s.badRanges.isEmpty {
            let bytes = s.badRanges.reduce(0) { $0 + $1.length }
            findings.append(L("%lld unreadable areas (%@) — failing NAND", s.badRanges.count, Format.bytes(Double(bytes))))
        }
        if !s.slowChunks.isEmpty {
            findings.append(L("%lld blocks were very slow (worst %@ ms) — possible weak NAND or retries",
                              s.slowChunks.count, Format.number(s.slowestChunkMs)))
        }
        if s.cancelled { findings.append(L("Test was stopped before the planned duration")) }
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

    public static func rows(_ r: FullSSDResult) -> [(String, String)] {
        let s = r.surface
        var rows: [(String, String)] = [
            (L("Surface scanned"), "\(Format.bytes(Double(s.bytesRead))) / \(Format.bytes(Double(s.deviceSize)))"),
            (L("Average read speed"), s.averageSpeed.map { Format.speed(megabytesPerSecond: $0) } ?? "–"),
            (L("Slowest block read"), "\(Format.number(s.slowestChunkMs)) ms"),
            (L("Unreadable areas"), Format.number(Double(s.badRanges.count))),
        ]
        if let w = r.writeVerify {
            rows += SSDText.resultRows(w).map { (L("Free space: %@", $0.0), $0.1) }
        }
        return rows
    }
}
