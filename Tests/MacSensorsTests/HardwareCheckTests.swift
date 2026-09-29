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
