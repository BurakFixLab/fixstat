import AppKit
import MacSensors
import SwiftUI

/// Hardware checklist window: one test per component, each marked passed / failed /
/// skipped by the technician. Tests that measure something fill in the evidence and
/// mark the item passed on their own; the technician can always override.
struct HardwareCheckView: View {
    static let windowID = "hardware-check"

    @Environment(Monitor.self) private var monitor
    @State private var selection: HardwareCheck.Item?

    init(initialItem: HardwareCheck.Item = .keyboard) {
        _selection = State(initialValue: initialItem)
    }

    var body: some View {
        NavigationSplitView {
            List(HardwareCheck.Item.allCases, id: \.self, selection: $selection) { item in
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
            .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 260)
        } detail: {
            if let selection {
                CheckDetail(item: selection)
                    .id(selection)
            }
        }
        .frame(minWidth: 860, minHeight: 620)
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
                Button("Reset") { monitor.hardwareCheck = HardwareCheck() }
                    .disabled(check.isEmpty)
                Spacer()
                ExportMenu()
            }
        }
        .padding([.horizontal, .bottom], 12)
    }
}

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
                case .speakers: SpeakerTestView()
                case .microphone: MicrophoneTestView()
                case .camera: CameraTestView()
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

extension Monitor {
    /// Stores measured evidence; marks the item passed if `passed` and nothing was
    /// marked yet (the technician's own choice is never overridden).
    func recordCheck(_ item: HardwareCheck.Item, detail: String, passed: Bool = false) {
        hardwareCheck[item].detail = detail
        if passed, hardwareCheck[item].status == .untested {
            hardwareCheck[item].status = .passed
            hardwareCheck[item].date = Date()
        }
    }
}

enum HardwareText {
    static func title(_ item: HardwareCheck.Item) -> String {
        switch item {
        case .keyboard: String(localized: "Keyboard")
        case .trackpad: String(localized: "Trackpad")
        case .display: String(localized: "Display")
        case .speakers: String(localized: "Speakers")
        case .microphone: String(localized: "Microphone")
        case .camera: String(localized: "Camera")
        case .wifi: String(localized: "Wi-Fi")
        case .bluetooth: String(localized: "Bluetooth")
        case .ports: String(localized: "Ports")
        case .lid: String(localized: "Lid sensor")
        }
    }

    static func symbol(_ item: HardwareCheck.Item) -> String {
        switch item {
        case .keyboard: "keyboard"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .display: "display"
        case .speakers: "speaker.wave.2"
        case .microphone: "mic"
        case .camera: "camera"
        case .wifi: "wifi"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .ports: "cable.connector"
        case .lid: "laptopcomputer"
        }
    }

    static func instructions(_ item: HardwareCheck.Item) -> String {
        switch item {
        case .keyboard:
            String(localized: "Press every key. A key turns blue once it registers; a key that stays grey did not respond. Hold fn for the top row, otherwise macOS uses those keys itself. Touch ID / power cannot be tested here.")
        case .trackpad:
            String(localized: "Run a finger over the whole trackpad surface; the pointer can be anywhere. Cells that stay empty did not register touches. Then click once in each of the nine zones and secondary-click (two fingers) in each zone, keeping the pointer in this window. Also force click, scroll and pinch.")
        case .display:
            String(localized: "Shows solid colours full screen on the built-in display to spot dead or stuck pixels, lines, stains and backlight bleed. Click or press → for the next colour, ← to go back, esc to end.")
        case .speakers:
            String(localized: "Plays test tones on the left and right speaker. The sweep runs from low to high frequencies and reveals rattling or distorted speakers.")
        case .microphone:
            String(localized: "Speak or tap near the microphones and watch the level. Record a few seconds and play them back to judge the sound.")
        case .camera:
            String(localized: "Shows the built-in camera image. Check sharpness, colours and that the green camera light turns on.")
        case .wifi:
            String(localized: "Shows the Wi-Fi link and scans for nearby networks. A weak signal next to the router or few networks can point to an antenna or cable problem.")
        case .bluetooth:
            String(localized: "Shows the Bluetooth controller and scans for nearby devices for ten seconds. Finding no devices in a busy room points to an antenna problem.")
        case .ports:
            String(localized: "Plug a USB device, a charger or a display into each port in turn. Every port should show a data connection; charging ports should show power in.")
        case .lid:
            String(localized: "Close the lid until the Mac sleeps, then open it again. FixStat detects the closing through the lid (Hall) sensor.")
        }
    }

    static func status(_ status: HardwareCheck.Status) -> String {
        switch status {
        case .untested: String(localized: "Not tested")
        case .passed: String(localized: "Passed")
        case .failed: String(localized: "Failed")
        case .skipped: String(localized: "Skipped")
        }
    }
}
