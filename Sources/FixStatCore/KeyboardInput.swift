import AppKit
import Carbon
import MacSensors

/// Keyboard test input, shared by both interfaces.

/// Keyboard event tap at the HID level: sees keys that macOS consumes before they reach
/// an app. Active (can block the key) with Accessibility, listen-only with Input Monitoring.
public final class KeyEventTap {
    public enum Mode { case none, listenOnly, active }

    public private(set) var mode = Mode.none
    /// Returns true to block the event (active tap only). Called on the main thread.
    public var handler: ((NSEvent) -> Bool)?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    public init() {}

    public func start() {
        guard port == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue) | (1 << 14) // NX_SYSDEFINED: media keys
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<KeyEventTap>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let port = tap.port { CGEvent.tapEnable(tap: port, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard let ns = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
            let block = (tap.handler?(ns) ?? false) && tap.mode == .active
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

    public func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
        mode = .none
    }
}

/// Key legends and layout type from the current input source, like the Keyboard Viewer.
public enum KeyLegend {
    public static var kind: KeyboardLayout.Kind {
        KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO ? .iso : .ansi
    }

    public static var layoutName: String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return "" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    /// Characters of all keys of the current layout, uppercased like the key caps.
    public static func legends() -> [Int: String] {
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
            // CharacterSet instead of Unicode.Scalar.Properties (macOS 10.15+).
            guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
            result[code] = text.uppercased(with: locale)
        }
        return result
    }

    /// Newer function-row keys send their own key codes (Mission Control, Spotlight,
    /// Dictation, Do Not Disturb, Launchpad); they are the F3–F6 / F4 positions.
    public static func physicalCode(_ code: Int) -> Int {
        switch code {
        case 160: return 99 // Mission Control → F3
        case 177, 131: return 118 // Spotlight / Launchpad → F4
        case 176: return 96 // Dictation → F5
        case 178: return 97 // Do Not Disturb → F6
        default: return code
        }
    }

    /// NX_KEYTYPE_* media keys → function-row positions on 2020+ MacBooks.
    public static let mediaKeyCodes: [Int: Int] = [
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
    public static func isModifierDown(_ code: Int, flags: NSEvent.ModifierFlags) -> Bool? {
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

extension KeyEventTap {
    /// Asks for Input Monitoring (macOS 10.15+) and opens its settings pane.
    public static func requestAccess() {
        if #available(macOS 10.15, *) { _ = CGRequestListenEventAccess() }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension KeyboardLayout {
    /// "12 / 78 keys"
    public static func progress(_ pressed: Int, of total: Int) -> String {
        L("%lld / %lld keys", pressed, total)
    }
}
