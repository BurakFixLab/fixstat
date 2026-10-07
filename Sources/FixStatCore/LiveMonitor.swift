import Foundation
import MacSensors

/// Live view of chosen SMC values (power totals, rails, temperatures, fans, battery) at up to
/// four samples a second, for watching a board while working on it: plugging the charger,
/// heating or cooling a part, flexing a cable. Only the chosen channels are read, on a
/// background queue; the last ten minutes stay in memory, a recording keeps everything until it
/// is stopped and exported as CSV. Read-only like everything else.
public final class LiveMonitor {
    public enum Unit: String {
        case watts, volts, amps, celsius, rpm, millivolts, milliamps
    }

    public enum Group: Int, CaseIterable {
        case power, temperatures, fans, battery, rails
    }

    public struct Channel: Equatable {
        public let id: String
        public let title: String
        /// Raw SMC key or HID name, for technicians.
        public let detail: String?
        public let unit: Unit
        public let group: Group
        let source: Source
    }

    enum Source: Equatable {
        case smc(String)
        case hid(String)
        case batteryVoltage, batteryAmperage, batteryTemperature
        case cell(Int)
    }

    public struct Sample {
        public let time: Date
        public let values: [String: Double]
    }

    public static let intervals: [TimeInterval] = [0.25, 0.5, 1]
    public static let window: TimeInterval = 10 * 60
    public static let maximumChannels = 6
    /// A recording stops by itself after this long (≈ 29 000 rows at 4 per second).
    public static let maximumRecording: TimeInterval = 2 * 3600

    public private(set) var channels: [Channel] = []
    public private(set) var ready = false
    public private(set) var selected: [String] = []
    public private(set) var interval: TimeInterval = 0.5
    public private(set) var samples: [Sample] = []
    /// Samples since "Record" was pressed; nil while not recording.
    public private(set) var recording: [Sample]?
    public private(set) var recordingStarted: Date?
    public private(set) var markers: [Date] = []
    /// Called on the main thread after every sample and every change.
    public var onChange: (() -> Void)?

    private let monitor: MonitorCore
    private let queue = DispatchQueue(label: "fixstat.live-monitor")
    private var timer: DispatchSourceTimer?
    // Touched only on `queue`.
    private var smc: SMC?
    private var hid: HIDSensorReader?
    private var active: [Channel] = []

    public init(monitor: MonitorCore) {
        self.monitor = monitor
    }

    public var isRunning: Bool { timer != nil }

    public func channel(_ id: String) -> Channel? { channels.first { $0.id == id } }

    // MARK: Start / stop

    /// Opens the SMC in the background (enumerating its keys takes seconds on old Intel Macs),
    /// builds the channel list and starts sampling.
    public func start() {
        guard timer == nil else { return }
        let sensors = monitor.sensors
        let battery = monitor.profile.hasBattery ? monitor.battery : nil
        let fanCount = monitor.fans.count
        queue.async { [weak self] in
            guard let self else { return }
            if self.smc == nil { self.smc = try? SMC() }
            if self.hid == nil { self.hid = HIDSensorReader(kind: .temperature) }
            let channels = self.channels.isEmpty
                ? Self.discover(smc: self.smc, sensors: sensors, battery: battery, fans: fanCount) : self.channels
            DispatchQueue.main.async {
                self.channels = channels
                self.ready = true
                if self.selected.isEmpty { self.selected = Self.defaultSelection(channels) }
                self.applySelection()
                self.schedule()
                self.onChange?()
            }
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func setInterval(_ value: TimeInterval) {
        interval = value
        if timer != nil {
            stop()
            schedule()
        }
        onChange?()
    }

    public func toggle(_ id: String) {
        if let index = selected.firstIndex(of: id) {
            selected.remove(at: index)
        } else if selected.count < Self.maximumChannels {
            selected.append(id)
        }
        applySelection()
        onChange?()
    }

    public func clear() {
        samples = []
        markers = []
        onChange?()
    }

    // MARK: Recording

    public func startRecording() {
        recording = []
        recordingStarted = Date()
        markers = []
        onChange?()
    }

    /// Stops and returns the recording as CSV (nil if nothing was recorded).
    public func stopRecording() -> String? {
        defer {
            recording = nil
            recordingStarted = nil
            onChange?()
        }
        guard let recording, !recording.isEmpty else { return nil }
        return Self.csv(recording, channels: selected.compactMap(channel), markers: markers)
    }

    /// The window shown on screen as CSV.
    public func windowCSV() -> String { Self.csv(samples, channels: selected.compactMap(channel), markers: markers) }

    public func addMarker() {
        markers.append(Date())
        onChange?()
    }

    /// One row per sample: ISO time, seconds since the first row, a column per channel and the
    /// marker ("M3") that fell between the previous row and this one.
    static func csv(_ rows: [Sample], channels shown: [Channel], markers: [Date]) -> String {
        let start = rows.first?.time ?? Date()
        var lines = [(["time", "seconds"] + shown.map { "\($0.title) [\(Self.unitSymbol($0.unit))]" } + ["marker"])
            .map(Self.csvField).joined(separator: ",")]
        var pending = markers.filter { $0 >= start }.sorted()
        var markerNumber = markers.filter { $0 < start }.count
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for row in rows {
            var marker = ""
            while let first = pending.first, first <= row.time {
                pending.removeFirst()
                markerNumber += 1
                marker = "M\(markerNumber)"
            }
            let values = shown.map { channel in row.values[channel.id].map { String(format: "%.4g", $0) } ?? "" }
            lines.append(([iso.string(from: row.time), String(format: "%.2f", row.time.timeIntervalSince(start))]
                + values + [marker]).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func csvField(_ text: String) -> String {
        text.contains(",") || text.contains("\"") ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }

    // MARK: Sampling

    private func applySelection() {
        let chosen = selected.compactMap(channel)
        queue.async { [weak self] in self?.active = chosen }
    }

    private func schedule() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
    }

    /// On `queue`: reads the chosen channels.
    private func sample() {
        var values: [String: Double] = [:]
        let needsHID = active.contains { if case .hid = $0.source { return true } else { return false } }
        let needsBattery = active.contains {
            switch $0.source {
            case .batteryVoltage, .batteryAmperage, .batteryTemperature, .cell: return true
            default: return false
            }
        }
        var hidValues: [String: Double] = [:]
        if needsHID {
            for reading in hid?.read() ?? [] {
                // Same as `SensorDescriptor.uid` of a HID sensor.
                hidValues["hid:" + (reading.key ?? reading.name)] = reading.value
            }
        }
        let battery = needsBattery ? BatteryReader.read() : nil
        for channel in active {
            let value: Double?
            switch channel.source {
            case let .smc(key):
                value = (try? smc?.read(key))?.flatMap { $0.doubleValue }
            case let .hid(uid):
                value = hidValues[uid]
            case .batteryVoltage: value = battery?.voltage.map(Double.init)
            case .batteryAmperage: value = battery?.amperage.map(Double.init)
            case .batteryTemperature: value = battery?.temperature
            case let .cell(index):
                value = battery?.cellVoltages.flatMap { index < $0.count ? Double($0[index]) : nil }
            }
            if let value, value.isFinite, abs(value) < 100_000 { values[channel.id] = value }
        }
        let sample = Sample(time: Date(), values: values)
        DispatchQueue.main.async { [weak self] in self?.append(sample) }
    }

    private func append(_ sample: Sample) {
        samples.append(sample)
        let cutoff = sample.time.addingTimeInterval(-Self.window)
        if let first = samples.firstIndex(where: { $0.time >= cutoff }), first > 0 {
            samples.removeFirst(first)
        }
        if recording != nil {
            recording?.append(sample)
            if let started = recordingStarted, sample.time.timeIntervalSince(started) >= Self.maximumRecording {
                stop()
            }
        }
        onChange?()
    }

    // MARK: Channels

    static func discover(smc: SMC?, sensors: [DisplaySensor], battery: BatteryInfo?, fans: Int) -> [Channel] {
        var channels: [Channel] = []
        if let smc {
            let totals = PowerRails.readTotals(smc: smc)
            for (key, title) in [("PSTR", L("System total")), ("PDTR", L("Power adapter input")), ("PPBR", L("Battery rail"))]
            where totals[key] != nil {
                channels.append(Channel(id: "smc:" + key, title: title, detail: key, unit: .watts, group: .power,
                                        source: .smc(key)))
            }
            for rail in PowerRails.discover(smc: smc) {
                let name = PowerText.rail(rail.name)
                for (key, unit) in [(rail.watts, Unit.watts), (rail.amps, .amps), (rail.volts, .volts)] {
                    guard let key else { continue }
                    channels.append(Channel(id: "smc:" + key, title: name + " · " + unitSymbol(unit), detail: key,
                                            unit: unit, group: .rails, source: .smc(key)))
                }
            }
            for index in 0..<fans {
                channels.append(Channel(id: "fan:\(index)", title: L("Fan %lld", index + 1), detail: "F\(index)Ac",
                                        unit: .rpm, group: .fans, source: .smc("F\(index)Ac")))
                channels.append(Channel(id: "fan:\(index):target", title: L("Fan %lld target", index + 1),
                                        detail: "F\(index)Tg", unit: .rpm, group: .fans, source: .smc("F\(index)Tg")))
            }
        }
        for sensor in sensors where sensor.isMatched {
            let source: Source = sensor.descriptor.source == .hid ? .hid(sensor.id) : .smc(sensor.descriptor.key ?? "")
            channels.append(Channel(id: sensor.id, title: sensor.name, detail: sensor.descriptor.rawLabel,
                                    unit: .celsius, group: .temperatures, source: source))
        }
        if let battery {
            channels.append(Channel(id: "battery:voltage", title: L("Battery voltage"), detail: nil, unit: .millivolts,
                                    group: .battery, source: .batteryVoltage))
            channels.append(Channel(id: "battery:amperage", title: L("Battery current"), detail: nil, unit: .milliamps,
                                    group: .battery, source: .batteryAmperage))
            channels.append(Channel(id: "battery:temperature", title: L("Battery temperature"), detail: nil,
                                    unit: .celsius, group: .battery, source: .batteryTemperature))
            for index in 0..<(battery.cellVoltages?.count ?? 0) {
                channels.append(Channel(id: "battery:cell:\(index)", title: L("Cell %lld", index + 1), detail: nil,
                                        unit: .millivolts, group: .battery, source: .cell(index)))
            }
        }
        return channels
    }

    /// System total and DC in, else the hottest-named CPU sensor and the battery current.
    static func defaultSelection(_ channels: [Channel]) -> [String] {
        let preferred = ["smc:PSTR", "smc:PDTR", "battery:amperage"]
        var ids = preferred.filter { id in channels.contains { $0.id == id } }
        if let cpu = channels.first(where: { $0.group == .temperatures }) { ids.append(cpu.id) }
        return Array(ids.prefix(3))
    }

    // MARK: Formatting

    public static func unitSymbol(_ unit: Unit) -> String {
        switch unit {
        case .watts: return "W"
        case .volts: return "V"
        case .amps: return "A"
        case .celsius: return "°C"
        case .rpm: return "rpm"
        case .millivolts: return "mV"
        case .milliamps: return "mA"
        }
    }

    public static func format(_ value: Double, _ unit: Unit) -> String {
        switch unit {
        case .watts: return Format.watts(value, digits: 2)
        case .volts: return Format.volts(millivolts: Int((value * 1000).rounded()), digits: 3)
        case .amps: return Format.amps(milliamps: Int((value * 1000).rounded()))
        case .celsius: return Format.temperature(value)
        case .rpm: return Format.rpm(value)
        case .millivolts: return Format.millivolts(Int(value.rounded()))
        case .milliamps: return Format.milliamps(Int(value.rounded()))
        }
    }

    /// Axis labels: fewer decimals than the readings.
    public static func axisLabel(_ value: Double, _ unit: Unit) -> String {
        switch unit {
        case .watts: return Format.watts(value, digits: abs(value) < 10 ? 1 : 0)
        case .volts: return Format.volts(millivolts: Int((value * 1000).rounded()), digits: 2)
        default: return format(value, unit)
        }
    }

    public static func groupTitle(_ group: Group) -> String {
        switch group {
        case .power: return L("Power")
        case .temperatures: return L("Temperatures")
        case .fans: return L("Fans")
        case .battery: return L("Battery")
        case .rails: return L("Power rails")
        }
    }
}
