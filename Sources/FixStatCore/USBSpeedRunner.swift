import Foundation
import MacSensors

/// One USB drive speed test: a scratch file written to the drive, read back and compared.
public struct USBSpeedResult: Equatable {
    public var date: Date
    /// "USB-C 1", nil when the port could not be found.
    public var port: String?
    /// "vendor:product", to compare the same drive across ports.
    public var deviceKey: String?
    public var drive: String
    /// Link speed in Mb/s while tested.
    public var linkMbps: Int?
    /// MB/s.
    public var writeSpeed: Double?
    public var readSpeed: Double?
    /// I/O errors plus chunks that read back different.
    public var errors: Int
    public var stoppedEarly: Bool
    public var notEnoughSpace: Bool

    public init(date: Date, port: String?, deviceKey: String?, drive: String, linkMbps: Int?, writeSpeed: Double?,
                readSpeed: Double?, errors: Int, stoppedEarly: Bool, notEnoughSpace: Bool = false) {
        self.date = date
        self.port = port
        self.deviceKey = deviceKey
        self.drive = drive
        self.linkMbps = linkMbps
        self.writeSpeed = writeSpeed
        self.readSpeed = readSpeed
        self.errors = errors
        self.stoppedEarly = stoppedEarly
        self.notEnoughSpace = notEnoughSpace
    }
}

/// Runs the write–verify test on a USB drive on a background thread; progress arrives on
/// the main thread through `onChange`. Results go to `MonitorCore.usbSpeedResults`.
public final class USBSpeedRunner: @unchecked Sendable {
    public enum State: Equatable { case idle, running, finished }

    /// 32 chunks of 8 MiB: long enough to pass a drive's cache, short enough to repeat per port.
    public static let testBytes: Int64 = 256 << 20
    /// Free space always left on the drive.
    public static let reserveBytes: Int64 = 64 << 20

    public private(set) var state = State.idle
    public private(set) var phase = SSDStressTest.Phase.write
    public private(set) var fraction = 0.0
    /// The volume being tested.
    public private(set) var volume: String?
    public var onChange: (() -> Void)?

    private var test: SSDStressTest?
    private let monitor: MonitorCore
    private var activity: NSObjectProtocol?

    public init(monitor: MonitorCore) {
        self.monitor = monitor
    }

    public static func hasSpace(_ volume: USBVolume) -> Bool {
        volume.availableBytes >= testBytes + reserveBytes
    }

    public func start(_ volume: USBVolume, port: PortStatus?) {
        guard state != .running else { return }
        let test = SSDStressTest()
        self.test = test
        state = .running
        phase = .write
        fraction = 0
        self.volume = volume.name
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "USB drive speed test")
        onChange?()
        let base = USBSpeedResult(date: Date(), port: port.map(PortText.name), deviceKey: PortHistory.key(volume.device),
                                  drive: volume.device.name ?? volume.name, linkMbps: volume.device.megabitsPerSecond,
                                  writeSpeed: nil, readSpeed: nil, errors: 0, stoppedEarly: false)
        let directory = volume.url
        Thread.detachNewThread { [weak self] in
            let result = test.run(bytes: Self.testBytes, directory: directory, reserve: Self.reserveBytes,
                                  internalSSD: false) { progress in
                DispatchQueue.main.async { self?.update(progress) }
            }
            DispatchQueue.main.async { self?.finish(result, base: base) }
        }
    }

    public func stop() {
        test?.cancel()
    }

    private func update(_ progress: SSDStressTest.Progress) {
        phase = progress.phase
        let done = Double(progress.chunk) / Double(max(progress.chunkCount, 1))
        fraction = progress.phase == .write ? done / 2 : 0.5 + done / 2
        onChange?()
    }

    private func finish(_ result: SSDStressTest.Result, base: USBSpeedResult) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        test = nil
        var speed = base
        speed.writeSpeed = result.writeSpeed
        speed.readSpeed = result.readSpeed
        speed.errors = result.ioErrors + result.mismatchedChunks.count
        speed.stoppedEarly = result.findings.contains(.stoppedEarly)
        speed.notEnoughSpace = result.findings.contains(.notEnoughSpace)
        monitor.usbSpeedResults.append(speed)
        state = .finished
        onChange?()
    }
}

public enum USBSpeedText {
    /// Table header and rows: port, drive, link, write, read, errors.
    public static var header: [String] {
        [L("Port"), L("Drive"), L("Link"), L("Write"), L("Read"), L("Errors")]
    }

    public static func row(_ r: USBSpeedResult) -> [String] {
        [r.port ?? "–", r.drive, r.linkMbps.map(PortText.speed) ?? "–",
         r.writeSpeed.map { Format.speed(megabytesPerSecond: $0) } ?? "–",
         r.readSpeed.map { Format.speed(megabytesPerSecond: $0) } ?? "–",
         r.notEnoughSpace ? L("not enough free space") : r.stoppedEarly ? L("stopped") : Format.number(Double(r.errors))]
    }

    /// What the speed tests point to: errors on a port, or the same drive clearly slower in one port.
    public static func findings(_ results: [USBSpeedResult]) -> [String] {
        var findings: [String] = []
        for r in results where r.errors > 0 {
            findings.append(L("%1$@: %2$@ read / write errors with %3$@. If the drive works without errors in another port, check this port's connector and pins.",
                              r.port ?? L("unknown port"), Format.number(Double(r.errors)), r.drive))
        }
        // The same drive, best read speed per port.
        var best: [String: [String: Double]] = [:]
        var names: [String: String] = [:]
        for r in results where !r.stoppedEarly {
            guard let key = r.deviceKey, let port = r.port, let read = r.readSpeed else { continue }
            names[key] = r.drive
            best[key, default: [:]][port] = max(best[key]?[port] ?? 0, read)
        }
        for (key, ports) in best.sorted(by: { $0.key < $1.key }) where ports.count > 1 {
            guard let fastest = ports.max(by: { $0.value < $1.value }) else { continue }
            for (port, read) in ports.sorted(by: { $0.key < $1.key }) where read < fastest.value * slowRatio {
                findings.append(L("%1$@ read %2$@ in %3$@ but %4$@ in %5$@: check %3$@ (connector, pins, USB 3 lane).",
                                  names[key] ?? L("USB device"), Format.speed(megabytesPerSecond: read), port,
                                  Format.speed(megabytesPerSecond: fastest.value), fastest.key))
            }
        }
        return findings
    }

    /// A port is flagged when the same drive reads slower than this share of its best port.
    public static let slowRatio = 0.5

    /// "USB-C 1: read 380 MB/s" per test, for the hardware check's evidence.
    public static func summary(_ results: [USBSpeedResult]) -> String {
        results.filter { !$0.stoppedEarly && !$0.notEnoughSpace }.map { r in
            (r.port ?? r.drive) + ": " + L("read %@", r.readSpeed.map { Format.speed(megabytesPerSecond: $0) } ?? "–")
        }.joined(separator: " · ")
    }
}

extension PortHistory {
    /// The ports check's evidence including the drive speed tests.
    public func detail(_ ports: [PortStatus], speeds: [USBSpeedResult]) -> String {
        let summary = USBSpeedText.summary(speeds)
        return detail(ports) + (summary.isEmpty ? "" : " · " + L("Drive speed: %@", summary))
    }

    public func passed(_ ports: [PortStatus], speeds: [USBSpeedResult]) -> Bool {
        passed(ports) && USBSpeedText.findings(speeds).isEmpty
    }
}
