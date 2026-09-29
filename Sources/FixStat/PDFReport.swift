import AppKit
import MacSensors
import SwiftUI

/// One-page A4 customer report rendered from SwiftUI.
enum PDFReport {
    static let pageSize = CGSize(width: 595, height: 842) // A4 in points

    @MainActor
    static func render(monitor: Monitor) -> Data? {
        let page = ReportPage(snapshot: .init(monitor: monitor))
            .frame(width: pageSize.width, height: pageSize.height, alignment: .top)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: page)
        renderer.proposedSize = ProposedViewSize(pageSize)
        let data = NSMutableData()
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
        }
        return data.length > 0 ? data as Data : nil
    }
}

/// Values captured for the report (serials are always masked).
struct ReportSnapshot {
    let date = Date()
    let system: SystemInfo
    let battery: BatteryInfo?
    let temperatures: [(LocalizedStringKey, Double)]
    let test: StressTestResult?
    let ssd: SSDInfo?
    let ssdTest: SSDStressTest.Result?
    let panics: [PanicReport]
    let shutdowns: [ShutdownEvent]?
    let shopName: String
    let note: String

    @MainActor
    init(monitor: Monitor) {
        system = monitor.system
        battery = BatteryReader.read(includeSerial: false)
        let groups: [(LocalizedStringKey, [String])] = [
            ("Performance clusters", ["cpu.pcluster"]), ("Efficiency clusters", ["cpu.ecluster"]),
            ("CPU", ["cpu.core", "cpu.die", "cpu.proximity"]), ("GPU", ["gpu."]),
            ("SSD (NAND)", ["ssd."]), ("Enclosure", ["chassis.skin", "chassis.palmrest"]),
            ("Battery", ["battery."]),
        ]
        temperatures = groups.compactMap { title, prefixes in
            monitor.maximum(idPrefixes: prefixes, excluding: []).map { (title, $0) }
        }
        test = monitor.lastTestResult
        ssd = SSDInfo.read(includeSerial: false)
        ssdTest = monitor.lastSSDResult
        panics = monitor.lastCrashScan?.panics ?? CrashHistory.panics()
        shutdowns = monitor.lastCrashScan?.shutdowns
        let defaults = UserDefaults.standard
        shopName = defaults.string(forKey: Pref.reportShopName) ?? ""
        note = defaults.string(forKey: Pref.reportNote) ?? ""
    }
}

private struct ReportPage: View {
    let snapshot: ReportSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            device
            if let battery = snapshot.battery {
                batterySection(battery)
                chargingSection(battery)
            }
            temperatureSection
            if let ssd = snapshot.ssd {
                ssdSection(ssd)
            }
            crashSection
            if let test = snapshot.test {
                testSection(test)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(36)
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.black)
        .background(.white)
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                if !snapshot.shopName.isEmpty {
                    Text(verbatim: snapshot.shopName).font(.system(size: 16, weight: .semibold))
                }
                Text("Mac inspection report").font(.system(size: 13, weight: .medium))
            }
            Spacer()
            Text(snapshot.date.formatted(date: .long, time: .shortened)).foregroundStyle(.gray)
        }
    }

    private var device: some View {
        ReportGroup(title: "Device") {
            ReportRow(title: "Mac", value: snapshot.system.marketingName ?? snapshot.system.model)
            ReportRow(title: "Model identifier", value: [snapshot.system.model, snapshot.system.boardTarget]
                .compactMap { $0 }.joined(separator: " · "))
            ReportRow(title: "Chip", value: snapshot.system.chip)
            ReportRow(title: "macOS", value: snapshot.system.osVersion)
        }
    }

    private func batterySection(_ b: BatteryInfo) -> some View {
        let analysis = CellAnalysis(battery: b)
        return ReportGroup(title: "Battery") {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    ReportRow(title: "Health", value: b.healthPercent.map { Format.percent($0, digits: 1) })
                    ReportRow(title: "Cycles", value: b.cycleCount.map { Format.number(Double($0)) })
                    ReportRow(title: "Design capacity", value: b.designCapacity.map(Format.milliampHours))
                    ReportRow(title: "Maximum capacity", value: b.rawMaxCapacity.map(Format.milliampHours))
                    ReportRow(title: "Temperature", value: b.temperature.map { Format.temperature($0) })
                    ReportRow(title: "Serial", value: b.serial)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 2) {
                        GridRow {
                            Text("Cell").gridColumnAlignment(.leading)
                            Text("Voltage")
                            Text("Qmax")
                            Text("Resistance")
                        }
                        .foregroundStyle(.gray)
                        ForEach(analysis.cells, id: \.number) { cell in
                            GridRow {
                                Text("Cell \(cell.number)").gridColumnAlignment(.leading)
                                Text(cell.voltage.map { Format.volts(millivolts: $0, digits: 3) } ?? "–")
                                Text(cell.qmax.map(Format.milliampHours) ?? "–")
                                Text(cell.resistance.map { Format.number(Double($0)) } ?? "–")
                            }
                            .fontWeight(cell.isSuspect ? .semibold : .regular)
                        }
                    }
                    if analysis.suspects.isEmpty {
                        Text("Cells are consistent.").foregroundStyle(.gray)
                    } else {
                        ForEach(analysis.suspects, id: \.number) { cell in
                            Text(verbatim: "⚠︎ " + cellFinding(cell)).fontWeight(.semibold)
                        }
                    }
                }
            }
        }
    }

    private func cellFinding(_ cell: CellAnalysis.Cell) -> String {
        var parts: [String] = []
        if cell.highResistance, let d = cell.resistanceDeviation {
            parts.append(String(localized: "resistance \(signed(d)) vs. average"))
        }
        if cell.lowCapacity, let d = cell.qmaxDeviation {
            parts.append(String(localized: "Qmax \(signed(d)) vs. average"))
        }
        return String(localized: "Cell \(cell.number): \(parts.joined(separator: ", "))")
    }

    private func signed(_ fraction: Double) -> String {
        (fraction * 100).formatted(.number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false))) + " %"
    }

    private func chargingSection(_ b: BatteryInfo) -> some View {
        ReportGroup(title: "Power") {
            ReportRow(title: "State", value: BatteryText.state(b))
            if let adapter = b.adapter {
                ReportRow(title: "Power adapter", value: [adapter.name, adapter.ratedWatts.map { Format.watts(Double($0)) }]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            if let active = b.powerDelivery?.activeProfile, b.externalConnected == true {
                ReportRow(title: "Contract", value: [active.maxVoltage.map { Format.volts(millivolts: $0, digits: 0) },
                                                    active.maxCurrent.map { Format.amps(milliamps: $0) }]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            if let life = b.lifetime {
                ReportRow(title: "Highest temperature (lifetime)", value: life.maximumTemperature.map { Format.temperature($0) })
            }
        }
    }

    private var temperatureSection: some View {
        ReportGroup(title: "Temperatures (at report time)") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 3) {
                ForEach(Array(snapshot.temperatures.enumerated()), id: \.offset) { _, entry in
                    ReportRow(title: entry.0, value: Format.temperature(entry.1))
                }
            }
        }
    }

    private func ssdSection(_ ssd: SSDInfo) -> some View {
        ReportGroup(title: "SSD") {
            ReportRow(title: "Model", value: [ssd.model, ssd.capacity.map { Format.bytes($0) }]
                .compactMap { $0 }.joined(separator: " · "))
            if let h = ssd.health {
                let findings = SSDText.healthFindings(h)
                ReportRow(title: "Health (SMART)", value: findings.isEmpty ? String(localized: "SSD health is good.") : findings.joined(separator: " "))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 3) {
                    ForEach(Array(SSDText.healthRows(h).prefix(8).enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(verbatim: row.0).foregroundStyle(.gray)
                            Spacer()
                            Text(verbatim: row.1)
                        }
                    }
                }
            }
            if let test = snapshot.ssdTest {
                let problems = test.findings.filter { $0 != .stoppedEarly }
                ReportRow(title: "Write–verify stress test",
                          value: (problems.isEmpty ? String(localized: "No problems found") : String(localized: "Needs attention"))
                            + " · " + SSDText.resultRows(test).prefix(3).map(\.1).joined(separator: " · "))
                ForEach(Array(problems.enumerated()), id: \.offset) { _, finding in
                    Text(verbatim: "• " + SSDText.finding(finding))
                }
            }
        }
    }

    private var crashSection: some View {
        ReportGroup(title: "Panics and shutdowns") {
            ReportRow(title: "Kernel panics", value: snapshot.panics.isEmpty ? String(localized: "none")
                      : Format.number(Double(snapshot.panics.count)))
            ForEach(Array(snapshot.panics.prefix(3).enumerated()), id: \.offset) { _, panic in
                Text(verbatim: "• " + panic.date.formatted(date: .abbreviated, time: .shortened) + " — "
                     + (panic.area.map(CrashText.area) ?? "") + " " + String(panic.summary.prefix(90)))
                    .lineLimit(1)
            }
            if let shutdowns = snapshot.shutdowns {
                let faults = shutdowns.filter(\.isFault)
                ReportRow(title: "Abnormal shutdowns (30 days)", value: faults.isEmpty ? String(localized: "none")
                          : faults.prefix(4).map { "\($0.code)" }.joined(separator: ", "))
            }
        }
    }

    private func testSection(_ test: StressTestResult) -> some View {
        let problems = test.findings.filter { $0 != .stoppedEarly }
        return ReportGroup(title: "Post-repair test") {
            Text(problems.isEmpty ? "No problems found" : "Needs attention")
                .font(.system(size: 11, weight: .semibold))
            ForEach(Array(test.findings.enumerated()), id: \.offset) { _, finding in
                Text(verbatim: "• " + TestText.finding(finding))
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 3) {
                ForEach(TestText.summaryRows(test), id: \.0) { row in
                    HStack {
                        Text(verbatim: row.0).foregroundStyle(.gray)
                        Spacer()
                        Text(verbatim: row.1)
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !snapshot.note.isEmpty {
                Text(verbatim: snapshot.note)
            }
            Divider()
            Text("Created with FixStat \(AboutInfo.version) — github.com/BurakFixLab/fixstat. Serial numbers are masked.")
                .foregroundStyle(.gray)
                .font(.system(size: 8))
        }
    }
}

private struct ReportGroup<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .textCase(.uppercase)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.gray)
            content
        }
    }
}

private struct ReportRow: View {
    let title: LocalizedStringKey
    let value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.gray)
            Spacer(minLength: 8)
            Text(value ?? "–")
        }
    }
}
