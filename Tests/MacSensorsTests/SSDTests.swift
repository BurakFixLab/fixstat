import Foundation
import Testing
@testable import MacSensors

@Suite struct SSDTests {
    @Test func parsesSMARTLog() {
        var log = [UInt8](repeating: 0, count: 512)
        log[0] = 0b0000_0100          // reliability degraded
        log[1] = 0x3D; log[2] = 0x01  // 317 K = 43.85 °C
        log[3] = 100; log[4] = 99; log[5] = 3
        log[48] = 0x10; log[49] = 0x27 // 10 000 data units written
        log[128] = 0xA8; log[129] = 0x01 // 424 hours
        log[144] = 91
        log[160] = 2
        let h = NVMeHealth.parse(log)
        #expect(h?.percentageUsed == 3)
        #expect(h?.availableSpare == 100)
        #expect(abs((h?.temperature ?? 0) - 43.85) < 0.01)
        #expect(h?.bytesWritten == 5_120_000_000.0)
        #expect(h?.powerOnHours == 424)
        #expect(h?.unsafeShutdowns == 91)
        #expect(h?.mediaErrors == 2)
        #expect(h?.warnings == ["reliabilityDegraded"])
        #expect(NVMeHealth.parse([0, 1]) == nil)
    }

    @Test func patternIsDeterministicAndDistinct() {
        var a = [UInt8](repeating: 0, count: 4096)
        var b = a, c = a
        SSDStressTest.fill(&a, seed: 42, chunk: 7)
        SSDStressTest.fill(&b, seed: 42, chunk: 7)
        SSDStressTest.fill(&c, seed: 42, chunk: 8)
        #expect(a == b)
        #expect(a != c)
        #expect(Set(a).count > 200) // looks random
    }

    @Test func slowChunkDetection() {
        var timings = (0..<20).map { SSDStressTest.ChunkTiming(index: $0, write: 0.02, read: 0.01) }
        timings[5] = .init(index: 5, write: 2.5, read: 0.01)
        #expect(SSDStressTest.slowChunks(timings) == [2.5])
        let fine = (0..<20).map { SSDStressTest.ChunkTiming(index: $0, write: 0.02, read: 0.3) }
        #expect(SSDStressTest.slowChunks(fine).isEmpty)
    }

    @Test func findings() {
        var before = NVMeHealth.parse([UInt8](repeating: 0, count: 512))!
        before.mediaErrors = 1
        var after = before
        after.mediaErrors = 4
        let result = SSDStressTest.Result(startedAt: Date(), plannedBytes: 1, testedBytes: 1, chunkSize: 1,
                                          writeSpeed: 1, readSpeed: 1, timings: [], mismatchedChunks: [3, 9],
                                          ioErrors: 1, healthBefore: before, healthAfter: after, findings: [])
        let found = SSDStressTest.findings(for: result, cancelled: false)
        #expect(found.contains(.dataMismatch(chunks: 2, firstChunk: 3)))
        #expect(found.contains(.ioErrors(count: 1)))
        #expect(found.contains(.smartMediaErrorsIncreased(by: 3)))
    }
}

@Suite struct SurfaceScanTests {
    @Test func parsesScanOutput() {
        var lines = [#"{"type":"start","device":"/dev/rdisk0","size":83886080,"chunk":8388608}"#]
        for i in 0..<10 {
            let ms = i == 4 ? 900.0 : 4.0
            lines.append(#"{"type":"chunk","offset":\#(i * 8_388_608),"length":8388608,"ms":\#(ms)}"#)
        }
        lines.append(#"{"type":"error","offset":33554432,"length":262144,"errno":5}"#)
        lines.append(#"{"type":"end","bytes":83886080,"seconds":1.2,"cancelled":false}"#)
        let r = SurfaceScanResult.parse(lines.joined(separator: "\n"))
        #expect(r.finished)
        #expect(r.bytesRead == 83_886_080)
        #expect(r.fraction == 1)
        #expect(r.badRanges == [.init(offset: 33_554_432, length: 262_144)])
        #expect(r.slowChunks == [0.9])
        #expect(!r.passed)
        #expect(r.regions.count == 10)
    }

    @Test func partialOutputWhileRunning() {
        let text = #"{"type":"start","size":800,"chunk":8}"# + "\n" + #"{"type":"chunk","offset":0,"length":8,"ms":1}"# + "\n" + #"{"type":"chu"#
        let r = SurfaceScanResult.parse(text)
        #expect(!r.finished)
        #expect(r.bytesRead == 8)
        #expect(abs(r.fraction - 0.01) < 1e-9)
    }
}
