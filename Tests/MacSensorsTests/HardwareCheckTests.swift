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
        #expect(HardwareCheck.items(for: HardwareProfile(kind: .notebook, hasBattery: true)) == HardwareCheck.Item.allCases)

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
