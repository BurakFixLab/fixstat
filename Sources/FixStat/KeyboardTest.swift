import AppKit
import Carbon
import MacSensors
import SwiftUI

/// Keyboard test: draws the built-in keyboard and marks every key that registered.
struct KeyboardTestView: View {
    @Environment(Monitor.self) private var monitor
    @State private var pressed: Set<Int> = []
    @State private var held: Set<Int> = []
    @State private var eventMonitor: Any?
    @State private var tap = KeyTap()
    @State private var retry: Timer?

    private let kind = KeyLegend.kind
    private var total: Int { KeyboardLayout.codes(kind).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyboardDrawing(kind: kind, pressed: pressed, held: held)
                .frame(maxWidth: 720)
            HStack {
                Text("\(pressed.count) / \(total) keys")
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
                Button("Allow…") {
                    _ = CGRequestListenEventAccess()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
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
        guard KeyboardLayout.codes(kind).contains(code) else { return }
        if down {
            held.insert(code)
            if pressed.insert(code).inserted {
                monitor.recordCheck(.keyboard, detail: String(localized: "\(pressed.count) / \(total) keys"),
                                    passed: pressed.count == total)
            }
        } else {
            held.remove(code)
        }
    }
}

/// Keyboard event tap at the HID level: sees keys that macOS consumes before they reach
/// an app. Active (can block the key) with Accessibility, listen-only with Input Monitoring.
@MainActor
@Observable
final class KeyTap {
    enum Mode { case none, listenOnly, active }

    private(set) var mode = Mode.none
    /// Returns true to block the event (active tap only).
    @ObservationIgnored var handler: ((NSEvent) -> Bool)?
    @ObservationIgnored private var port: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?

    func start() {
        guard port == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue) | (1 << 14) // NX_SYSDEFINED: media keys
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<KeyTap>.fromOpaque(info).takeUnretainedValue()
            let block = MainActor.assumeIsolated { () -> Bool in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let port = tap.port { CGEvent.tapEnable(tap: port, enable: true) }
                    return false
                }
                guard let ns = NSEvent(cgEvent: event) else { return false }
                return (tap.handler?(ns) ?? false) && tap.mode == .active
            }
            return block ? nil : Unmanaged.passUnretained(event)
        }
        let info = Unmanaged.passUnretained(self).toOpaque()
        for (options, mode) in [(CGEventTapOptions.defaultTap, Mode.active), (.listenOnly, .listenOnly)] {
            if let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: options,
                                            eventsOfInterest: mask, callback: callback, userInfo: info) {
                let source = CFMachPortCreateRunLoopSource(nil, port, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: port, enable: true)
                self.port = port
                self.source = source
                self.mode = mode
                return
            }
        }
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
        mode = .none
    }
}

/// Key legends and layout type from the current input source, like the Keyboard Viewer.
enum KeyLegend {
    static var kind: KeyboardLayout.Kind {
        KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO ? .iso : .ansi
    }

    static var layoutName: String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return "" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    /// Characters of all keys of the current layout, uppercased like the key caps.
    static func legends() -> [Int: String] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return [:] }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let locale = Locale.current
        var result: [Int: String] = [:]
        for code in 0..<128 {
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var count = 0
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &count, &chars)
            guard status == noErr, count > 0 else { continue }
            let text = String(utf16CodeUnits: chars, count: count)
            guard !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { continue }
            result[code] = text.uppercased(with: locale)
        }
        return result
    }

    /// Newer function-row keys send their own key codes (Mission Control, Spotlight,
    /// Dictation, Do Not Disturb, Launchpad); they are the F3–F6 / F4 positions.
    static func physicalCode(_ code: Int) -> Int {
        switch code {
        case 160: 99 // Mission Control → F3
        case 177, 131: 118 // Spotlight / Launchpad → F4
        case 176: 96 // Dictation → F5
        case 178: 97 // Do Not Disturb → F6
        default: code
        }
    }

    /// NX_KEYTYPE_* media keys → function-row positions on 2020+ MacBooks.
    static let mediaKeyCodes: [Int: Int] = [
        3: 122, // brightness down → F1
        2: 120, // brightness up → F2
        21: 97, 22: 96, // keyboard illumination (older models) → F6 / F5
        20: 98, 18: 98, // rewind / previous → F7
        16: 100, // play → F8
        19: 101, 17: 101, // fast / next → F9
        7: 109, // mute → F10
        1: 103, // volume down → F11
        0: 111, // volume up → F12
    ]

    /// Device-dependent modifier bits (NX_DEVICE*KEYMASK), so left and right keys differ.
    static func isModifierDown(_ code: Int, flags: NSEvent.ModifierFlags) -> Bool? {
        let raw = flags.rawValue
        switch code {
        case 59: return raw & 0x0001 != 0 // left control
        case 62: return raw & 0x2000 != 0 // right control
        case 56: return raw & 0x0002 != 0 // left shift
        case 60: return raw & 0x0004 != 0 // right shift
        case 55: return raw & 0x0008 != 0 // left command
        case 54: return raw & 0x0010 != 0 // right command
        case 58: return raw & 0x0020 != 0 // left option
        case 61: return raw & 0x0040 != 0 // right option
        case 63: return flags.contains(.function)
        case 57: return true // caps lock: every change is a press
        default: return nil
        }
    }
}

/// Draws the keyboard rows, 14.5 units wide.
struct KeyboardDrawing: View {
    let kind: KeyboardLayout.Kind
    let pressed: Set<Int>
    let held: Set<Int>
    @State private var legends = KeyLegend.legends()

    var body: some View {
        GeometryReader { proxy in
            let unit = proxy.size.width / 14.5
            let gap = unit * 0.1
            VStack(spacing: gap) {
                ForEach(Array(KeyboardLayout.rows(kind).enumerated()), id: \.offset) { index, row in
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
        let isPlaceholder = key.code == KeyboardLayout.touchIDPlaceholder
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
