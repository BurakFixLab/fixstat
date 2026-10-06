import AppKit
import CoreBluetooth
import CoreWLAN
import MacSensors

// Readers and watchers behind the hardware check, shared by both interfaces. Main thread
// unless noted; watchers report through `onChange`.

// MARK: - Display

public enum DisplayInfo {
    public static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
        } ?? NSScreen.main
    }

    /// "Built-in Retina Display · 2560 × 1600 · 60 Hz"
    public static func describe(_ screen: NSScreen) -> String {
        var parts: [String] = []
        if #available(macOS 10.15, *) { parts.append(screen.localizedName) }
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let mode = CGDisplayCopyDisplayMode(number.uint32Value) {
            parts.append("\(mode.pixelWidth) × \(mode.pixelHeight)")
            if #available(macOS 12, *) {
                if screen.maximumFramesPerSecond > 0 {
                    parts.append(Format.number(Double(screen.maximumFramesPerSecond)) + "\u{00A0}Hz")
                }
            } else if mode.refreshRate > 0 {
                parts.append(Format.number(mode.refreshRate) + "\u{00A0}Hz")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Number of full-screen test patterns (black, white, red, green, blue, gray, gradient).
    public static let patternCount = 7

    public static func patternsShown(_ count: Int) -> String {
        L("%lld / %lld patterns shown", count, patternCount)
    }
}

// MARK: - Wi-Fi

public struct WiFiLink: Sendable {
    public let interface: String
    public let powerOn: Bool
    public let connected: Bool
    public let rssi: Int
    public let noise: Int
    public let transmitRate: Double
    public let channel: String?
    public let phyMode: String?

    public static func read() -> WiFiLink? {
        guard let i = CWWiFiClient.shared().interface() else { return nil }
        let rssi = i.rssiValue()
        let channel = i.wlanChannel().map { c in
            "\(c.channelNumber) · \(WiFiScan.band(c.channelBand) ?? "") · \(width(c.channelWidth))"
        }
        return WiFiLink(interface: i.interfaceName ?? "Wi-Fi", powerOn: i.powerOn(), connected: rssi != 0,
                        rssi: rssi, noise: i.noiseMeasurement(), transmitRate: i.transmitRate(),
                        channel: channel, phyMode: phy(i.activePHYMode()))
    }

    private static func width(_ w: CWChannelWidth) -> String {
        switch w {
        case .width20MHz: return "20 MHz"
        case .width40MHz: return "40 MHz"
        case .width80MHz: return "80 MHz"
        case .width160MHz: return "160 MHz"
        default: return "–"
        }
    }

    private static func phy(_ mode: CWPHYMode) -> String? {
        // Raw values: 802.11ax is not in the macOS 10.13 SDK enum.
        switch mode.rawValue {
        case 1: return "802.11a"
        case 2: return "802.11b"
        case 3: return "802.11g"
        case 4: return "802.11n (Wi-Fi 4)"
        case 5: return "802.11ac (Wi-Fi 5)"
        case 6: return "802.11ax (Wi-Fi 6)"
        default: return nil
        }
    }

    /// Signal, noise, rate, channel, standard as label / value rows.
    public var rows: [(String, String)] {
        var rows = [(L("Interface"), [interface, powerOn ? L("on") : L("off")].joined(separator: " · "))]
        if connected {
            rows.append((L("Signal"), Format.decibels(Double(rssi), unit: "dBm")
                         + " · " + L("noise %@", Format.decibels(Double(noise), unit: "dBm"))))
            rows.append((L("Signal-to-noise"), Format.decibels(Double(rssi - noise), unit: "dB")))
            rows.append((L("Transmit rate"), Format.number(transmitRate) + "\u{00A0}Mb/s"))
            if let channel { rows.append((L("Channel"), channel)) }
            if let phyMode { rows.append((L("Standard"), phyMode)) }
        } else {
            rows.append((L("Signal"), L("not connected")))
        }
        return rows
    }
}

/// Nearby networks. Without Location permission macOS hides the names, which are
/// not needed here: the count and signal strengths test the radio and antennas.
/// `run()` blocks for a few seconds: call it in the background.
public struct WiFiScan: Sendable {
    public let count: Int
    public let strongest: Int?
    public let bands: [String]

    public static func run() -> WiFiScan? {
        guard let i = CWWiFiClient.shared().interface(),
              let networks = try? i.scanForNetworks(withName: nil) else { return nil }
        let bands = Set(networks.compactMap { $0.wlanChannel?.channelBand.rawValue })
        return WiFiScan(count: networks.count, strongest: networks.map(\.rssiValue).max(),
                        bands: bands.sorted().compactMap { CWChannelBand(rawValue: $0).flatMap(band) })
    }

    static func band(_ band: CWChannelBand) -> String? {
        // Raw values: the 6 GHz band is not in the macOS 10.13 SDK enum.
        switch band.rawValue {
        case 1: return "2.4 GHz"
        case 2: return "5 GHz"
        case 3: return "6 GHz"
        default: return nil
        }
    }

    public var summary: String {
        var parts = [L("%lld networks", count)]
        if let strongest {
            parts.append(L("strongest %@", Format.decibels(Double(strongest), unit: "dBm")))
        }
        if !bands.isEmpty { parts.append(bands.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Bluetooth

/// Controller facts from `system_profiler SPBluetoothDataType -json` (no permission
/// needed; the controller address is not read). Blocks: call it in the background.
public struct BluetoothController: Sendable {
    public let on: Bool
    public let chipset: String?
    public let firmware: String?
    public let transport: String?
    public let connected: Int
    public let notConnected: Int

    public static func read() -> BluetoothController? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = (json["SPBluetoothDataType"] as? [[String: Any]])?.first else { return nil }
        // macOS 12+: controller_properties; older systems: local_device_title.
        let c = root["controller_properties"] as? [String: Any] ?? root["local_device_title"] as? [String: Any] ?? [:]
        let connected = (root["device_connected"] as? [Any])?.count ?? 0
        let notConnected = (root["device_not_connected"] as? [Any])?.count ?? 0
        let state = (c["controller_state"] ?? c["general_power"]) as? String
        return BluetoothController(on: state == "attrib_on",
                                   chipset: (c["controller_chipset"] ?? c["general_chipset"]) as? String,
                                   firmware: (c["controller_firmwareVersion"] ?? c["general_fw_version"]) as? String,
                                   transport: (c["controller_transport"] ?? c["general_hci_transport"]) as? String,
                                   connected: connected, notConnected: notConnected)
    }

    public var rows: [(String, String)] {
        var rows = [(L("State"), on ? L("on") : L("off"))]
        if let chipset { rows.append((L("Chipset"), chipset)) }
        if let firmware { rows.append((L("Firmware"), firmware)) }
        if let transport { rows.append((L("Transport"), transport)) }
        rows.append((L("Paired devices"), L("%lld connected, %lld not connected", connected, notConnected)))
        return rows
    }
}

/// Counts advertising Bluetooth LE devices nearby. Main thread; `onChange` on updates.
public final class BluetoothScan: NSObject, CBCentralManagerDelegate {
    public enum State { case idle, scanning, finished, unauthorized, off }

    public private(set) var state = State.idle
    public private(set) var devices = 0
    public private(set) var strongest: Int?
    public var onChange: (() -> Void)?

    private var manager: CBCentralManager?
    private var seen: Set<UUID> = []
    private var duration = 10.0
    private var timer: Timer?

    public override init() {
        super.init()
    }

    public func scan(seconds: Double) {
        duration = seconds
        seen = []
        devices = 0
        strongest = nil
        state = .scanning
        if let manager, manager.state == .poweredOn {
            begin()
        } else if manager == nil {
            manager = CBCentralManager(delegate: self, queue: .main) // asks for permission the first time
        }
        onChange?()
    }

    private func begin() {
        manager?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        timer?.invalidate()
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            guard let self else { return }
            manager?.stopScan()
            state = .finished
            onChange?()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        manager?.stopScan()
        if state == .scanning { state = .idle }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: if state == .scanning { begin() }
        case .unauthorized: state = .unauthorized
        case .poweredOff: state = .off
        default: break
        }
        onChange?()
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        var changed = false
        if seen.insert(peripheral.identifier).inserted {
            devices = seen.count
            changed = true
        }
        let rssi = RSSI.intValue
        if rssi < 0 && rssi > (strongest ?? -200) {
            strongest = rssi
            changed = true
        }
        if changed { onChange?() }
    }

    public var summary: String {
        var parts = [L("%lld devices nearby", devices)]
        if let strongest {
            parts.append(L("strongest %@", Format.decibels(Double(strongest), unit: "dBm")))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Ports

public enum PortText {
    public static func name(_ port: PortStatus) -> String {
        "\(port.type) \(port.number)"
    }

    /// "USB 3, DisplayPort · charging the Mac (96 W)"; empty for ports read from the XHCI
    /// root hub (no transports: the devices below tell what is plugged in).
    public static func activity(_ port: PortStatus) -> String {
        var text = port.activeTransports.map(transport).joined(separator: ", ")
        if port.powerIn == true {
            text += (text.isEmpty ? "" : " · ") + L("charging the Mac")
            if let watts = port.controller?.maxPowerWatts { text += " (\(Format.watts(watts)))" }
        }
        return text
    }

    public static func transport(_ t: String) -> String {
        switch t {
        case "CC": return L("cable detected")
        case "USB2": return "USB 2"
        case "USB3": return "USB 3"
        case "CIO": return "Thunderbolt / USB4"
        case "DisplayPort": return "DisplayPort"
        default: return t
        }
    }

    public static func seenSummary(_ seen: Set<String>) -> String {
        guard !seen.isEmpty else { return L("nothing yet") }
        let order = ["USB2", "USB3", "USB", "CIO", "DisplayPort", "power"]
        var parts: [String] = []
        for key in order where seen.contains(key) {
            if key == "USB", seen.contains("USB2") || seen.contains("USB3") { continue }
            parts.append(key == "power" ? L("charging") : key == "USB" ? "USB" : transport(key))
        }
        return parts.joined(separator: ", ")
    }

    public static func slowLane(_ s: (device: String, here: Int, elsewhere: Int)) -> String {
        L("%1$@ linked at %2$@ here but at %3$@ in another port: this port's USB 3 lane may be faulty (pins, connector, redriver), or the plug was not fully in.",
          s.device, speed(s.here), speed(s.elsewhere))
    }

    public static func speed(_ megabits: Int) -> String {
        megabits >= 1000 ? Format.number(Double(megabits) / 1000) + "\u{00A0}Gb/s"
            : Format.number(Double(megabits)) + "\u{00A0}Mb/s"
    }
}

/// Remembers per port which transports and power were seen during this session.
public struct PortHistory {
    public private(set) var seen: [String: Set<String>] = [:]

    /// Highest link speed (Mb/s) per USB device ("vendor:product"), on any port and per port.
    public private(set) var fastest: [String: Int] = [:]
    public private(set) var fastestOnPort: [String: [String: Int]] = [:]
    /// Device names for the messages.
    private var names: [String: String] = [:]

    public init() {}

    /// Adds what the ports show now; true if anything new was seen.
    public mutating func update(_ ports: [PortStatus]) -> Bool {
        var changed = false
        for port in ports {
            var set = seen[port.id] ?? []
            let before = set
            set.formUnion(port.activeTransports.filter { $0 != "CC" })
            if port.powerIn == true { set.insert("power") }
            if !port.devices.isEmpty { set.insert("USB") }
            if set != before {
                seen[port.id] = set
                changed = true
            }
            for device in port.devices {
                guard let key = Self.key(device), let speed = device.megabitsPerSecond else { continue }
                names[key] = device.name
                if speed > fastest[key] ?? 0 { fastest[key] = speed; changed = true }
                if speed > fastestOnPort[port.id]?[key] ?? 0 { fastestOnPort[port.id, default: [:]][key] = speed; changed = true }
            }
        }
        return changed
    }

    static func key(_ device: USBDeviceInfo) -> String? {
        guard let vendor = device.vendorID, let product = device.productID else { return nil }
        return "\(vendor):\(product)"
    }

    /// A device that linked at USB 3 speed on another port but only at USB 2 speed on this one:
    /// the port's USB 3 lane (pins, connector, redriver) may be faulty, or the plug was not fully in.
    public func slowLane(_ port: PortStatus) -> (device: String, here: Int, elsewhere: Int)? {
        for (key, here) in fastestOnPort[port.id] ?? [:] {
            if here <= 480, let best = fastest[key], best >= 5_000 {
                return (names[key] ?? L("USB device"), here, best)
            }
        }
        return nil
    }

    public func detail(_ ports: [PortStatus]) -> String {
        ports.map { port in
            "\(PortText.name(port)): " + PortText.seenSummary(seen[port.id] ?? [])
                + (slowLane(port) != nil ? " (" + L("USB 2 speed only") + ")" : "")
        }.joined(separator: " · ")
    }

    /// Every data port was tested and none linked a USB 3 device at USB 2 speed only.
    public func passed(_ ports: [PortStatus]) -> Bool {
        allDataTested(ports) && ports.allSatisfy { slowLane($0) == nil }
    }

    /// Every USB-C / USB-A port carried data at least once.
    public func allDataTested(_ ports: [PortStatus]) -> Bool {
        let data = ports.filter { $0.type == "USB-C" || $0.type == "USB-A" }
        return !data.isEmpty && data.allSatisfy { !(seen[$0.id] ?? []).subtracting(["power"]).isEmpty }
    }
}

// MARK: - Lid

/// Polls `AppleClamshellState` and checks the sleep reason after a wake: closing the
/// lid normally puts the Mac to sleep before a poll can see it.
public final class LidWatcher {
    public private(set) var closed: Bool?
    public private(set) var detected: String?
    public var onChange: (() -> Void)?

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var closedAtSleep = false

    public init() {}

    public func start() {
        guard timer == nil else { return }
        closed = LidSensor.isClosed()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.closedAtSleep = LidSensor.isClosed() == true
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkAfterWake()
        })
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
    }

    private func poll() {
        let now = LidSensor.isClosed()
        var changed = now != closed
        if now == true, closed == false, detected == nil {
            detected = L("Lid closing detected at %@", Format.timeWithSeconds(Date()))
            changed = true
        }
        closed = now
        if changed { onChange?() }
    }

    private func checkAfterWake() {
        let wasClosed = closedAtSleep
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let reason = LidSensor.lastSleepReason(within: 3600)
            DispatchQueue.main.async {
                guard let watcher = self else { return }
                if wasClosed || reason?.localizedCaseInsensitiveContains("clamshell") == true {
                    watcher.detected = L("Lid close and open detected (woke at %@)", Format.timeWithSeconds(Date()))
                }
                watcher.closed = LidSensor.isClosed()
                watcher.onChange?()
            }
        }
    }
}
