import Darwin
import Foundation

/// CPU and memory usage from Mach host statistics (no privileges needed).
public final class SystemStats {
    public struct Memory: Sendable, Equatable {
        /// Bytes in use, computed like Activity Monitor's "Memory Used":
        /// app memory (internal − purgeable) + wired + compressed.
        public let used: UInt64
        public let total: UInt64
    }

    private var previousTicks: [UInt32]?

    public init() {}

    /// Total CPU usage in 0…1 since the previous call (nil on the first call).
    public func cpuUsage() -> Double? {
        cpuLoad().map { $0.user + $0.system }
    }

    /// User (incl. nice) and system shares of all CPUs in 0…1 since the previous call. A high
    /// system share under a user load means the kernel takes the CPU (e.g. kernel_task
    /// keeping a hot or sensor-less Intel CPU idle).
    public func cpuLoad() -> (user: Double, system: Double)? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        // Sum user, system, idle, nice over all CPUs.
        var ticks = [UInt32](repeating: 0, count: Int(CPU_STATE_MAX))
        for cpu in 0..<Int(count) {
            for state in 0..<Int(CPU_STATE_MAX) {
                ticks[state] &+= UInt32(bitPattern: info[cpu * Int(CPU_STATE_MAX) + state])
            }
        }
        defer { previousTicks = ticks }
        guard let previous = previousTicks else { return nil }

        let delta = zip(ticks, previous).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        return ((delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_NICE)]) / total, delta[Int(CPU_STATE_SYSTEM)] / total)
    }

    /// CPU time used by this process so far (user + system), in seconds.
    public static func ownCPUTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    public func memory() -> Memory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return Memory(used: used, total: ProcessInfo.processInfo.physicalMemory)
    }
}
