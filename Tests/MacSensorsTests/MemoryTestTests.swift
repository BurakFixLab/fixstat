import Foundation
import Testing
@testable import MacSensors

@Suite struct MemoryTestTests {
    @Test func smallRunPasses() {
        let result = MemoryTest().run(bytes: 8 << 20) { _ in }
        #expect(result.passed)
        #expect(result.patternsCompleted == MemoryTest.Pattern.allCases)
        #expect(result.bytes == 8 << 20)
    }

    @Test func detectsCorruption() {
        let count = 1024
        let buffer = UnsafeMutablePointer<UInt64>.allocate(capacity: count)
        defer { buffer.deallocate() }
        MemoryTest.write(.checkerboard, buffer: buffer, count: count, seed: 1)
        buffer[10] ^= 1 << 7 // flip one bit
        var result = MemoryTest.Result(startedAt: Date(), bytes: 8192, patternsCompleted: [], errorCount: 0,
                                       firstErrors: [], flippedBits: 0, seconds: 0, throughput: nil,
                                       cancelled: false, allocationFailed: false)
        MemoryTest.verify(.checkerboard, buffer: buffer, count: count, seed: 1, into: &result)
        #expect(result.errorCount == 1)
        #expect(result.firstErrors == [80])
        #expect(result.flippedBits == 1 << 7)
    }

    @Test func randomPatternIsReproducible() {
        var a: UInt64 = 5, b: UInt64 = 5
        let x = (0..<10).map { MemoryTest.expected(.random, index: $0, seed: 5, state: &a) }
        let y = (0..<10).map { MemoryTest.expected(.random, index: $0, seed: 5, state: &b) }
        #expect(x == y)
        #expect(Set(x).count == 10)
    }

    @Test func cancelStopsEarly() {
        let test = MemoryTest()
        test.cancel()
        let result = test.run(bytes: 1 << 20) { _ in }
        #expect(result.cancelled)
        #expect(result.patternsCompleted.isEmpty)
    }
}
