import CoreBluetooth
import CoreWLAN
import MacSensors
import SwiftUI

// MARK: - Wi-Fi

struct WiFiTestView: View {
    @Environment(Monitor.self) private var monitor
    @State private var link: WiFiLink?
    @State private var scan: WiFiScan?
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let link {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                    row("Interface", [link.interface, link.powerOn ? String(localized: "on") : String(localized: "off")]
                        .joined(separator: " · "))
                    if link.connected {
                        row("Signal", Format.decibels(Double(link.rssi), unit: "dBm")
                            + " · " + String(localized: "noise \(Format.decibels(Double(link.noise), unit: "dBm"))"))
                        row("Signal-to-noise", Format.decibels(Double(link.rssi - link.noise), unit: "dB"))
                        row("Transmit rate", Format.number(link.transmitRate) + "\u{00A0}Mb/s")
                        if let channel = link.channel { row("Channel", channel) }
                        if let phy = link.phyMode { row("Standard", phy) }
                    } else {
                        row("Signal", String(localized: "not connected"))
                    }
                }
                .font(.callout)
            } else {
                Text("No Wi-Fi interface found.").foregroundStyle(TemperatureColor.hot)
            }
            HStack {
                Button {
                    runScan()
                } label: {
                    Label(scanning ? "Scanning…" : "Scan for networks", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(scanning || link?.powerOn != true)
                if let scan {
                    Text(scanSummary(scan)).font(.callout)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                link = WiFiLink.read()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(verbatim: value)
        }
    }

    private func scanSummary(_ scan: WiFiScan) -> String {
        var parts = [String(localized: "\(scan.count) networks")]
        if let strongest = scan.strongest {
            parts.append(String(localized: "strongest \(Format.decibels(Double(strongest), unit: "dBm"))"))
        }
        if !scan.bands.isEmpty { parts.append(scan.bands.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func runScan() {
        scanning = true
        Task {
            let result = await Task.detached { WiFiScan.run() }.value
            scan = result
            scanning = false
            if let result {
                monitor.recordCheck(.wifi, detail: scanSummary(result), passed: result.count > 0 && link?.connected == true)
            }
        }
    }
}

struct WiFiLink {
    let interface: String
    let powerOn: Bool
    let connected: Bool
    let rssi: Int
    let noise: Int
    let transmitRate: Double
    let channel: String?
    let phyMode: String?

    static func read() -> WiFiLink? {
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
        case .width20MHz: "20 MHz"
        case .width40MHz: "40 MHz"
        case .width80MHz: "80 MHz"
        case .width160MHz: "160 MHz"
        default: "–"
        }
    }

    private static func phy(_ mode: CWPHYMode) -> String? {
        switch mode {
        case .mode11a: "802.11a"
        case .mode11b: "802.11b"
        case .mode11g: "802.11g"
        case .mode11n: "802.11n (Wi-Fi 4)"
        case .mode11ac: "802.11ac (Wi-Fi 5)"
        case .mode11ax: "802.11ax (Wi-Fi 6)"
        default: nil
        }
    }
}

/// Nearby networks. Without Location permission macOS hides the names, which are
/// not needed here: the count and signal strengths test the radio and antennas.
struct WiFiScan: Sendable {
    let count: Int
    let strongest: Int?
    let bands: [String]

    static func run() -> WiFiScan? {
        guard let i = CWWiFiClient.shared().interface(),
              let networks = try? i.scanForNetworks(withName: nil) else { return nil }
        let bands = Set(networks.compactMap { $0.wlanChannel?.channelBand })
        return WiFiScan(count: networks.count, strongest: networks.map(\.rssiValue).max(),
                        bands: bands.sorted { $0.rawValue < $1.rawValue }.compactMap(band))
    }

    static func band(_ band: CWChannelBand) -> String? {
        switch band {
        case .band2GHz: "2.4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: nil
        }
    }
}

// MARK: - Bluetooth

struct BluetoothTestView: View {
    @Environment(Monitor.self) private var monitor
    @State private var controller: BluetoothController?
    @State private var scanner = BluetoothScanner()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let controller {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                    row("State", controller.on ? String(localized: "on") : String(localized: "off"))
                    if let chip = controller.chipset { row("Chipset", chip) }
                    if let firmware = controller.firmware { row("Firmware", firmware) }
                    if let transport = controller.transport { row("Transport", transport) }
                    row("Paired devices", String(localized: "\(controller.connected) connected, \(controller.notConnected) not connected"))
                }
                .font(.callout)
            } else {
                ProgressView().controlSize(.small)
            }
            if scanner.state == .unauthorized {
                Label("FixStat has no Bluetooth access. Allow it in System Settings › Privacy & Security › Bluetooth.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(TemperatureColor.hot)
            }
            HStack {
                Button {
                    scanner.scan(seconds: 10)
                } label: {
                    Label(scanner.state == .scanning ? "Scanning…" : "Scan for devices",
                          systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(scanner.state == .scanning)
                if scanner.state == .scanning || scanner.state == .finished {
                    Text(summary).font(.callout)
                }
            }
        }
        .task {
            controller = await Task.detached { BluetoothController.read() }.value
        }
        .onDisappear { scanner.stop() }
        .onChange(of: scanner.state) { _, state in
            guard state == .finished else { return }
            monitor.recordCheck(.bluetooth, detail: ([controller?.chipset].compactMap { $0 } + [summary])
                .joined(separator: " · "), passed: scanner.devices > 0)
        }
    }

    private var summary: String {
        var parts = [String(localized: "\(scanner.devices) devices nearby")]
        if let strongest = scanner.strongest {
            parts.append(String(localized: "strongest \(Format.decibels(Double(strongest), unit: "dBm"))"))
        }
        return parts.joined(separator: " · ")
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(verbatim: value)
        }
    }
}

/// Controller facts from `system_profiler SPBluetoothDataType -json` (no permission
/// needed; the controller address is not read).
struct BluetoothController: Sendable {
    let on: Bool
    let chipset: String?
    let firmware: String?
    let transport: String?
    let connected: Int
    let notConnected: Int

    static func read() -> BluetoothController? {
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
              let root = (json["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let c = root["controller_properties"] as? [String: Any] else { return nil }
        let connected = (root["device_connected"] as? [Any])?.count ?? 0
        let notConnected = (root["device_not_connected"] as? [Any])?.count ?? 0
        return BluetoothController(on: (c["controller_state"] as? String) == "attrib_on",
                                   chipset: c["controller_chipset"] as? String,
                                   firmware: c["controller_firmwareVersion"] as? String,
                                   transport: c["controller_transport"] as? String,
                                   connected: connected, notConnected: notConnected)
    }
}

/// Counts advertising Bluetooth LE devices nearby.
@MainActor
@Observable
final class BluetoothScanner: NSObject, CBCentralManagerDelegate {
    enum State { case idle, scanning, finished, unauthorized, off }

    private(set) var state = State.idle
    private(set) var devices = 0
    private(set) var strongest: Int?

    @ObservationIgnored private var manager: CBCentralManager?
    @ObservationIgnored private var seen: Set<UUID> = []
    @ObservationIgnored private var duration = 10.0
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    func scan(seconds: Double) {
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
    }

    private func begin() {
        manager?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        stopTask?.cancel()
        stopTask = Task { [weak self, duration] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.manager?.stopScan()
            self?.state = .finished
        }
    }

    func stop() {
        stopTask?.cancel()
        manager?.stopScan()
        if state == .scanning { state = .idle }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let value = central.state
        MainActor.assumeIsolated {
            switch value {
            case .poweredOn: if state == .scanning { begin() }
            case .unauthorized: state = .unauthorized
            case .poweredOff: state = .off
            default: break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            if seen.insert(id).inserted { devices = seen.count }
            if rssi < 0 && rssi > (strongest ?? -200) { strongest = rssi }
        }
    }
}
