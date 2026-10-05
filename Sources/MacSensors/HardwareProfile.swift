import Foundation

/// What kind of Mac this is and which built-in parts it has, so that tools and checks that
/// cannot apply (a battery test on a Mac mini, a lid test on an iMac) are not offered.
///
/// Recent Apple Silicon models all have `MacNN,N` identifiers, so the kind comes from the
/// product name first, then from the identifier, and finally from the hardware (a lid or
/// a battery means a notebook).
public struct HardwareProfile: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// MacBook, MacBook Air, MacBook Pro.
        case notebook
        /// iMac, iMac Pro: built-in display, camera, microphone, speakers.
        case allInOne
        /// Mac mini, Mac Studio, Mac Pro: no built-in display, camera or microphone.
        case desktop
    }

    public var kind: Kind
    /// An internal battery is installed (false on desktops and on a notebook running
    /// without its battery at the bench).
    public var hasBattery: Bool
    /// The SMC reports fans (`FNum` > 0): MacBook Pro, iMac, Mac mini, Mac Studio, Mac Pro
    /// and older MacBook Airs; not the fanless Apple Silicon MacBook Airs.
    public var hasFans: Bool
    /// MacBook Pros with a Touch Bar instead of the function keys.
    public var touchBar: TouchBar?

    public enum TouchBar: String, Codable, Sendable {
        /// Magic Keyboard models with a physical Esc key: 16-inch 2019 (A2141), 13-inch 2020
        /// (A2251, A2289), 13-inch M1 / M2 (A2338).
        case withEscapeKey
        /// Butterfly keyboard models 2016 – 2019 (e.g. A1706, A1707, A1989, A1990, A2159):
        /// Esc is on the Touch Bar.
        case withoutEscapeKey
    }

    public init(kind: Kind, hasBattery: Bool, hasFans: Bool = false, touchBar: TouchBar? = nil) {
        self.kind = kind
        self.hasBattery = hasBattery
        self.hasFans = hasFans
        self.touchBar = touchBar
    }

    /// Touch Bar models by identifier (a closed set: no Mac after 2022 has one).
    public static func touchBar(model: String) -> TouchBar? {
        let withoutEscape: Set<String> = ["MacBookPro13,2", "MacBookPro13,3", "MacBookPro14,2", "MacBookPro14,3",
                                          "MacBookPro15,1", "MacBookPro15,2", "MacBookPro15,3", "MacBookPro15,4"]
        let withEscape: Set<String> = ["MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,3", "MacBookPro16,4",
                                       "MacBookPro17,1", "Mac14,7"]
        if withoutEscape.contains(model) { return .withoutEscapeKey }
        if withEscape.contains(model) { return .withEscapeKey }
        return nil
    }

    public var isNotebook: Bool { kind == .notebook }
    /// Lid sensor, built-in keyboard and trackpad.
    public var hasLid: Bool { kind == .notebook }
    public var hasBuiltInKeyboard: Bool { kind == .notebook }
    public var hasBuiltInTrackpad: Bool { kind == .notebook }
    /// Built-in display, camera, microphone and ambient light sensor.
    public var hasBuiltInDisplay: Bool { kind != .desktop }
    public var hasBuiltInCamera: Bool { kind != .desktop }
    public var hasBuiltInMicrophone: Bool { kind != .desktop }
    public var hasAmbientLightSensor: Bool { kind != .desktop }

    /// The profile of this Mac. `-FixStatHardwareKind notebook|allInOne|desktop` (an
    /// argument or a default) overrides the kind for testing; a desktop or all-in-one
    /// override also hides the battery.
    public static func current(system: SystemInfo = .current()) -> HardwareProfile {
        let battery = batteryInstalled()
        let fans = ((try? SMC())?.fans().count ?? 0) > 0 || UserDefaults.standard.integer(forKey: "FixStatSimulateFans") > 0
        // `-FixStatTouchBar withEscapeKey|withoutEscapeKey` pretends a Touch Bar (UI checks).
        let touchBar = UserDefaults.standard.string(forKey: "FixStatTouchBar").flatMap(TouchBar.init(rawValue:))
            ?? Self.touchBar(model: system.model)
        if let raw = UserDefaults.standard.string(forKey: "FixStatHardwareKind"), let kind = Kind(rawValue: raw) {
            return HardwareProfile(kind: kind, hasBattery: battery && kind == .notebook, hasFans: fans,
                                   touchBar: kind == .notebook ? touchBar : nil)
        }
        let kind = Self.kind(marketingName: system.marketingName, model: system.model)
            ?? (battery || LidSensor.isClosed() != nil ? .notebook : .desktop)
        return HardwareProfile(kind: kind, hasBattery: battery, hasFans: fans, touchBar: touchBar)
    }

    /// Kind from the product name ("MacBook Air (M2, 2022)", "iMac (24-inch, M4, 2024)",
    /// "Mac mini (2024)") or the model identifier ("MacBookPro16,1", "iMac20,1",
    /// "Macmini8,1", "MacPro7,1"); nil for an unknown `MacNN,N` without a name.
    public static func kind(marketingName: String?, model: String) -> Kind? {
        let name = marketingName?.lowercased() ?? ""
        if name.contains("macbook") { return .notebook }
        if name.contains("imac") { return .allInOne }
        if name.contains("mac mini") || name.contains("mac studio") || name.contains("mac pro") { return .desktop }
        let id = model.lowercased()
        if id.hasPrefix("macbook") { return .notebook }
        if id.hasPrefix("imac") { return .allInOne }
        if id.hasPrefix("macmini") || id.hasPrefix("macpro") || id.hasPrefix("xserve") { return .desktop }
        return nil
    }

    /// `AppleSmartBattery` reports `BatteryInstalled`.
    static func batteryInstalled() -> Bool {
        guard let properties = Registry.properties(ofClass: BatteryReader.registryClass) else { return false }
        return (properties["BatteryInstalled"] as? NSNumber)?.boolValue ?? false
    }
}
