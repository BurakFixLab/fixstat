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
    @State private var history = PortHistory()

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
        guard history.update(current) else { return }
        monitor.recordCheck(.ports, detail: history.detail(current), passed: history.passed(current))
    }

    private func portCard(_ port: PortStatus) -> some View {
        let history = self.history.seen[port.id] ?? []
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
            if port.connected, !PortText.activity(port).isEmpty {
                Text(verbatim: PortText.activity(port)).font(.callout)
            }
            if let slow = self.history.slowLane(port) {
                Label(PortText.slowLane(slow), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(TemperatureColor.hot)
                    .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Lid

@available(macOS 14.0, *)
struct LidTestView: View {
    @Environment(Monitor.self) private var monitor
    @State private var watcher = LidWatcherModel()

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

/// SwiftUI view of the core `LidWatcher`.
@available(macOS 14.0, *)
@MainActor
@Observable
final class LidWatcherModel {
    private(set) var closed: Bool?
    private(set) var detected: String?

    @ObservationIgnored private let watcher = FixStatCore.LidWatcher()

    init() {
        watcher.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    func start() {
        watcher.start()
        sync()
    }

    func stop() { watcher.stop() }

    private func sync() {
        if watcher.closed != closed { closed = watcher.closed }
        if watcher.detected != detected { detected = watcher.detected }
    }
}
