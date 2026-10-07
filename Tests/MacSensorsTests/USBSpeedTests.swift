import FixStatCore
import Foundation
import Testing
@testable import MacSensors

@Suite struct USBSpeedTests {
    static func result(_ port: String, read: Double?, errors: Int = 0, stopped: Bool = false) -> USBSpeedResult {
        USBSpeedResult(date: Date(), port: port, deviceKey: "1921:21889", drive: "USB Flash Drive", linkMbps: 5_000,
                       writeSpeed: 40, readSpeed: read, errors: errors, stoppedEarly: stopped)
    }

    @Test func sameDriveMuchSlowerInOnePortIsFlagged() {
        let results = [Self.result("USB-A 1", read: 180), Self.result("USB-A 2", read: 35)]
        let findings = USBSpeedText.findings(results)
        #expect(findings.count == 1)
        #expect(findings.first?.contains("USB-A 2") == true)
    }

    @Test func similarSpeedsAreFine() {
        let results = [Self.result("USB-A 1", read: 180), Self.result("USB-A 2", read: 150)]
        #expect(USBSpeedText.findings(results).isEmpty)
        #expect(USBSpeedText.findings([Self.result("USB-A 1", read: 20)]).isEmpty) // one port: nothing to compare
    }

    @Test func errorsAreFlaggedAndStoppedRunsNotCompared() {
        #expect(USBSpeedText.findings([Self.result("USB-C 1", read: 300, errors: 2)]).count == 1)
        let results = [Self.result("USB-A 1", read: 180), Self.result("USB-A 2", read: 10, stopped: true)]
        #expect(USBSpeedText.findings(results).isEmpty)
    }

    @Test func volumeFindsItsPort() {
        let device = USBDeviceInfo(name: "USB Flash Drive", vendorID: 1921, productID: 21889, speed: 3, portNumber: nil)
        let volume = USBVolume(url: URL(fileURLWithPath: "/Volumes/STICK"), name: "STICK", bsdName: "disk4s1",
                               availableBytes: 1 << 30, device: device)
        let empty = PortStatus(type: "USB-A", number: 1, connected: false, activeTransports: [], supportedTransports: [],
                               powerIn: nil, overcurrentCount: nil, connectionCount: nil, enumerationFailures: 0, devices: [])
        var used = empty
        used.number = 2
        used.connected = true
        used.devices = [device]
        #expect(volume.port(in: [empty, used])?.number == 2)

        var usbC = volume
        usbC.device.portNumber = 1
        let portC = PortStatus(type: "USB-C", number: 1, connected: true, activeTransports: ["USB3"], supportedTransports: [],
                               powerIn: nil, overcurrentCount: nil, connectionCount: nil, enumerationFailures: 0, devices: [])
        #expect(usbC.port(in: [empty, portC])?.type == "USB-C")
    }
}
