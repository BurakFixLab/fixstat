import Foundation
import MacSensors

public enum MemoryText {
    public static func pattern(_ p: MemoryTest.Pattern) -> String {
        switch p {
        case .zeros: L("All zeros")
        case .ones: L("All ones")
        case .checkerboard: L("Checkerboard")
        case .walkingOnes: L("Walking ones")
        case .addressInAddress: L("Address in address")
        case .random: L("Random data")
        }
    }

    public static func rows(_ r: MemoryTest.Result) -> [(String, String)] {
        var rows: [(String, String)] = [
            (L("Tested"), Format.bytes(Double(r.bytes))),
            (L("Patterns"), "\(r.patternsCompleted.count) / \(MemoryTest.Pattern.allCases.count)"),
            (L("Rounds"), Format.number(Double(r.roundsCompleted))),
            (L("Errors"), Format.number(Double(r.errorCount))),
            (L("Duration"), Format.minutesSeconds(r.seconds)),
        ]
        if let t = r.throughput {
            rows.append((L("Throughput"), Format.speed(megabytesPerSecond: t * 1000)))
        }
        if r.errorCount > 0 {
            rows.append((L("Flipped bits"), String(format: "0x%016llX", r.flippedBits)))
            rows.append((L("First failing offsets"),
                         r.firstErrors.prefix(4).map { String(format: "0x%llX", $0) }.joined(separator: ", ")))
        }
        if r.cancelled {
            rows.append((L("Note"), L("Test was stopped before the planned duration")))
        }
        return rows
    }
}
