import AppKit
import Carbon
import MacSensors
import SwiftUI
import FixStatCore

/// Keyboard test: draws the built-in keyboard and marks every key that registered.
@available(macOS 14.0, *)
struct KeyboardTestView: View {
    @Environment(Monitor.self) private var monitor
    @State private var pressed: Set<Int> = []
    @State private var held: Set<Int> = []
    @State private var eventMonitor: Any?
    @State private var tap = KeyTap()
    @State private var retry: Timer?

    private let kind = KeyLegend.kind
    private var total: Int { KeyboardLayout.codes(kind, touchBar: monitor.profile.touchBar).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyboardDrawing(kind: kind, touchBar: monitor.profile.touchBar, pressed: pressed, held: held)
                .frame(maxWidth: 720)
            HStack {
                Text(verbatim: KeyboardLayout.progress(pressed.count, of: total))
                    .font(.headline)
                Text(verbatim: KeyLegend.layoutName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset keys") {
                    pressed = []
                    held = []
                }
                .disabled(pressed.isEmpty)
            }
            tapNote
        }
        .onAppear(perform: install)
        .onDisappear(perform: remove)
    }

    /// Keys macOS takes for itself (Mission Control, Spotlight, Dictation, Do Not Disturb,
    /// volume …) only reach FixStat through an event tap, which needs Input Monitoring.
    @ViewBuilder
    private var tapNote: some View {
        switch tap.mode {
        case .none:
            HStack(alignment: .firstTextBaseline) {
                Label("Keys used by macOS (e.g. F3–F6 without fn) need the Input Monitoring permission.",
                      systemImage: "info.circle")
                Spacer()
                Button("Allow…") { KeyEventTap.requestAccess() }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .listenOnly:
            Label("All keys are detected. macOS still acts on its own keys (Mission Control, Spotlight …); allow FixStat under Accessibility to block that during the test.",
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .active:
            EmptyView()
        }
    }

    /// Only in the checklist window, and typing into the note field works normally.
    private static var testIsFocused: Bool {
        guard let window = NSApp.keyWindow,
              window.identifier?.rawValue.contains(HardwareCheckView.windowID) == true else { return false }
        return !(window.firstResponder is NSText)
    }

    private func install() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .systemDefined]) { event in
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard Self.testIsFocused else { return false }
                handle(event)
                return event.type == .keyDown || event.type == .keyUp // no shortcuts while testing
            }
            return swallow ? nil : event
        }
        tap.handler = { event in
            guard Self.testIsFocused else { return false }
            handle(event)
            // With an active tap, keep macOS from opening Mission Control, Spotlight, …
            return event.type == .keyDown || event.type == .keyUp
                || (event.type == .systemDefined && event.subtype.rawValue == 8)
        }
        startTap()
    }

    private func startTap() {
        tap.start()
        retry?.invalidate()
        retry = nil
        guard tap.mode == .none else { return }
        // Picks up the permission as soon as it is granted in System Settings.
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                tap.start()
                if tap.mode != .none { retry?.invalidate(); retry = nil }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retry = timer
    }

    private func remove() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        tap.stop()
        retry?.invalidate()
        retry = nil
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            register(KeyLegend.physicalCode(Int(event.keyCode)), down: true)
        case .keyUp:
            held.remove(KeyLegend.physicalCode(Int(event.keyCode)))
        case .flagsChanged:
            let code = Int(event.keyCode)
            guard let down = KeyLegend.isModifierDown(code, flags: event.modifierFlags) else { return }
            register(code, down: down)
        case .systemDefined:
            // Media keys (top row without fn): subtype 8, key type in data1's high word.
            guard event.subtype.rawValue == 8 else { return }
            let keyType = (event.data1 & 0xFFFF_0000) >> 16
            let state = (event.data1 & 0xFF00) >> 8
            guard let code = KeyLegend.mediaKeyCodes[keyType] else { return }
            register(code, down: state == 0x0A)
        default:
            break
        }
    }

    private func register(_ code: Int, down: Bool) {
        guard KeyboardLayout.codes(kind, touchBar: monitor.profile.touchBar).contains(code) else { return }
        if down {
            held.insert(code)
            if pressed.insert(code).inserted {
                monitor.recordCheck(.keyboard, detail: KeyboardLayout.progress(pressed.count, of: total),
                                    passed: pressed.count == total)
            }
        } else {
            held.remove(code)
        }
    }
}

/// SwiftUI view of the core `KeyEventTap` (mode is observed).
@available(macOS 14.0, *)
@MainActor
@Observable
final class KeyTap {
    typealias Mode = KeyEventTap.Mode

    private(set) var mode = Mode.none
    @ObservationIgnored private let tap = KeyEventTap()

    /// Returns true to block the event (active tap only).
    var handler: ((NSEvent) -> Bool)? {
        get { tap.handler }
        set { tap.handler = newValue }
    }

    func start() {
        tap.start()
        if tap.mode != mode { mode = tap.mode }
    }

    func stop() {
        tap.stop()
        if tap.mode != mode { mode = tap.mode }
    }
}

/// Draws the keyboard rows, 14.5 units wide.
@available(macOS 14.0, *)
struct KeyboardDrawing: View {
    let kind: KeyboardLayout.Kind
    let touchBar: HardwareProfile.TouchBar?
    let pressed: Set<Int>
    let held: Set<Int>
    @State private var legends = KeyLegend.legends()

    var body: some View {
        GeometryReader { proxy in
            let unit = proxy.size.width / 14.5
            let gap = unit * 0.1
            VStack(spacing: gap) {
                ForEach(Array(KeyboardLayout.rows(kind, touchBar: touchBar).enumerated()), id: \.offset) { index, row in
                    rowView(row, unit: unit, gap: gap, height: (index == 0 ? 0.55 : 0.9) * unit)
                }
            }
        }
        .aspectRatio(14.5 / 5.65, contentMode: .fit)
        .onReceive(NotificationCenter.default.publisher(for: NSTextInputContext.keyboardSelectionDidChangeNotification)) { _ in
            legends = KeyLegend.legends()
        }
    }

    private func rowView(_ row: [KeyboardLayout.Key], unit: CGFloat, gap: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(groups(row), id: \.first!.code) { group in
                if group.count == 2 {
                    VStack(spacing: gap / 2) {
                        ForEach(group, id: \.code) { key in
                            keyView(key, width: unit - gap, height: (height - gap / 2) / 2)
                        }
                    }
                } else {
                    keyView(group[0], width: group[0].width * unit - gap, height: height)
                }
            }
        }
    }

    /// Stacks consecutive half-height keys (Up/Down) into one column.
    private func groups(_ row: [KeyboardLayout.Key]) -> [[KeyboardLayout.Key]] {
        var result: [[KeyboardLayout.Key]] = []
        for key in row {
            if key.halfHeight, let last = result.last, last.count == 1, last[0].halfHeight {
                result[result.count - 1].append(key)
            } else {
                result.append([key])
            }
        }
        return result
    }

    private func keyView(_ key: KeyboardLayout.Key, width: CGFloat, height: CGFloat) -> some View {
        let isPlaceholder = key.code < 0 // Touch ID, Touch Bar
        let isPressed = pressed.contains(key.code)
        let isHeld = held.contains(key.code)
        let legend = key.legend ?? legends[key.code] ?? ""
        return RoundedRectangle(cornerRadius: 4)
            .fill(isPressed ? AnyShapeStyle(TemperatureColor.cool.opacity(isHeld ? 1 : 0.7)) : AnyShapeStyle(.quaternary))
            .overlay {
                if isPlaceholder {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                        .foregroundStyle(.tertiary)
                }
            }
            .overlay {
                Text(verbatim: legend)
                    .font(.system(size: min(height * 0.42, 13), weight: .medium))
                    .foregroundStyle(isPressed ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .frame(width: width, height: height)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: legend))
            .accessibilityValue(isPressed ? Text("Tested") : Text("Not tested"))
    }
}
