import FixStatCore
import Testing
@testable import MacSensors

@Suite struct PortHistoryTests {
    static func port(_ number: Int, speed: Int?) -> PortStatus {
        PortStatus(type: "USB-A", number: number, connected: speed != nil, activeTransports: [], supportedTransports: [],
                   powerIn: nil, overcurrentCount: nil, connectionCount: nil, enumerationFailures: 0,
                   devices: speed.map { [USBDeviceInfo(name: "Ugreen Storage Device", vendorID: 5964, productID: 4435,
                                                       speed: $0, portNumber: nil)] } ?? [])
    }

    @Test func usb3DeviceAtUSB2SpeedFlagsThePort() {
        // Air 2014: the same disk at 5 Gb/s in USB-A 2, at 480 Mb/s in USB-A 1.
        var history = PortHistory()
        _ = history.update([Self.port(1, speed: nil), Self.port(2, speed: 3)])
        _ = history.update([Self.port(1, speed: 2), Self.port(2, speed: nil)])
        let slow = history.slowLane(Self.port(1, speed: nil))
        #expect(slow?.here == 480)
        #expect(slow?.elsewhere == 5_000)
        #expect(history.slowLane(Self.port(2, speed: nil)) == nil)
        #expect(history.allDataTested([Self.port(1, speed: nil), Self.port(2, speed: nil)]))
        #expect(!history.passed([Self.port(1, speed: nil), Self.port(2, speed: nil)]))
    }

    @Test func usb2OnlyDeviceIsNotAFault() {
        var history = PortHistory()
        _ = history.update([Self.port(1, speed: 2), Self.port(2, speed: 2)])
        #expect(history.slowLane(Self.port(1, speed: nil)) == nil)
    }
}
