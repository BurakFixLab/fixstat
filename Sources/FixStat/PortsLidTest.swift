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
    @State private var volumes: [USBVolume] = []
    @State private var speed = USBSpeedTestModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if ports.isEmpty {
                Text("This Mac does not publish its port state (IOPort). Check the ports by hand.")
                    .foregroundStyle(.secondary)
            }
            ForEach(ports) { port in
                portCard(port)
            }
            speedCard
        }
        .task {
            while !Task.isCancelled {
                let (current, mounted) = await Task.detached { (PortReader.read(), USBVolumes.mounted()) }.value
                if mounted != volumes { volumes = mounted }
                update(current)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func update(_ current: [PortStatus]) {
        ports = current
        guard history.update(current) else { return }
        recordCheck()
    }

    private func recordCheck() {
        let speeds = monitor.usbSpeedResults
        monitor.recordCheck(.ports, detail: history.detail(ports, speeds: speeds), passed: history.passed(ports, speeds: speeds))
    }

    // MARK: Drive speed

    private var speedCard: some View {
        Card {
            CardHeader("USB drive speed", systemImage: "speedometer")
            Text("Writes 256 MB to the free space of a USB drive, reads it back and compares every byte; the drive's files are not touched. Test the same drive in each port: a port that is clearly slower or gives errors points to its connector or USB 3 lane.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if volumes.isEmpty {
                Text("Plug in a USB memory stick or SSD to test the ports' speed.").foregroundStyle(.secondary)
            }
            ForEach(volumes, id: \.bsdName) { volume in
                volumeRow(volume)
            }
            if speed.running {
                HStack {
                    ProgressView(value: speed.fraction) {
                        Text(speed.phase == .write ? "Writing…" : "Reading and verifying…").font(.caption)
                    }
                    Button("Stop", role: .cancel) { speed.stop() }
                }
            }
            let results = monitor.usbSpeedResults
            if !results.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow {
                        ForEach(USBSpeedText.header, id: \.self) { Text(verbatim: $0).foregroundStyle(.secondary) }
                    }
                    ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                        GridRow {
                            ForEach(Array(USBSpeedText.row(result).enumerated()), id: \.offset) { _, cell in
                                Text(verbatim: cell)
                            }
                        }
                    }
                }
                .font(.callout)
                .padding(.top, 4)
                ForEach(Array(USBSpeedText.findings(results).enumerated()), id: \.offset) { _, finding in
                    FindingRow(text: finding)
                }
            }
        }
        .onAppear { speed.onFinish = { recordCheck() } }
    }

    private func volumeRow(_ volume: USBVolume) -> some View {
        let port = volume.port(in: ports)
        let details = [port.map(PortText.name), volume.device.name, volume.device.megabitsPerSecond.map(PortText.speed),
                       String(localized: "\(Format.bytes(Double(volume.availableBytes))) free")].compactMap { $0 }
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: volume.name)
                Text(verbatim: details.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if USBSpeedRunner.hasSpace(volume) {
                Button("Test speed") { speed.start(volume, port: port, monitor: monitor) }
                    .disabled(speed.running)
            } else {
                Text("not enough free space").font(.callout).foregroundStyle(.secondary)
            }
        }
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
        .background(Design.cardFill, in: RoundedRectangle(cornerRadius: Design.cardRadius))
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

/// SwiftUI view of the core `USBSpeedRunner`.
@available(macOS 14.0, *)
@MainActor
@Observable
final class USBSpeedTestModel {
    private(set) var running = false
    private(set) var fraction = 0.0
    private(set) var phase = SSDStressTest.Phase.write

    @ObservationIgnored private var runner: USBSpeedRunner?
    @ObservationIgnored var onFinish: (() -> Void)?

    func start(_ volume: USBVolume, port: PortStatus?, monitor: Monitor) {
        let runner = self.runner ?? USBSpeedRunner(monitor: monitor.core)
        self.runner = runner
        runner.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync(monitor) }
        }
        runner.start(volume, port: port)
    }

    func stop() { runner?.stop() }

    private func sync(_ monitor: Monitor) {
        guard let runner else { return }
        let nowRunning = runner.state == .running
        fraction = runner.fraction
        if runner.phase != phase { phase = runner.phase }
        if nowRunning != running {
            running = nowRunning
            if !nowRunning {
                // The core appended the result; let the views observe it.
                monitor.usbSpeedResults = monitor.core.usbSpeedResults
                onFinish?()
            }
        }
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
