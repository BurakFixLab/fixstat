import Foundation
import Testing
@testable import FixStatCore

@Suite struct LiveMonitorTests {
    @Test func csvHasAColumnPerChannelAndTheMarkers() {
        let power = LiveMonitor.Channel(id: "smc:PSTR", title: "System total", detail: "PSTR", unit: .watts,
                                        group: .power, source: .smc("PSTR"))
        let rail = LiveMonitor.Channel(id: "smc:PP0b", title: "PMU buck 0, CPU", detail: "PP0b", unit: .watts,
                                       group: .rails, source: .smc("PP0b"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = (0..<4).map { i in
            LiveMonitor.Sample(time: start.addingTimeInterval(Double(i) * 0.5),
                               values: i == 2 ? ["smc:PSTR": 9.5] : ["smc:PSTR": 9.5 + Double(i), "smc:PP0b": 1.25])
        }
        let csv = LiveMonitor.csv(rows, channels: [power, rail], markers: [start.addingTimeInterval(0.7)])
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.count == 5)
        // A comma in a title is quoted.
        #expect(lines[0] == #"time,seconds,System total [W],"PMU buck 0, CPU [W]",marker"#)
        #expect(lines[1].hasSuffix(",0.00,9.5,1.25,"))
        // The marker at 0.7 s lands on the row at 1.0 s; a missing value stays empty.
        #expect(lines[3].hasSuffix(",1.00,9.5,,M1"))
    }
}
