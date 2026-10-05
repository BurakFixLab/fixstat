import CoreGraphics
import Foundation
import IOKit.graphics
import IOKit.pwr_mgt

/// Turning the built-in display's backlight off for the idle power measurement: it is the
/// largest and most variable load of an idle notebook. No root needed.
///
/// The brightness is set to 0 through DisplayServices (private, the framework the brightness
/// keys use) or, where that is missing, the IODisplay brightness parameter; the display stays
/// awake. Putting the display to sleep instead (`pmset displaysleepnow`) is the fallback: on
/// some Macs the internal trackpad reports an event a few seconds after the display sleeps,
/// which wakes it again.
public enum DisplayPower {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let displayServices: (get: GetBrightness, set: SetBrightness)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"), let set = dlsym(handle, "DisplayServicesSetBrightness")
        else { return nil }
        return (unsafeBitCast(get, to: GetBrightness.self), unsafeBitCast(set, to: SetBrightness.self))
    }()

    /// The built-in display (or the main one).
    static var display: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    /// Brightness 0…1, nil when it cannot be read.
    public static func brightness() -> Float? {
        if let services = displayServices {
            var value: Float = 0
            if services.get(display, &value) == 0 { return value }
        }
        return ioDisplay { service in
            var value: Float = 0
            return IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &value) == kIOReturnSuccess ? value : nil
        }
    }

    @discardableResult
    public static func setBrightness(_ value: Float) -> Bool {
        if let services = displayServices, services.set(display, value) == 0 { return true }
        return ioDisplay { service in
            IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, value) == kIOReturnSuccess ? true : nil
        } ?? false
    }

    /// Runs `body` on the IODisplayConnect services until it returns a value (Intel).
    private static func ioDisplay<T>(_ body: (io_service_t) -> T?) -> T? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(ioMainPort, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            if let value = body(service) { return value }
        }
        return nil
    }

    /// `pmset displaysleepnow` (fallback when the brightness cannot be set).
    public static func sleepNow() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
        process.waitUntilExit()
    }

    /// Declares user activity, which wakes a sleeping display.
    public static func wake() {
        var id = IOPMAssertionID(0)
        if IOPMAssertionDeclareUserActivity("FixStat idle power measurement" as CFString, kIOPMUserActiveLocal, &id)
            == kIOReturnSuccess {
            IOPMAssertionRelease(id)
        }
    }

    public static var isAsleep: Bool { CGDisplayIsAsleep(display) != 0 }
}

/// System power with the display off, the Mac idle and awake.
public struct IdlePowerResult: Codable, Sendable, Equatable {
    public var date: Date
    /// Mean system power (W): adapter input minus charging on Apple Silicon, the battery's
    /// output on battery.
    public var watts: Double
    /// Standard deviation of the samples (W).
    public var spread: Double
    public var samples: Int
    /// Mean share of all CPUs in use (0…1): a busy process explains a high value.
    public var cpu: Double?
    public var onBattery: Bool
    /// "smc" (`PSTR`, every second) or "gauge" (battery telemetry, every ~30 s).
    public var source: String?

    public init(date: Date, samples values: [Double], cpu: Double?, onBattery: Bool, source: String? = nil) {
        self.date = date
        let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        watts = mean
        spread = values.isEmpty ? 0
            : (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        samples = values.count
        self.cpu = cpu
        self.onBattery = onBattery
        self.source = source
    }
}

/// `SensorMaps/power-reference.json`: idle power with the display off measured at the bench on
/// Macs known to be good, per model.
public struct PowerReference: Codable, Sendable, Equatable {
    public struct Model: Codable, Sendable, Equatable {
        /// One value per recorded Mac (W).
        public var idleDisplayOffW: [Double]

        public init(idleDisplayOffW: [Double]) {
            self.idleDisplayOffW = idleDisplayOffW
        }
    }

    public var schemaVersion: Int
    public var note: String?
    public var models: [String: Model]

    public init(schemaVersion: Int = 1, note: String? = nil, models: [String: Model] = [:]) {
        self.schemaVersion = schemaVersion
        self.note = note
        self.models = models
    }

    public static func load(from url: URL) -> PowerReference? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PowerReference.self, from: data)
    }

    public enum Verdict: Equatable, Sendable {
        case noReference
        /// Within the reference (`range` of the recorded values).
        case normal(range: ClosedRange<Double>, samples: Int)
        /// Above it by `excess` W: a leak on a powered rail or a busy process.
        case elevated(excess: Double, range: ClosedRange<Double>, samples: Int)
    }

    /// Elevated when above both 125 % of the highest reference and its median + 0.5 W (the
    /// noise of the measurement).
    public func verdict(model: String, watts: Double) -> Verdict {
        guard let values = models[model]?.idleDisplayOffW.sorted(), let low = values.first, let high = values.last
        else { return .noReference }
        let median = values[values.count / 2]
        let limit = max(high * 1.25, median + 0.5)
        return watts > limit ? .elevated(excess: watts - median, range: low...high, samples: values.count)
            : .normal(range: low...high, samples: values.count)
    }
}
