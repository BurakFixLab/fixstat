import Foundation
import IOKit.hid

/// The lid (hinge) angle sensor of recent Apple Silicon notebooks: an SPU HID device named "las"
/// (VendorID 0x05AC, ProductID 0x8104, sensor page 0x20, usage 0x8A) whose input report 1 holds
/// the hinge angle, usage 0x047F, 9 bits, 0 … 360 degrees (report descriptor of the MacBook Air
/// M2 / M3 and MacBook Pro 14" M3 dumps; not on M1 or Intel Macs, nor the 13" M2 MacBook Pro).
///
/// Read-only. Three ways: a feature report and an input report asked for (all three answered on
/// a MacBook Pro M3, macOS 27), and the value the device last sent (delivered on the main run
/// loop; seconds behind the lid). `Reading.method` and `raw` say which one answered. Main thread.
public final class LidAngleSensor {
    public enum Method: String, Sendable { case inputValue, inputReport, featureReport }

    public struct Reading: Equatable, Sendable {
        /// Degrees, 0 = closed.
        public var degrees: Double
        public var method: Method
        /// The bytes or value read, for the diagnostic line.
        public var raw: String

        public init(degrees: Double, method: Method, raw: String) {
            self.degrees = degrees
            self.method = method
            self.raw = raw
        }
    }

    static let vendorID = 0x05AC, productID = 0x8104
    static let sensorPage: UInt32 = 0x20, angleUsage: UInt32 = 0x047F, reportID: CFIndex = 1

    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let element: IOHIDElement?
    private var lastValue: (degrees: Double, raw: Int)?

    /// nil when this Mac has no lid angle sensor or it cannot be opened.
    public init?() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, Self.matching as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first,
              IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
        self.manager = manager
        self.device = device
        let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
        element = elements.first {
            IOHIDElementGetUsagePage($0) == Self.sensorPage && IOHIDElementGetUsage($0) == Self.angleUsage
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            guard let context else { return }
            Unmanaged<LidAngleSensor>.fromOpaque(context).takeUnretainedValue().received(value)
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    static var matching: [String: Any] {
        [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID,
         kIOHIDPrimaryUsagePageKey: Int(sensorPage), kIOHIDPrimaryUsageKey: 0x8A]
    }

    /// Whether this Mac publishes the sensor (without opening it).
    public static var isPresent: Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        return !((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []).isEmpty
    }

    /// The current angle, asked of the sensor itself (a feature report, then an input report);
    /// the value the HID system last delivered only as a fallback: it lagged seconds behind the
    /// lid on a real Mac.
    public func read() -> Reading? {
        for (type, method) in [(kIOHIDReportTypeFeature, Method.featureReport), (kIOHIDReportTypeInput, Method.inputReport)] {
            if let bytes = report(type), let degrees = Self.angle(report: bytes) {
                return Reading(degrees: degrees, method: method, raw: bytes.map { String(format: "%02x", $0) }.joined())
            }
        }
        if let (result, raw) = currentValue(), result == kIOReturnSuccess, raw > 0 || lastValue != nil {
            return Reading(degrees: Double(raw), method: .inputValue, raw: String(raw))
        }
        if let last = lastValue { return Reading(degrees: last.degrees, method: .inputValue, raw: String(last.raw)) }
        return nil
    }

    /// Every way's answer, for diagnostic dumps (works off the main thread too, except the
    /// delivered input values).
    public func probe() -> [String] {
        var lines: [String] = []
        if let (result, raw) = currentValue() {
            lines.append("get value: " + (result == kIOReturnSuccess ? String(raw) : String(format: "error 0x%08x", result)))
        } else {
            lines.append("get value: no element with usage 0x20 / 0x047F")
        }
        for (type, name) in [(kIOHIDReportTypeInput, "input report 1"), (kIOHIDReportTypeFeature, "feature report 1")] {
            var buffer = [UInt8](repeating: 0, count: 8)
            var length = buffer.count
            let result = IOHIDDeviceGetReport(device, type, Self.reportID, &buffer, &length)
            lines.append(name + ": " + (result == kIOReturnSuccess
                ? buffer.prefix(length).map { String(format: "%02x", $0) }.joined()
                    + (Self.angle(report: Array(buffer.prefix(length))).map { String(format: " = %.0f°", $0) } ?? "")
                : String(format: "error 0x%08x", result)))
        }
        return lines
    }

    /// The angle element's current value as the HID system has it (nil without the element).
    private func currentValue() -> (IOReturn, Int)? {
        guard let element else { return nil }
        let placeholder = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0)
        var value = Unmanaged.passUnretained(placeholder)
        let result = IOHIDDeviceGetValue(device, element, &value)
        return (result, result == kIOReturnSuccess ? IOHIDValueGetIntegerValue(value.takeUnretainedValue()) : 0)
    }

    private func report(_ type: IOHIDReportType) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 8)
        var length = buffer.count
        guard IOHIDDeviceGetReport(device, type, Self.reportID, &buffer, &length) == kIOReturnSuccess else { return nil }
        return Array(buffer.prefix(length))
    }

    /// Report 1: the report ID, then the 9-bit angle, little endian.
    static func angle(report bytes: [UInt8]) -> Double? {
        guard bytes.count >= 3, bytes[0] == UInt8(reportID) else { return nil }
        let value = (Int(bytes[1]) | Int(bytes[2]) << 8) & 0x1FF
        return value <= 360 ? Double(value) : nil
    }

    private func received(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == Self.sensorPage, IOHIDElementGetUsage(element) == Self.angleUsage else { return }
        let raw = IOHIDValueGetIntegerValue(value)
        lastValue = (Double(raw), raw)
    }
}
