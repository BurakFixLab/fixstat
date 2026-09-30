import AppKit
import MacSensors

/// Measures the battery drain while the Mac is shut down: saves the gauge's remaining
/// capacity when macOS announces a power off and compares it when FixStat starts again
/// after the next boot (FixStat must open at login for this).
public final class OffStateRecorder {
    private let directory: URL
    private var observer: NSObjectProtocol?

    private var markURL: URL { directory.appendingPathComponent("power-off.json") }
    private var periodsURL: URL { directory.appendingPathComponent("off-periods.json") }

    public init(directory: URL) {
        self.directory = directory
        completePendingMark()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.saveMark()
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// Periods measured so far, oldest first.
    public var periods: [OffPeriod] {
        guard let data = try? Data(contentsOf: periodsURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([OffPeriod].self, from: data)) ?? []
    }

    /// Also posted for a logout; `completePendingMark` only keeps it if a boot followed.
    private func saveMark() {
        let b = BatteryReader.read()
        let mark = OffStateDrain.PowerOffMark(date: Date(), remaining: b?.rawCurrentCapacity, charge: b?.stateOfCharge,
                                              fullChargeCapacity: b?.rawMaxCapacity)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoder.encode(mark).write(to: markURL, options: .atomic)
    }

    private func completePendingMark() {
        guard let data = try? Data(contentsOf: markURL) else { return }
        try? FileManager.default.removeItem(at: markURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let mark = try? decoder.decode(OffStateDrain.PowerOffMark.self, from: data),
              let b = BatteryReader.read(),
              let period = OffStateDrain.measured(mark: mark, records: OffStateDrain.bootRecords(), now: Date(),
                                                  remaining: b.rawCurrentCapacity, charge: b.stateOfCharge)
        else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        let all = Array((periods + [period]).suffix(30))
        try? encoder.encode(all).write(to: periodsURL, options: .atomic)
    }
}
