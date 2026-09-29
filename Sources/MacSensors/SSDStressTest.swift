import Foundation

/// Write–verify stress test for the internal SSD.
///
/// Writes a scratch file in chunks filled with a pseudo-random pattern derived
/// from the chunk index, reads it back with the page cache disabled and compares
/// every byte. Chunk timings reveal slow or stalling regions; mismatches and I/O
/// errors point to failing NAND or controller problems. Only free space can be
/// tested (raw disk access needs root), and the test consumes write endurance.
public final class SSDStressTest: @unchecked Sendable {
    public enum Phase: String, Codable, Sendable {
        case write, verify
    }

    public struct Progress: Sendable {
        public let phase: Phase
        public let chunk: Int
        public let chunkCount: Int
        /// MB/s of the chunk just finished.
        public let throughput: Double
    }

    public struct ChunkTiming: Codable, Sendable, Equatable {
        public let index: Int
        /// Seconds.
        public let write: Double
        public var read: Double?
    }

    public struct Result: Codable, Sendable, Equatable {
        public enum Finding: Codable, Sendable, Equatable {
            case dataMismatch(chunks: Int, firstChunk: Int)
            case ioErrors(count: Int)
            case slowChunks(count: Int, worstSeconds: Double)
            case smartMediaErrorsIncreased(by: Double)
            case smartErrorLogIncreased(by: Double)
            case stoppedEarly
            case notEnoughSpace
        }

        public var startedAt: Date
        public var plannedBytes: Double
        public var testedBytes: Double
        public var chunkSize: Int
        /// MB/s over the whole phase.
        public var writeSpeed: Double?
        public var readSpeed: Double?
        public var timings: [ChunkTiming]
        public var mismatchedChunks: [Int]
        public var ioErrors: Int
        public var healthBefore: NVMeHealth?
        public var healthAfter: NVMeHealth?
        public var findings: [Finding]

        public var passed: Bool { findings.allSatisfy { $0 == .stoppedEarly } }
    }

    public static let chunkSize = 8 << 20
    /// Free space always left on the volume.
    public static let reserveBytes: Int64 = 10 << 30
    /// A chunk is "slow" when it takes this many times the median, and at least `slowFloor` seconds.
    public static let slowFactor = 10.0
    public static let slowFloor = 0.5

    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Bytes that may be used for the test in `directory`.
    public static func availableBytes(in directory: URL) -> Int64 {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return max(0, free - reserveBytes)
    }

    /// Runs synchronously; call from a background thread.
    public func run(bytes requested: Int64, directory: URL, progress: @Sendable (Progress) -> Void) -> Result {
        let started = Date()
        let chunk = Self.chunkSize
        let available = Self.availableBytes(in: directory)
        let bytes = min(requested, available)
        let count = Int(bytes / Int64(chunk))
        var result = Result(startedAt: started, plannedBytes: Double(requested), testedBytes: 0, chunkSize: chunk,
                            timings: [], mismatchedChunks: [], ioErrors: 0,
                            healthBefore: SSDInfo.readHealth(), healthAfter: nil, findings: [])
        guard count > 0 else {
            result.findings = [.notEnoughSpace]
            return result
        }

        let url = directory.appendingPathComponent("fixstat-ssd-test-\(getpid()).bin")
        defer { unlink(url.path) }
        var buffer = [UInt8](repeating: 0, count: chunk)
        var expected = [UInt8](repeating: 0, count: chunk)
        let seed = UInt64(started.timeIntervalSince1970 * 1000)

        // Write phase.
        let wfd = open(url.path, O_CREAT | O_TRUNC | O_WRONLY, 0o600)
        guard wfd >= 0 else {
            result.findings = [.ioErrors(count: 1)]
            return result
        }
        _ = fcntl(wfd, F_NOCACHE, 1)
        var written = 0
        let writeStart = Date()
        for index in 0..<count {
            if isCancelled { break }
            Self.fill(&buffer, seed: seed, chunk: index)
            let t0 = Date()
            let n = buffer.withUnsafeBytes { pwrite(wfd, $0.baseAddress, chunk, off_t(index) * off_t(chunk)) }
            if n != chunk { result.ioErrors += 1 }
            // Flush regularly so the timings reflect the SSD, not the write-back cache.
            if index % 32 == 31 { fsync(wfd) }
            let seconds = Date().timeIntervalSince(t0)
            result.timings.append(ChunkTiming(index: index, write: seconds))
            written += 1
            progress(Progress(phase: .write, chunk: index + 1, chunkCount: count,
                              throughput: seconds > 0 ? Double(chunk) / seconds / 1e6 : 0))
        }
        _ = fcntl(wfd, F_FULLFSYNC)
        close(wfd)
        _ = writeStart
        // Speeds from the I/O time of the chunks only (pattern generation and
        // comparison are CPU work and would understate the SSD).
        let writeSeconds = result.timings.map(\.write).reduce(0, +)
        if written > 0, writeSeconds > 0 {
            result.writeSpeed = Double(written * chunk) / writeSeconds / 1e6
        }

        // Verify phase.
        let rfd = open(url.path, O_RDONLY)
        if rfd >= 0 {
            _ = fcntl(rfd, F_NOCACHE, 1)
            let readStart = Date()
            var read = 0
            for index in 0..<written {
                if isCancelled { break }
                let t0 = Date()
                let n = buffer.withUnsafeMutableBytes { pread(rfd, $0.baseAddress, chunk, off_t(index) * off_t(chunk)) }
                let seconds = Date().timeIntervalSince(t0)
                result.timings[index].read = seconds
                if n != chunk {
                    result.ioErrors += 1
                } else {
                    Self.fill(&expected, seed: seed, chunk: index)
                    if buffer != expected { result.mismatchedChunks.append(index) }
                }
                read += 1
                progress(Progress(phase: .verify, chunk: index + 1, chunkCount: written,
                                  throughput: seconds > 0 ? Double(chunk) / seconds / 1e6 : 0))
            }
            close(rfd)
            _ = readStart
            let readSeconds = result.timings.compactMap(\.read).reduce(0, +)
            if read > 0, readSeconds > 0 {
                result.readSpeed = Double(read * chunk) / readSeconds / 1e6
            }
            result.testedBytes = Double(read * chunk)
        } else {
            result.ioErrors += 1
        }

        result.healthAfter = SSDInfo.readHealth()
        result.findings = Self.findings(for: result, cancelled: isCancelled || written < count)
        return result
    }

    static func findings(for result: Result, cancelled: Bool) -> [Result.Finding] {
        var findings: [Result.Finding] = []
        if let first = result.mismatchedChunks.first {
            findings.append(.dataMismatch(chunks: result.mismatchedChunks.count, firstChunk: first))
        }
        if result.ioErrors > 0 { findings.append(.ioErrors(count: result.ioErrors)) }
        let slow = slowChunks(result.timings)
        if !slow.isEmpty {
            findings.append(.slowChunks(count: slow.count, worstSeconds: slow.max() ?? 0))
        }
        if let before = result.healthBefore, let after = result.healthAfter {
            if after.mediaErrors > before.mediaErrors {
                findings.append(.smartMediaErrorsIncreased(by: after.mediaErrors - before.mediaErrors))
            }
            if after.errorLogEntries > before.errorLogEntries {
                findings.append(.smartErrorLogIncreased(by: after.errorLogEntries - before.errorLogEntries))
            }
        }
        if cancelled { findings.append(.stoppedEarly) }
        return findings
    }

    /// Chunk durations (write or read) that are far above the median.
    static func slowChunks(_ timings: [ChunkTiming]) -> [Double] {
        func slow(_ values: [Double]) -> [Double] {
            guard values.count >= 8 else { return [] }
            let median = values.sorted()[values.count / 2]
            return values.filter { $0 >= max(slowFloor, median * slowFactor) }
        }
        return slow(timings.map(\.write)) + slow(timings.compactMap(\.read))
    }

    /// Deterministic pattern: xorshift64* seeded by the run seed and the chunk index,
    /// so every chunk (and every run) has different, reproducible content.
    static func fill(_ buffer: inout [UInt8], seed: UInt64, chunk: Int) {
        var state = seed ^ (UInt64(chunk) &* 0x9E37_79B9_7F4A_7C15) | 1
        buffer.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for i in 0..<words.count {
                state ^= state >> 12
                state ^= state << 25
                state ^= state >> 27
                words[i] = state &* 0x2545_F491_4F6C_DD1D
            }
        }
    }
}
