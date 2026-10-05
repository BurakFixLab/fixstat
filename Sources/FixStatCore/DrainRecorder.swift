import AppKit
import MacSensors

/// Records the gauge before every sleep and after the wake (and, through
/// `OffStateRecorder`, around shutdowns) for the drain detective. FixStat must be running:
/// it is a menu bar app that opens at login, so it usually is. Main thread.
public final class DrainRecorder {
    private let directory: URL
    private var observers: [NSObjectProtocol] = []

    static let fileName = "drain-segments.json"
    static let keep = 60

    private var markURL: URL { directory.appendingPathComponent("sleep-mark.json") }

    public init(directory: URL) {
        self.directory = directory
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.willSleep()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.didWake()
        })
    }

    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// Segments measured so far, oldest first.
    public var segments: [DrainSegment] { Self.load(from: directory) }

    private func willSleep() {
        guard let snapshot = GaugeSnapshot.read() else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Self.encoder().encode(snapshot).write(to: markURL, options: .atomic)
    }

    private func didWake() {
        guard let data = try? Data(contentsOf: markURL) else { return }
        try? FileManager.default.removeItem(at: markURL)
        guard let start = try? Self.decoder().decode(GaugeSnapshot.self, from: data), let end = GaugeSnapshot.read() else { return }
        Self.append(DrainSegment(kind: .sleep, start: start, end: end), in: directory)
    }

    // MARK: Store (shared with OffStateRecorder)

    static func load(from directory: URL) -> [DrainSegment] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return [] }
        return (try? decoder().decode([DrainSegment].self, from: data)) ?? []
    }

    static func append(_ segment: DrainSegment, in directory: URL) {
        let all = Array((load(from: directory) + [segment]).suffix(keep))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoder().encode(all).write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
