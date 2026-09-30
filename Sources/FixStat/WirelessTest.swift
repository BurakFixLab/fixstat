import CoreBluetooth
import CoreWLAN
import MacSensors
import SwiftUI
import FixStatCore

// MARK: - Wi-Fi

@available(macOS 14.0, *)
struct WiFiTestView: View {
    @Environment(Monitor.self) private var monitor
    @State private var link: WiFiLink?
    @State private var scan: WiFiScan?
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let link {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                    ForEach(Array(link.rows.enumerated()), id: \.offset) { _, r in row(r.0, r.1) }
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
                    Text(verbatim: scan.summary).font(.callout)
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

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(verbatim: title).foregroundStyle(.secondary)
            Text(verbatim: value)
        }
    }

    private func runScan() {
        scanning = true
        Task {
            let result = await Task.detached { WiFiScan.run() }.value
            scan = result
            scanning = false
            if let result {
                monitor.recordCheck(.wifi, detail: result.summary, passed: result.count > 0 && link?.connected == true)
            }
        }
    }
}

// MARK: - Bluetooth

@available(macOS 14.0, *)
struct BluetoothTestView: View {
    @Environment(Monitor.self) private var monitor
    @State private var controller: BluetoothController?
    @State private var scanner = BluetoothScanner()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let controller {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                    ForEach(Array(controller.rows.enumerated()), id: \.offset) { _, r in row(r.0, r.1) }
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

    private var summary: String { scanner.summary }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(verbatim: title).foregroundStyle(.secondary)
            Text(verbatim: value)
        }
    }
}

/// SwiftUI view of the core `BluetoothScan`.
@available(macOS 14.0, *)
@MainActor
@Observable
final class BluetoothScanner {
    typealias State = BluetoothScan.State

    private(set) var state = State.idle
    private(set) var devices = 0
    private(set) var strongest: Int?

    @ObservationIgnored private let scan = BluetoothScan()

    init() {
        scan.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    var summary: String { scan.summary }

    func scan(seconds: Double) { scan.scan(seconds: seconds) }
    func stop() {
        scan.stop()
        sync()
    }

    private func sync() {
        if scan.state != state { state = scan.state }
        if scan.devices != devices { devices = scan.devices }
        if scan.strongest != strongest { strongest = scan.strongest }
    }
}
