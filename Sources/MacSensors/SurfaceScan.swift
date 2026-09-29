import Foundation

/// Result of a read-only full-surface scan (`fixstat-diskscan` output).
public struct SurfaceScanResult: Codable, Sendable, Equatable {
    public struct Region: Codable, Sendable, Equatable {
        /// Start offset in bytes.
        public let offset: Int64
        /// Read speed in MB/s over the region.
        public let speed: Double
    }

    public struct BadRange: Codable, Sendable, Equatable {
        public let offset: Int64
        public let length: Int
    }

    public var deviceSize: Int64
    public var bytesRead: Int64
    public var seconds: Double
    public var finished: Bool
    public var cancelled: Bool
    public var badRanges: [BadRange]
    /// Chunks far slower than the median (seconds).
    public var slowChunks: [Double]
    public var slowestChunkMs: Double
    /// Average speed in MB/s over the chunks' I/O time.
    public var averageSpeed: Double?
    /// Up to `regionCount` regions for a speed map.
    public var regions: [Region]

    public var fraction: Double { deviceSize > 0 ? Double(bytesRead) / Double(deviceSize) : 0 }
    public var passed: Bool { badRanges.isEmpty && slowChunks.isEmpty }

    public static let regionCount = 200

    /// Parses JSON lines (may be incomplete while the scan is running).
    public static func parse(_ text: String) -> SurfaceScanResult {
        var result = SurfaceScanResult(deviceSize: 0, bytesRead: 0, seconds: 0, finished: false, cancelled: false,
                                       badRanges: [], slowChunks: [], slowestChunkMs: 0, averageSpeed: nil, regions: [])
        var chunks: [(offset: Int64, length: Int, ms: Double)] = []
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            let number: (String) -> Double = { (object[$0] as? NSNumber)?.doubleValue ?? 0 }
            switch type {
            case "start":
                result.deviceSize = Int64(number("size"))
            case "chunk":
                chunks.append((Int64(number("offset")), Int(number("length")), number("ms")))
            case "error":
                result.badRanges.append(BadRange(offset: Int64(number("offset")), length: Int(number("length"))))
            case "end":
                result.finished = true
                result.seconds = number("seconds")
                result.cancelled = (object["cancelled"] as? Bool) ?? false
            default:
                break
            }
        }
        result.bytesRead = chunks.reduce(0) { $0 + Int64($1.length) }
        let totalMs = chunks.reduce(0) { $0 + $1.ms }
        if totalMs > 0 { result.averageSpeed = Double(result.bytesRead) / (totalMs / 1000) / 1e6 }
        result.slowestChunkMs = chunks.map(\.ms).max() ?? 0
        if chunks.count >= 8 {
            let median = chunks.map(\.ms).sorted()[chunks.count / 2]
            let limit = max(SSDStressTest.slowFloor * 1000, median * SSDStressTest.slowFactor)
            result.slowChunks = chunks.filter { $0.ms >= limit }.map { $0.ms / 1000 }
        }
        // Speed map: group consecutive chunks into at most `regionCount` regions.
        if !chunks.isEmpty {
            let expected = result.deviceSize > 0 ? Int(result.deviceSize / Int64(max(chunks[0].length, 1))) + 1 : chunks.count
            let perRegion = max(1, expected / regionCount)
            var index = 0
            while index < chunks.count {
                let group = chunks[index..<min(index + perRegion, chunks.count)]
                let bytes = group.reduce(0) { $0 + $1.length }
                let ms = group.reduce(0) { $0 + $1.ms }
                result.regions.append(Region(offset: group.first!.offset, speed: ms > 0 ? Double(bytes) / (ms / 1000) / 1e6 : 0))
                index += perRegion
            }
        }
        return result
    }
}

/// The internal physical disk that holds the startup volume.
public struct InternalDisk: Sendable, Equatable {
    /// e.g. "disk0"
    public let identifier: String
    public let size: Int64

    public var rawDevice: String { "/dev/r\(identifier)" }

    /// Uses `diskutil` (no root needed).
    public static func find() -> InternalDisk? {
        guard let root = diskutil(["info", "-plist", "/"]) else { return nil }
        var store = (root["APFSPhysicalStores"] as? [[String: Any]])?.first?["APFSPhysicalStore"] as? String
        if store == nil { store = root["ParentWholeDisk"] as? String }
        guard let partition = store, let info = diskutil(["info", "-plist", partition]),
              let whole = info["ParentWholeDisk"] as? String ?? (partition.contains("s") ? nil : partition),
              let wholeInfo = diskutil(["info", "-plist", whole]),
              (wholeInfo["Internal"] as? Bool) == true,
              let size = (wholeInfo["Size"] as? NSNumber)?.int64Value,
              whole.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return InternalDisk(identifier: whole, size: size)
    }

    private static func diskutil(_ arguments: [String]) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}
