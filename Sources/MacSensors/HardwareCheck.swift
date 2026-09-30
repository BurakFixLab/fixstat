import Foundation

/// Results of the hardware checklist (keyboard, trackpad, display, …).
///
/// Each item is marked passed / failed / skipped by the technician; tests that can
/// measure something fill in `detail` (e.g. "78 / 78 keys", "−38 dBFS peak").
public struct HardwareCheck: Codable, Sendable, Equatable {
    public enum Item: String, CaseIterable, Codable, Sendable {
        case keyboard, trackpad, display, ambientLight, speakers, microphone, camera, wifi, bluetooth, ports, lid
    }

    public enum Status: String, Codable, Sendable {
        case untested, passed, failed, skipped
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var status: Status
        /// Measured evidence, already localized for the report.
        public var detail: String?
        /// Technician's note.
        public var note: String
        public var date: Date?

        public init(status: Status = .untested, detail: String? = nil, note: String = "", date: Date? = nil) {
            self.status = status
            self.detail = detail
            self.note = note
            self.date = date
        }
    }

    public var entries: [Item: Entry]

    public init(entries: [Item: Entry] = [:]) {
        self.entries = entries
    }

    public subscript(item: Item) -> Entry {
        get { entries[item] ?? Entry() }
        set { entries[item] = newValue }
    }

    public func count(_ status: Status) -> Int {
        Item.allCases.filter { self[$0].status == status }.count
    }

    /// Nothing has been marked yet.
    public var isEmpty: Bool { count(.untested) == Item.allCases.count }

    public var hasFailures: Bool { count(.failed) > 0 }
}

/// Physical layout of a MacBook built-in keyboard (2016 and later), by virtual key code.
///
/// Rows are 14.5 units wide. The function row is drawn half height. ANSI and ISO
/// differ in the key left of "1" / right of left Shift and in the Return key; JIS
/// keyboards are shown with the ANSI layout.
public enum KeyboardLayout {
    public enum Kind: Sendable { case ansi, iso }

    public struct Key: Sendable, Equatable {
        public let code: Int
        public let width: Double
        /// Fixed legend (symbol) for keys whose character does not come from the input source.
        public let legend: String?
        /// Up/Down arrows share one column, drawn half height.
        public let halfHeight: Bool

        init(_ code: Int, _ width: Double = 1, _ legend: String? = nil, halfHeight: Bool = false) {
            self.code = code
            self.width = width
            self.legend = legend
            self.halfHeight = halfHeight
        }
    }

    /// Key code used for the Touch ID / power button position (not a real key code: that
    /// button never reaches apps).
    public static let touchIDPlaceholder = -1

    public static func rows(_ kind: Kind) -> [[Key]] {
        let function: [Key] = [Key(53, 1.5, "esc")]
            + [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].enumerated().map { Key($1, 1, "F\($0 + 1)") }
            + [Key(touchIDPlaceholder, 1, "⏻")]
        let letters1 = [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30].map { Key($0) }
        let letters2 = [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39].map { Key($0) }
        let letters3 = [6, 7, 8, 9, 11, 45, 46, 43, 47, 44].map { Key($0) }
        let digits = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24].map { Key($0) }
        let bottom: [Key] = [
            Key(63, 1, "fn"), Key(59, 1, "⌃"), Key(58, 1, "⌥"), Key(55, 1.25, "⌘"), Key(49, 5, ""),
            Key(54, 1.25, "⌘"), Key(61, 1, "⌥"), Key(123, 1, "←"),
            Key(126, 1, "↑", halfHeight: true), Key(125, 1, "↓", halfHeight: true), Key(124, 1, "→"),
        ]
        switch kind {
        case .ansi:
            return [
                function,
                [Key(50)] + digits + [Key(51, 1.5, "⌫")],
                [Key(48, 1.5, "⇥")] + letters1 + [Key(42)],
                [Key(57, 1.75, "⇪")] + letters2 + [Key(36, 1.75, "⏎")],
                [Key(56, 2.25, "⇧")] + letters3 + [Key(60, 2.25, "⇧")],
                bottom,
            ]
        case .iso:
            return [
                function,
                [Key(10)] + digits + [Key(51, 1.5, "⌫")],
                [Key(48, 1.5, "⇥")] + letters1 + [Key(36, 1, "⏎")],
                [Key(57, 1.75, "⇪")] + letters2 + [Key(42), Key(36, 0.75, "")],
                [Key(56, 1.25, "⇧"), Key(50)] + letters3 + [Key(60, 2.25, "⇧")],
                bottom,
            ]
        }
    }

    /// Every testable key code of the layout (Touch ID excluded).
    public static func codes(_ kind: Kind) -> Set<Int> {
        Set(rows(kind).joined().map(\.code).filter { $0 != touchIDPlaceholder })
    }
}
