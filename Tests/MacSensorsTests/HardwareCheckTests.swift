import Foundation
import Testing
@testable import MacSensors

@Suite struct HardwareCheckTests {
    @Test(arguments: [KeyboardLayout.Kind.ansi, .iso])
    func keyboardRowsAreFullWidth(kind: KeyboardLayout.Kind) {
        for row in KeyboardLayout.rows(kind) {
            // Stacked half-height keys (Up/Down) share one column.
            var width = 0.0
            var previousHalf = false
            for key in row {
                if key.halfHeight && previousHalf {
                    previousHalf = false
                    continue
                }
                width += key.width
                previousHalf = key.halfHeight
            }
            #expect(abs(width - 14.5) < 0.001)
        }
    }

    @Test func keyboardCodes() {
        let ansi = KeyboardLayout.codes(.ansi)
        let iso = KeyboardLayout.codes(.iso)
        #expect(ansi.count == 77)
        #expect(iso.count == 78)
        #expect(!ansi.contains(10))
        #expect(iso.subtracting(ansi) == [10])
        #expect(!ansi.contains(KeyboardLayout.touchIDPlaceholder))
    }

    @Test func checkCounts() {
        var check = HardwareCheck()
        #expect(check.isEmpty)
        check[.keyboard].status = .passed
        check[.camera].status = .failed
        #expect(!check.isEmpty)
        #expect(check.hasFailures)
        #expect(check.count(.untested) == HardwareCheck.Item.allCases.count - 2)
        let data = try! JSONEncoder().encode(check)
        #expect(try! JSONDecoder().decode(HardwareCheck.self, from: data) == check)
    }

    @Test func touchBarLayouts() {
        let full = KeyboardLayout.codes(.ansi)
        let withEscape = KeyboardLayout.codes(.ansi, touchBar: .withEscapeKey)
        let withoutEscape = KeyboardLayout.codes(.ansi, touchBar: .withoutEscapeKey)
        let fKeys: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        #expect(full.isSuperset(of: fKeys))
        #expect(withEscape == full.subtracting(fKeys))
        #expect(withoutEscape == full.subtracting(fKeys).subtracting([53]))
        for touchBar in [HardwareProfile.TouchBar.withEscapeKey, .withoutEscapeKey] {
            for kind in [KeyboardLayout.Kind.ansi, .iso] {
                // The function row stays 14.5 units wide.
                #expect(KeyboardLayout.rows(kind, touchBar: touchBar)[0].map(\.width).reduce(0, +) == 14.5)
            }
        }
    }

    @Test func touchBarModels() {
        #expect(HardwareProfile.touchBar(model: "MacBookPro15,2") == .withoutEscapeKey) // A1989, butterfly
        #expect(HardwareProfile.touchBar(model: "MacBookPro17,1") == .withEscapeKey)    // A2338
        #expect(HardwareProfile.touchBar(model: "MacBookPro16,3") == .withEscapeKey)    // A2289
        #expect(HardwareProfile.touchBar(model: "MacBookPro14,1") == nil)               // no Touch Bar
        #expect(HardwareProfile.touchBar(model: "Mac14,2") == nil)
        let items = HardwareCheck.items(for: HardwareProfile(kind: .notebook, hasBattery: true, touchBar: .withEscapeKey))
        #expect(items.prefix(2) == [.keyboard, .touchBar])
        #expect(!HardwareCheck.items(for: HardwareProfile(kind: .notebook, hasBattery: true)).contains(.touchBar))
    }

    @Test func hardwareKind() {
        #expect(HardwareProfile.kind(marketingName: "MacBook Air (M2, 2022)", model: "Mac14,2") == .notebook)
        #expect(HardwareProfile.kind(marketingName: "iMac (24-inch, 2024)", model: "Mac16,2") == .allInOne)
        #expect(HardwareProfile.kind(marketingName: "Mac mini (2024)", model: "Mac16,10") == .desktop)
        #expect(HardwareProfile.kind(marketingName: "Mac Studio (2023)", model: "Mac14,13") == .desktop)
        #expect(HardwareProfile.kind(marketingName: nil, model: "iMac20,1") == .allInOne)
        #expect(HardwareProfile.kind(marketingName: nil, model: "Macmini8,1") == .desktop)
        #expect(HardwareProfile.kind(marketingName: nil, model: "MacBookAir6,1") == .notebook)
        #expect(HardwareProfile.kind(marketingName: nil, model: "Mac15,3") == nil)
    }

    @Test func checklistFollowsTheMac() {
        let mini = HardwareCheck.items(for: HardwareProfile(kind: .desktop, hasBattery: false))
        #expect(mini == [.speakers, .wifi, .bluetooth, .ports])
        let iMac = HardwareCheck.items(for: HardwareProfile(kind: .allInOne, hasBattery: false))
        #expect(iMac == [.display, .ambientLight, .speakers, .microphone, .camera, .wifi, .bluetooth, .ports])
        #expect(HardwareCheck.items(for: HardwareProfile(kind: .notebook, hasBattery: true, hasFans: true, touchBar: .withEscapeKey))
            == HardwareCheck.Item.allCases)
        // Fanless MacBook Air: everything but the fan and Touch Bar tests.
        #expect(HardwareCheck.items(for: HardwareProfile(kind: .notebook, hasBattery: true))
            == HardwareCheck.Item.allCases.filter { $0 != .fans && $0 != .touchBar })
        let iMacWithFans = HardwareCheck.items(for: HardwareProfile(kind: .allInOne, hasBattery: false, hasFans: true))
        #expect(iMacWithFans == [.display, .ambientLight, .speakers, .microphone, .camera, .fans, .wifi, .bluetooth, .ports])

        var check = HardwareCheck(items: mini)
        check[.keyboard].status = .passed // not part of this Mac's checklist
        #expect(check.isEmpty)
        #expect(check.count(.untested) == 4)
    }

    @Test func checklistFromAnEarlierVersionDecodes() throws {
        let json = #"{"entries":["camera",{"status":"failed","note":""}]}"#
        let check = try JSONDecoder().decode(HardwareCheck.self, from: Data(json.utf8))
        #expect(check.items == HardwareCheck.Item.allCases)
        #expect(check[.camera].status == .failed)
    }

    @Test func lastSleepReason() {
        let log = """
            2026-09-29 06:10:21 +0300 Sleep               \tEntering Sleep state due to 'Low Power Sleep':TCPKeepAlive=inactive
            2026-09-29 09:25:03 +0300 Wake                \tWake from Hibernate [CDNVA] : due to UserActivity
            2026-09-29 10:00:00 +0300 Sleep               \tEntering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active
            2026-09-29 10:00:09 +0300 Wake                \tWake from Normal Sleep [CDNVA] : due to EC.LidOpen/Lid Open
            """
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-09-29T07:01:00Z")! // 10:01 +0300
        #expect(LidSensor.parseLastSleepReason(log, within: 300, now: now) == "Clamshell Sleep")
        #expect(LidSensor.parseLastSleepReason(log, within: 30, now: now) == nil)
    }
}

@Suite struct PortControllerTests {
    @Test func chargingPortFromContract() {
        let active: [String: Any] = ["PortControllerActiveContractRdo": 319_074_604, "PortControllerMaxPower": 94_000,
                                     "PortControllerShortDetectCount": 0, "PortControllerHardResetCount": 1]
        let counters = PortControllerCounters.parse(active, externalPower: true)
        #expect(counters.charging)
        #expect(counters.maxPowerWatts == 94)
        #expect(counters.hardReset == 1)
        #expect(counters.hasFaults)
        #expect(!PortControllerCounters.parse(active, externalPower: false).charging)
        let idle: [String: Any] = ["PortControllerActiveContractRdo": 0, "PortControllerMaxPower": 0]
        #expect(!PortControllerCounters.parse(idle, externalPower: true).charging)
        #expect(!PortControllerCounters.parse(idle, externalPower: true).hasFaults)
    }
}

@Suite struct DeviceInfoTests {
    @Test func enrollment() {
        let text = "Enrolled via DEP: No\nMDM enrollment: Yes (User Approved)\n"
        #expect(DeviceInfo.parseEnrollment(text, prefix: "Enrolled via DEP:") == .off)
        #expect(DeviceInfo.parseEnrollment(text, prefix: "MDM enrollment:") == .on)
        #expect(DeviceInfo.parseEnrollment(nil, prefix: "MDM enrollment:") == .unknown)
    }

    @Test func statuses() {
        #expect(DeviceInfo.activationLock("activation_lock_disabled") == .off)
        #expect(DeviceInfo.activationLock("activation_lock_enabled") == .on)
        #expect(DeviceInfo.activationLock(nil) == .unknown)
        #expect(DeviceInfo.parseStatus("System Integrity Protection status: enabled.", on: "enabled", off: "disabled") == .on)
        #expect(DeviceInfo.parseStatus("FileVault is Off.", on: "FileVault is On", off: "FileVault is Off") == .off)
    }
}

@Suite struct FanCheckTests {
    static func reading(_ actual: Double, target: Double, index: Int = 0) -> FanReading {
        FanReading(index: index, actual: actual, minimum: 1200, maximum: 6000, target: target)
    }

    @Test func fanFollowingItsTargetPasses() {
        var check = FanCheck()
        check.add([Self.reading(1200, target: 1200)])
        for rpm in stride(from: 1200.0, through: 4000, by: 200) { check.add([Self.reading(rpm - 100, target: rpm)]) }
        #expect(check.verdict == .passed)
        #expect(check.fans[0].idle == 1200)
        #expect(check.fans[0].peak == 3900)
    }

    @Test func fanThatDoesNotTurnFails() {
        var check = FanCheck()
        for _ in 0..<10 { check.add([Self.reading(0, target: 2500)]) }
        #expect(check.verdict == .stalled(fan: 0, target: 2500))
    }

    @Test func slowFanFails() {
        var check = FanCheck()
        check.add([Self.reading(1200, target: 1200)])
        for _ in 0..<16 { check.add([Self.reading(1500, target: 3000)]) }
        #expect(check.verdict == .belowTarget(fan: 0, actual: 1500, target: 3000))
    }

    @Test func spinningUpTakesAFewSeconds() {
        var check = FanCheck()
        check.add([Self.reading(1200, target: 1200)])
        // Target jumps, the fan needs five seconds to get there: no failure.
        for rpm in [1300.0, 1800, 2300, 2900, 3500] { check.add([Self.reading(rpm, target: 4000)]) }
        for _ in 0..<20 { check.add([Self.reading(3900, target: 4000)]) }
        #expect(check.verdict == .passed)
    }

    @Test func fansOffWhileCoolAreNotAFailure() {
        // Apple Silicon MacBook Pro: fans off (target 0) until the Mac gets warm.
        var check = FanCheck()
        for _ in 0..<30 { check.add([FanReading(index: 0, actual: 0, minimum: 1200, maximum: 6000, target: 0)]) }
        #expect(check.verdict == .notAsked)
    }
}

@Suite struct XHCIPortTests {
    @Test func usbAPortsOfAnAir2014() {
        // MacBookAir6,1 root hub: HS01 / HS02 + SSP1 / SSP2 are the two USB 3 Type-A ports;
        // HS03 (Bluetooth hub) and HS05 (camera) are internal (255) and not passed in.
        let roots = [
            PortReader.RootPort(location: 0x1410_0000, name: "HS01", connector: 3, superSpeed: false, enumerationFailures: 0),
            PortReader.RootPort(location: 0x1420_0000, name: "HS02", connector: 3, superSpeed: false, enumerationFailures: 2),
            PortReader.RootPort(location: 0x1450_0000, name: "SSP1", connector: 3, superSpeed: true, enumerationFailures: nil),
            PortReader.RootPort(location: 0x1460_0000, name: "SSP2", connector: 3, superSpeed: true, enumerationFailures: nil),
        ]
        let connectors = PortReader.connectors(from: roots)
        #expect(connectors.count == 2)
        #expect(connectors.map(\.kind) == ["USB-A", "USB-A"])
        #expect(connectors[0].lanes.map(\.name) == ["HS01", "SSP1"])
        #expect(connectors[1].lanes.map(\.name) == ["HS02", "SSP2"])
    }

    @Test func typeCPortsOnTheirOwnController() {
        let roots = [
            PortReader.RootPort(location: 0x1410_0000, name: "HS01", connector: 3, superSpeed: false),
            PortReader.RootPort(location: 0x0110_0000, name: "HS01", connector: 9, superSpeed: false),
            PortReader.RootPort(location: 0x0130_0000, name: "SS01", connector: 9, superSpeed: true),
        ]
        let kinds = PortReader.connectors(from: roots).map(\.kind)
        #expect(kinds.sorted() == ["USB-A", "USB-C"])
    }
}
