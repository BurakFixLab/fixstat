import AppKit
import MacSensors
import SwiftUI
import FixStatCore

/// Hardware checklist window: one test per component, each marked passed / failed /
/// skipped by the technician. Tests that measure something fill in the evidence and
/// mark the item passed on their own; the technician can always override.
@available(macOS 14.0, *)
struct HardwareCheckView: View {
    static let windowID = "hardware-check"

    @Environment(Monitor.self) private var monitor
    @State private var selection: HardwareCheck.Item?

    /// nil: the first item that applies to this Mac.
    init(initialItem: HardwareCheck.Item? = nil) {
        _selection = State(initialValue: initialItem)
    }

    var body: some View {
        let items = monitor.hardwareCheck.items
        NavigationSplitView {
            List(items, id: \.self, selection: $selection) { item in
                HStack(spacing: 8) {
                    Image(systemName: HardwareText.symbol(item))
                        .frame(width: 20)
                        .foregroundStyle(.secondary)
                    Text(HardwareText.title(item))
                    Spacer()
                    StatusIcon(status: monitor.hardwareCheck[item].status)
                }
                .padding(.vertical, 2)
            }
            .safeAreaInset(edge: .bottom) { summary }
            .navigationSplitViewColumnWidth(min: 240, ideal: 250, max: 300)
        } detail: {
            if let selection {
                CheckDetail(item: selection)
                    .id(selection)
            }
        }
        .frame(minWidth: 860, minHeight: 620)
        .onAppear {
            if selection.map(items.contains) != true { selection = items.first }
        }
    }

    private var summary: some View {
        let check = monitor.hardwareCheck
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("\(check.count(.passed)) passed · \(check.count(.failed)) failed · \(check.count(.untested)) not tested")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack {
                Button("Reset") { monitor.resetHardwareCheck() }
                    .disabled(check.isEmpty)
                    .fixedSize()
                Spacer()
                ExportMenu()
            }
        }
        .padding([.horizontal, .bottom], 12)
    }
}

@available(macOS 14.0, *)
struct StatusIcon: View {
    let status: HardwareCheck.Status

    var body: some View {
        switch status {
        case .untested:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(TemperatureColor.cool)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(TemperatureColor.hot)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

/// Title, instructions, the test itself and the result bar.
@available(macOS 14.0, *)
private struct CheckDetail: View {
    let item: HardwareCheck.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(HardwareText.title(item)).font(.title2.weight(.semibold))
            Text(HardwareText.instructions(item))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            Group {
                switch item {
                case .keyboard: KeyboardTestView()
                case .trackpad: TrackpadTestView()
                case .display: DisplayTestView()
                case .ambientLight: AmbientLightTestView()
                case .speakers: SpeakerTestView()
                case .microphone: MicrophoneTestView()
                case .camera: CameraTestView()
                case .fans: FanTestView()
                case .wifi: WiFiTestView()
                case .bluetooth: BluetoothTestView()
                case .ports: PortsTestView()
                case .lid: LidTestView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            ResultBar(item: item)
        }
        .padding(20)
        .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .monospacedDigit()
    }
}

/// Passed / Failed / Skipped buttons, the measured evidence and a note.
@available(macOS 14.0, *)
private struct ResultBar: View {
    let item: HardwareCheck.Item
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let entry = monitor.hardwareCheck[item]
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if let detail = entry.detail {
                Label(detail, systemImage: "gauge.with.dots.needle.33percent")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                mark("Passed", "checkmark", .passed, entry)
                mark("Failed", "xmark", .failed, entry)
                mark("Skipped", "minus", .skipped, entry)
                TextField("Note", text: Binding(
                    get: { monitor.hardwareCheck[item].note },
                    set: { monitor.hardwareCheck[item].note = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func mark(_ title: LocalizedStringKey, _ symbol: String, _ status: HardwareCheck.Status,
                      _ entry: HardwareCheck.Entry) -> some View {
        Button {
            monitor.hardwareCheck[item].status = entry.status == status ? .untested : status
            monitor.hardwareCheck[item].date = Date()
        } label: {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.bordered)
        .tint(entry.status == status ? (status == .failed ? TemperatureColor.hot : TemperatureColor.cool) : nil)
        .background(entry.status == status ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6))
    }
}

@available(macOS 14.0, *)
extension Monitor {
    /// Stores measured evidence; marks the item passed (or failed, for a clear measured fault)
    /// if nothing was marked yet (the technician's own choice is never overridden).
    func recordCheck(_ item: HardwareCheck.Item, detail: String, passed: Bool = false, failed: Bool = false) {
        hardwareCheck[item].detail = detail
        if passed || failed, hardwareCheck[item].status == .untested {
            hardwareCheck[item].status = passed ? .passed : .failed
            hardwareCheck[item].date = Date()
        }
    }
}
