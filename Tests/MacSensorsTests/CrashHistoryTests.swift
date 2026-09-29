import Foundation
import Testing
@testable import MacSensors

@Suite struct CrashHistoryTests {
    static let appleSiliconPanic = """
    {"bug_type":"210","timestamp":"2026-09-20 14:03:11.00 +0300","os_version":"macOS 26.6"}
    {"panicString":"panic(cpu 4 caller 0xfffffe0012345678): SMC PANIC - ASSERTION FAILED\\nDebugger message: panic\\nPanicked task 0xfffffe1: pid 0: kernel_task\\nKernel Extensions in backtrace:\\n","build":"25G83"}
    """

    @Test func parsesAppleSiliconPanic() throws {
        let report = try #require(PanicReport.parse(Self.appleSiliconPanic, fileDate: Date()))
        #expect(report.summary.hasPrefix("panic(cpu 4"))
        #expect(report.area == "smc")
        #expect(report.panickedProcess == "pid 0: kernel_task")
        #expect(abs(report.date.timeIntervalSince1970 - 1_789_902_191) < 1)
    }

    @Test func areaFallsBackToFullText() {
        let text = """
        {"bug_type":"210"}
        {"panicString":"panic(cpu 0 caller 0x1): userspace watchdog timeout: no successful checkins from WindowServer"}
        """
        #expect(PanicReport.parse(text, fileDate: Date())?.area == "watchdog")
    }

    @Test func ignoresOtherReports() {
        let crash = """
        {"bug_type":"309","timestamp":"2026-09-20 14:03:11.00 +0300"}
        {"panicString":"x"}
        """
        #expect(PanicReport.parse(crash, fileDate: Date()) == nil)
        #expect(PanicReport.parse("not json", fileDate: Date()) == nil)
    }

    @Test func readsPanicFilesFromDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("panic-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.appleSiliconPanic.write(to: dir.appendingPathComponent("panic-full-2026-09-20-140311.0002.panic"),
                                         atomically: true, encoding: .utf8)
        try "ignored".write(to: dir.appendingPathComponent("Something.diag"), atomically: true, encoding: .utf8)
        let panics = CrashHistory.panics(in: [dir])
        #expect(panics.count == 1)
    }

    @Test func parsesShutdownCauses() {
        let ndjson = """
        {"timestamp":"2026-09-26 13:12:48.123456+0300","eventMessage":"Previous shutdown cause: -128"}
        {"timestamp":"2026-09-20 09:00:01.000000+0300","eventMessage":"Previous shutdown cause: 5"}
        {"timestamp":"2026-09-20 09:00:01.000000+0300","eventMessage":"unrelated"}
        """
        let events = ShutdownEvent.parse(ndjson: ndjson)
        #expect(events.map(\.code) == [-128, 5])
        #expect(events[0].isFault)
        #expect(!events[1].isFault)
        #expect(events[0].meaning == "unknownCritical")
    }
}
