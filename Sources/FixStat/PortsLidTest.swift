import AppKit
import MacSensors
import SwiftUI
import FixStatCore

// MARK: - Ports

@available(macOS 14.0, *)
struct PortsTestView: View {
    @Environment(Monitor.self) private var monitor
    @State private var ports: [PortStatus] = []
    /// Per port: data transports and power seen during this session.
    @State private var seen: [String: Set<String>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if ports.isEmpty {
                Text("This Mac does not publish its port state (IOPort). Check the ports by hand.")
                    .foregroundStyle(.secondary)
            }
            ForEach(ports) { port in
                portCard(port)
            }
        }
        .task {
            while !Task.isCancelled {
                let current = await Task.detached { PortReader.read() }.value
                update(current)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func update(_ current: [PortStatus]) {
        ports = current
        var changed = false
        for port in current {
            var set = seen[port.id] ?? []
            let before = set
            set.formUnion(port.activeTransports.filter { $0 != "CC" })
            if port.powerIn == true { set.insert("power") }
            if !port.devices.isEmpty { set.insert("USB") }
            if set != before { seen[port.id] = set; changed = true }
        }
        guard changed else { return }
        let detail = current.map { port in
            "\(PortText.name(port)): " + PortText.seenSummary(seen[port.id] ?? [])
        }.joined(separator: " · ")
        let usbC = current.filter { $0.type == "USB-C" }
        let allData = !usbC.isEmpty && usbC.allSatisfy { !(seen[$0.id] ?? []).subtracting(["power"]).isEmpty }
        monitor.recordCheck(.ports, detail: detail, passed: allData)
    }

    private func portCard(_ port: PortStatus) -> some View {
        let history = seen[port.id] ?? []
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: port.connected ? "cable.connector" : "cable.connector.slash")
                    .foregroundStyle(port.connected ? AnyShapeStyle(TemperatureColor.cool) : AnyShapeStyle(.secondary))
                Text(verbatim: PortText.name(port)).font(.headline)
                Text(port.connected ? "Connected" : "Empty").foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: String(localized: "Tested: ") + PortText.seenSummary(history))
                    .font(.callout)
                    .foregroundStyle(history.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(TemperatureColor.cool))
            }
            if port.connected {
                Text(verbatim: port.activeTransports.map(PortText.transport).joined(separator: ", ")
                     + (port.powerIn == true ? " · " + String(localized: "charging the Mac") : "")
                     + (port.powerIn == true ? port.controller?.maxPowerWatts.map { " (\(Format.watts($0)))" } ?? "" : ""))
                    .font(.callout)
            }
            ForEach(Array(port.devices.enumerated()), id: \.offset) { _, device in
                Text(verbatim: "• " + (device.name ?? String(localized: "USB device"))
                     + (device.megabitsPerSecond.map { " · " + PortText.speed($0) } ?? ""))
                    .font(.callout)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 16) {
                    if let count = port.overcurrentCount {
                        counter("Overcurrent", count)
                    }
                    if let count = port.enumerationFailures {
                        counter("USB enumeration failures", count)
                    }
                    if let count = port.connectionCount {
                        Text("Plug-ins since start: \(count)").foregroundStyle(.secondary)
                    }
                }
                if let c = port.controller {
                    HStack(spacing: 16) {
                        counter("Short circuit detections", c.shortDetect)
                        counter("PD hard resets", c.hardReset)
                        counter("Input FET failures", c.inputFETFailures)
                        counter("I²C errors", c.i2cErrors)
                    }
                }
            }
            .font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func counter(_ title: LocalizedStringKey, _ count: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text(verbatim: Format.number(Double(count)))
        }
        .foregroundStyle(count > 0 ? AnyShapeStyle(TemperatureColor.hot) : AnyShapeStyle(.secondary))
        .fontWeight(count > 0 ? .semibold : .regular)
    }
}

@available(macOS 14.0, *)
enum PortText {
    static func name(_ port: PortStatus) -> String {
        "\(port.type) \(port.number)"
    }

    static func transport(_ t: String) -> String {
        switch t {
        case "CC": String(localized: "cable detected")
        case "USB2": "USB 2"
        case "USB3": "USB 3"
        case "CIO": "Thunderbolt / USB4"
        case "DisplayPort": "DisplayPort"
        default: t
        }
    }

    static func seenSummary(_ seen: Set<String>) -> String {
        guard !seen.isEmpty else { return String(localized: "nothing yet") }
        let order = ["USB2", "USB3", "USB", "CIO", "DisplayPort", "power"]
        var parts: [String] = []
        for key in order where seen.contains(key) {
            if key == "USB", seen.contains("USB2") || seen.contains("USB3") { continue }
            parts.append(key == "power" ? String(localized: "charging") : key == "USB" ? "USB" : transport(key))
        }
        return parts.joined(separator: ", ")
    }

    static func speed(_ megabits: Int) -> String {
        megabits >= 1000 ? Format.number(Double(megabits) / 1000) + "\u{00A0}Gb/s"
            : Format.number(Double(megabits)) + "\u{00A0}Mb/s"
    }
}

// MARK: - Lid

@available(macOS 14.0, *)
struct LidTestView: View {
    @Environment(Monitor.self) private var monitor
    @State private var watcher = LidWatcher()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let closed = watcher.closed {
                Label(closed ? "Lid closed" : "Lid open", systemImage: closed ? "laptopcomputer.slash" : "laptopcomputer")
                    .font(.headline)
            } else {
                Text("This Mac has no lid sensor.").foregroundStyle(.secondary)
            }
            if let event = watcher.detected {
                Label(event, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(TemperatureColor.cool)
            } else {
                Text("Waiting for the lid to close…").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .onAppear { watcher.start() }
        .onDisappear { watcher.stop() }
        .onChange(of: watcher.detected) { _, event in
            if let event { monitor.recordCheck(.lid, detail: event, passed: true) }
        }
    }
}

/// Polls `AppleClamshellState` and checks the sleep reason after a wake: closing the
/// lid normally puts the Mac to sleep before a poll can see it.
@available(macOS 14.0, *)
@MainActor
@Observable
final class LidWatcher {
    private(set) var closed: Bool?
    private(set) var detected: String?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var closedAtSleep = false

    func start() {
        guard timer == nil else { return }
        closed = LidSensor.isClosed()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closedAtSleep = LidSensor.isClosed() == true }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAfterWake() }
        })
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
    }

    private func poll() {
        let now = LidSensor.isClosed()
        if now == true, closed == false, detected == nil {
            detected = String(localized: "Lid closing detected at \(Date().formatted(date: .omitted, time: .standard))")
        }
        closed = now
    }

    private func checkAfterWake() {
        let wasClosed = closedAtSleep
        Task {
            let reason = await Task.detached { LidSensor.lastSleepReason(within: 3600) }.value
            if wasClosed || reason?.localizedCaseInsensitiveContains("clamshell") == true {
                detected = String(localized: "Lid close and open detected (woke at \(Date().formatted(date: .omitted, time: .standard)))")
            }
            closed = LidSensor.isClosed()
        }
    }
}
