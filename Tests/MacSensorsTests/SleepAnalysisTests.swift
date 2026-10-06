import Foundation
import Testing
@testable import MacSensors

@Suite struct SleepAnalysisTests {
    static let log = """
        2026-09-25 11:31:59 +0300 Sleep               \tEntering Sleep state due to 'Idle Sleep':TCPKeepAlive=active Using Batt (Charge:80%) 7200 secs
        2026-09-25 12:10:00 +0300 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to RTC/Maintenance Using BATT (Charge:79%) 45 secs
        2026-09-25 12:10:45 +0300 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:79%) 4000 secs
        2026-09-25 13:31:59 +0300 Wake                \tWake from Normal Sleep [CDNVA] : due to EC.LidOpen/Lid Open Using BATT (Charge:77%)
        2026-09-25 13:32:00 +0300 WakeTime            \tWakeTime: 3.235 sec
        2026-09-25 13:32:00 +0300 Kernel Client Acks  \tDelays to Wake notifications: [AppleSEPManager driver is slow(msg: SetState to 2)(330 ms)] [CoreKDLDriver driver is slow(msg: SetState to 1)(3233 ms)]
        2026-09-25 13:40:00 +0300 Assertions          \tPID 29772(Claude) Released NoIdleSleepAssertion "Electron" 01:06:44  id:0x0x10000992c [System: PrevIdle DeclUser kDisp]
        2026-09-25 13:41:00 +0300 Assertions          \tPID 108(powerd) Released PreventUserIdleSystemSleep "Powerd" 02:00:00  id:0x1 [System: PrevIdle]
        2026-09-25 14:00:00 +0300 BatteryHealth       \tWarning level: 2 time: 30 cap: 10
        2026-09-26 11:01:10 +0300 Sleep               \tEntering Sleep state due to 'Low Power Sleep':TCPKeepAlive=inactive Using Batt (Charge:1%) 24 secs
        2026-09-26 11:01:34 +0300 Wake                \tWake from Hibernate [CDNVA] : due to acattach/UserActivity Assertion Using AC (Charge:1%)
        """

    @Test func parsesEvents() {
        let a = SleepAnalysis.parse(log: Self.log)
        #expect(a.sleeps.count == 3)
        #expect(a.wakes.count == 2)
        #expect(a.darkWakes.count == 1)
        #expect(a.lowPowerSleeps == 1)
        #expect(a.sleeps[0].reason == "Idle Sleep")
        #expect(a.sleeps[0].charge == 80)
        #expect(a.sleeps[0].onBattery == true)
        #expect(a.sleeps[0].duration == 7200)
        #expect(a.darkWakes[0].reason == "RTC/Maintenance")
        #expect(a.darkWakes[0].duration == 45)
        #expect(a.wakes[0].reason == "EC.LidOpen/Lid Open")
        #expect(a.wakes[1].onBattery == false)
        #expect(a.averageWakeTime == 3.235)
        #expect(a.lowBatteryWarnings == 1)
        #expect(a.reasons(.wake).count == 2)
    }

    @Test func drainAndDrivers() {
        let a = SleepAnalysis.parse(log: Self.log)
        // 80 → 79 over 38 min, 79 → 77 over 81 min; the 24 s sleep is too short.
        let drain = a.sleepDrain!
        #expect(drain.segments == 2)
        #expect(abs(drain.percentPerHour - 3 / ((38 * 60 + 1 + 81 * 60 + 14) / 3600.0)) < 0.01)
        #expect(a.slowDrivers.first?.driver == "AppleSEPManager" || a.slowDrivers.first?.driver == "CoreKDLDriver")
        #expect(a.slowDrivers.contains { $0.driver == "CoreKDLDriver" && $0.maxMilliseconds == 3233 })
        #expect(a.preventers == [.init(process: "Claude", count: 1, longestSeconds: 4004)])
    }

    @Test func settings() {
        let text = """
            System-wide power settings:
            Currently in use:
             standby              1
             Sleep On Power Button 1
             sleep                1 (sleep prevented by powerd, Claude)
             displaysleep         0
            """
        let (settings, preventing) = SleepAnalysis.parseSettings(text)
        #expect(settings["standby"] == "1")
        #expect(settings["sleep"] == "1")
        #expect(settings["Sleep On Power Button"] == "1")
        #expect(settings["displaysleep"] == "0")
        #expect(preventing == ["powerd", "Claude"])
    }

    @Test func systemWideSleepDisabled() {
        // `pmset -g` on a bench Mac set never to sleep (MacBookAir6,1, macOS 11): tab separated.
        let text = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep                1\n"
        #expect(SleepAnalysis.parseSettings(text).settings["SleepDisabled"] == "1")
    }
}

@Suite struct OffStateDrainTests {
    static let log = """
        2026-09-24 09:49:37 +0300 Assertions          \tSummary- [System: PrevIdle DeclUser kDisp] Using Batt(Charge: 17)
        2026-09-24 14:25:09 +0300 Start               \tpowerd process is started
        2026-09-24 14:25:09 +0300 Assertions          \tSummary- [System: No Assertions] Using AC(Charge: 15)
        2026-09-25 08:00:00 +0300 Assertions          \tSummary- [System: No Assertions] Using Batt(Charge: 40)
        2026-09-25 12:00:00 +0300 Assertions          \tSummary- [System: No Assertions] Using AC(Charge: 38)
        """

    static func date(_ s: String) -> Date { SleepAnalysis.dateFormatter.date(from: s)! }

    @Test func fromLog() {
        let records: [(date: Date, isBoot: Bool)] = [
            (Self.date("2026-09-24 10:01:55 +0300"), false),
            (Self.date("2026-09-24 14:25:04 +0300"), true),
            // Power loss: no shutdown record before this boot.
            (Self.date("2026-09-25 11:59:00 +0300"), true),
        ]
        let periods = OffStateDrain.fromLog(Self.log, records: records, fullChargeCapacity: 3200)
        #expect(periods.count == 2)
        #expect(periods[0].chargeBefore == 17)
        #expect(periods[0].chargeAfter == 15)
        #expect(!periods[0].shutdownEstimated)
        #expect(abs(periods[0].hours - 4.386) < 0.01)
        #expect(abs((periods[0].lostMAh ?? 0) - 64) < 0.01)
        #expect(periods[1].shutdownEstimated)
        #expect(periods[1].shutdown == Self.date("2026-09-25 08:00:00 +0300"))
        let summary = OffStateDrain.summary(periods)!
        #expect(abs(summary.hours - (4.386 + 3.983)) < 0.01)
        #expect(abs((summary.percentPerHour ?? 0) - 4 / summary.hours) < 0.001)
    }

    @Test func measured() {
        let mark = OffStateDrain.PowerOffMark(date: Self.date("2026-09-24 20:00:00 +0300"), remaining: 2000,
                                              charge: 62, fullChargeCapacity: 3200)
        let boot = Self.date("2026-09-25 08:00:00 +0300")
        let period = OffStateDrain.measured(mark: mark, records: [(boot, true)], now: boot.addingTimeInterval(60),
                                            remaining: 1964, charge: 61)!
        #expect(period.averageCurrent == 3) // 36 mAh in 12 h
        #expect(period.isUsable)
        #expect(OffStateDrain.measured(mark: mark, records: [(boot, true)], now: boot.addingTimeInterval(3600),
                                       remaining: 1964, charge: 61) == nil)
    }
}
