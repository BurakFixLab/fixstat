import Foundation
import IOKit

/// The enclosure finish of an Apple Silicon Mac: the device tree's `chosen/housing-color`
/// (four 32-bit little-endian words, e.g. `01000000 00000000 00000000 02000000`). macOS picks the
/// coloured Mac picture with the same number (CoreTypes' `<model>@ECOLOR=<n>` device codes):
/// 1 silver, 2 space gray, 3 gold, 7 midnight, 8 starlight, 9 space black, 11 sky blue.
/// Which word holds the number is assumed to be the last one (the first reads 1 on every Mac
/// seen so far); to be confirmed with dumps of Macs whose colour is known. Read-only, no root.
public enum HousingColor: Int, CaseIterable, Sendable {
    case silver = 1, spaceGray = 2, gold = 3, midnight = 7, starlight = 8, spaceBlack = 9, skyBlue = 11

    /// This Mac's finish; nil on Intel or an unknown number.
    /// `-FixStatHousingColor silver|spaceGray|gold|midnight|starlight|spaceBlack|skyBlue` overrides it.
    public static func current() -> HousingColor? {
        if let raw = UserDefaults.standard.string(forKey: "FixStatHousingColor") {
            return allCases.first { "\($0)" == raw }
        }
        return rawWords().flatMap(of(words:))
    }

    static func of(words: [UInt32]) -> HousingColor? {
        words.last.flatMap { HousingColor(rawValue: Int($0)) }
    }

    /// The property's words, for diagnostic dumps too.
    public static func rawWords() -> [UInt32]? {
        let chosen = IORegistryEntryFromPath(ioMainPort, "IODeviceTree:/chosen")
        guard chosen != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(chosen) }
        guard let data = IORegistryEntryCreateCFProperty(chosen, "housing-color" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data, data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        var words: [UInt32] = []
        for start in stride(from: 0, to: bytes.count - 3, by: 4) {
            var word: UInt32 = 0
            for (shift, byte) in bytes[start..<start + 4].enumerated() {
                word |= UInt32(byte) << UInt32(8 * shift)
            }
            words.append(word)
        }
        return words
    }
}
