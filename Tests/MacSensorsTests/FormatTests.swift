import Foundation
import Testing
@testable import FixStatCore

/// The pre-macOS 12 formatting (AppKit interface on old Macs) must look like the
/// FormatStyle output of the SwiftUI interface.
@Suite(.serialized) struct FormatFallbackTests {
    static func format(_ name: String) -> String {
        switch name {
        case "percent": Format.percent(73.3, digits: 1)
        case "temperature": Format.temperature(58.44)
        case "mAh": Format.milliampHours(4382)
        case "mA": Format.milliamps(1875)
        case "mA negative": Format.milliamps(-363)
        case "volts": Format.volts(millivolts: 11_620)
        case "amps": Format.amps(milliamps: 4700)
        case "mV": Format.millivolts(27)
        case "watts": Format.watts(22.4, digits: 1)
        case "Wh": Format.watthours(35.1)
        case "minutes": Format.minutes(172)
        case "duration": Format.duration(15_780)
        case "seconds": Format.seconds(3.29)
        case "min:sec": Format.minutesSeconds(245)
        case "bytes": Format.bytes(256_000_000_000)
        case "memory": Format.memory(8_589_934_592)
        case "speed": Format.speed(megabytesPerSecond: 2250)
        case "number": Format.number(4382.5, digits: 1)
        case "gigabytes": Format.gigabytes(8_589_934_592)
        default: ""
        }
    }

    @Test(arguments: ["percent", "temperature", "mAh", "mA", "mA negative", "volts", "amps", "mV", "watts", "Wh",
                      "minutes", "duration", "seconds", "min:sec", "bytes", "memory", "speed", "number", "gigabytes"])
    func sameOutput(name: String) {
        Format.forceLegacy = false
        let modern = Self.format(name)
        Format.forceLegacy = true
        let legacy = Self.format(name)
        Format.forceLegacy = false
        #expect(modern == legacy, "\(name): modern «\(modern)» legacy «\(legacy)»")
    }
}
