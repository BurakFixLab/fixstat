import Darwin
import Foundation

/// Installed memory as reported by System Information, plus current pressure.
public struct MemoryInfo: Codable, Sendable, Equatable {
    public var totalBytes: UInt64
    public var type: String?
    public var manufacturer: String?
    public var swapUsedBytes: UInt64?
    public var compressedBytes: UInt64?

    public static func read() -> MemoryInfo {
        var info = MemoryInfo(totalBytes: ProcessInfo.processInfo.physicalMemory)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPMemoryDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = root["SPMemoryDataType"] as? [[String: Any]], let first = items.first {
                info.type = first["dimm_type"] as? String
                info.manufacturer = first["dimm_manufacturer"] as? String
            }
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            info.swapUsedBytes = swap.xsu_used
        }
        if let stats = vmStatistics() {
            info.compressedBytes = UInt64(stats.compressor_page_count) * UInt64(getpagesize())
        }
        return info
    }

    static func vmStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    /// Memory that can be used without pushing other apps into swap:
    /// 60 % of free + inactive + speculative + purgeable pages.
    public static func testableBytes() -> UInt64 {
        guard let s = vmStatistics() else { return 0 }
        let pages = UInt64(s.free_count) + UInt64(s.inactive_count) + UInt64(s.speculative_count) + UInt64(s.purgeable_count)
        return pages * UInt64(getpagesize()) * 6 / 10
    }
}

/// User-space memory test: fills a buffer with several patterns and verifies them.
///
/// It can only test memory macOS hands to the app (not kernel memory, and pages
/// may be compressed or moved), so it finds clear faults but does not replace
/// a boot-time memory test or Apple Diagnostics.
public final class MemoryTest: @unchecked Sendable {
    public enum Pattern: String, CaseIterable, Codable, Sendable {
        case zeros, ones, checkerboard, walkingOnes, addressInAddress, random
    }

    public struct Progress: Sendable {
        public let pattern: Pattern
        public let patternIndex: Int
        public let patternCount: Int
        /// 0…1 within the whole test.
        public let fraction: Double
    }

    public struct Result: Codable, Sendable, Equatable {
        public var startedAt: Date
        public var bytes: UInt64
        public var patternsCompleted: [Pattern]
        /// Full rounds of all patterns completed.
        public var roundsCompleted: Int = 0
        public var errorCount: Int
        /// Byte offsets of the first failing words (at most 16).
        public var firstErrors: [UInt64]
        /// OR of all flipped bits seen; a single repeated bit hints at a stuck line.
        public var flippedBits: UInt64
        public var seconds: Double
        /// GB/s over all write and verify passes.
        public var throughput: Double?
        public var cancelled: Bool
        public var allocationFailed: Bool

        public var passed: Bool { errorCount == 0 && !allocationFailed }
    }

    private let lock = NSLock()
    private var cancelledFlag = false

    public init() {}

    public func cancel() { lock.lock(); cancelledFlag = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelledFlag }

    /// Runs synchronously; call from a background thread.
    public func run(bytes requested: UInt64, rounds: Int = 1, progress: @Sendable (Progress) -> Void) -> Result {
        let start = Date()
        let words = Int(requested / 8)
        var result = Result(startedAt: start, bytes: UInt64(words) * 8, patternsCompleted: [], errorCount: 0,
                            firstErrors: [], flippedBits: 0, seconds: 0, throughput: nil, cancelled: false,
                            allocationFailed: false)
        guard words > 0, let raw = mmap(nil, words * 8, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0),
              raw != MAP_FAILED else {
            result.allocationFailed = true
            return result
        }
        defer { munmap(raw, words * 8) }
        let buffer = raw.bindMemory(to: UInt64.self, capacity: words)
        let patterns = Pattern.allCases
        let seed = UInt64(start.timeIntervalSince1970 * 1000) | 1
        var passes = 0.0

        let total = Double(patterns.count * max(rounds, 1))
        rounds: for round in 0..<max(rounds, 1) {
            for (index, pattern) in patterns.enumerated() {
                if isCancelled { result.cancelled = true; break rounds }
                let step = Double(round * patterns.count + index)
                // Write, then verify in a second sweep so values have to survive in memory.
                Self.write(pattern, buffer: buffer, count: words, seed: seed &+ UInt64(round))
                progress(Progress(pattern: pattern, patternIndex: index, patternCount: patterns.count,
                                  fraction: (step + 0.5) / total))
                Self.verify(pattern, buffer: buffer, count: words, seed: seed &+ UInt64(round), into: &result)
                passes += 2
                if round == 0 { result.patternsCompleted.append(pattern) }
                progress(Progress(pattern: pattern, patternIndex: index, patternCount: patterns.count,
                                  fraction: (step + 1) / total))
            }
            result.roundsCompleted = round + 1
        }
        result.seconds = Date().timeIntervalSince(start)
        if result.seconds > 0, passes > 0 {
            result.throughput = Double(result.bytes) * passes / result.seconds / 1e9
        }
        return result
    }

    static func expected(_ pattern: Pattern, index: Int, seed: UInt64, state: inout UInt64) -> UInt64 {
        switch pattern {
        case .zeros: return 0
        case .ones: return ~0
        case .checkerboard: return index % 2 == 0 ? 0x5555_5555_5555_5555 : 0xAAAA_AAAA_AAAA_AAAA
        case .walkingOnes: return 1 << UInt64(index % 64)
        case .addressInAddress: return UInt64(index) &* 8
        case .random:
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 0x2545_F491_4F6C_DD1D
        }
    }

    static func write(_ pattern: Pattern, buffer: UnsafeMutablePointer<UInt64>, count: Int, seed: UInt64) {
        var state = seed
        for i in 0..<count {
            buffer[i] = expected(pattern, index: i, seed: seed, state: &state)
        }
    }

    static func verify(_ pattern: Pattern, buffer: UnsafeMutablePointer<UInt64>, count: Int, seed: UInt64,
                       into result: inout Result) {
        var state = seed
        for i in 0..<count {
            let want = expected(pattern, index: i, seed: seed, state: &state)
            let got = buffer[i]
            if got != want {
                result.errorCount += 1
                result.flippedBits |= got ^ want
                if result.firstErrors.count < 16 { result.firstErrors.append(UInt64(i) * 8) }
            }
        }
    }
}
