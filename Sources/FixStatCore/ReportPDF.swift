import AppKit
import MacSensors

/// Values captured for the customer report (serials are always masked).
public struct ReportData {
    public let date = Date()
    public let system: SystemInfo
    public let battery: BatteryInfo?
    public let temperatures: [(title: String, value: Double)]
    public let test: StressTestResult?
    public let ssd: SSDInfo?
    public let ssdTest: SSDStressTest.Result?
    public let panics: [PanicReport]
    public let shutdowns: [ShutdownEvent]?
    public let memoryResult: MemoryTest.Result?
    public let batteryCheck: PartCheck?
    public let adapterCheck: PartCheck?
    public let macOSHealth: MacOSBatteryHealth?
    public let device: DeviceInfo
    public let shopName: String
    public let note: String
    public let hardwareCheck: HardwareCheck?
    /// Serial numbers are shown in full (Settings › PDF report), otherwise masked.
    public let fullSerial: Bool
    public let sleep: SleepAnalysis?
    public let offPeriods: [OffPeriod]
    public let capacity: CapacityResult?
    /// Drain detective (notebooks with a battery).
    public let drain: DrainReport?

    /// Reads what the report needs (system_profiler, SMART, panics: about a second).
    public init(monitor: MonitorCore) {
        system = monitor.system
        fullSerial = Pref.reportsShowSerial
        battery = BatteryReader.read(includeSerial: fullSerial)
        temperatures = SensorSummary.rows(sensors: monitor.sensors, values: monitor.values, hidden: [])
        test = monitor.lastTestResult
        ssd = SSDInfo.read(includeSerial: fullSerial)
        ssdTest = monitor.lastSSDResult
        panics = monitor.lastCrashScan?.panics ?? CrashHistory.panics()
        shutdowns = monitor.lastCrashScan?.shutdowns
        memoryResult = monitor.lastMemoryResult
        batteryCheck = battery.map { PartCheck.battery($0, model: monitor.system.model, reference: monitor.partsReference) }
        adapterCheck = battery.flatMap { PartCheck.adapter($0, reference: monitor.partsReference) }
        macOSHealth = MacOSBatteryHealth.read()
        // The device card in the app is always masked: read again for full serials.
        device = fullSerial ? DeviceInfo.read(includeSerial: true) : (monitor.deviceInfo ?? DeviceInfo.read())
        let defaults = UserDefaults.standard
        shopName = defaults.string(forKey: Pref.reportShopName) ?? ""
        note = defaults.string(forKey: Pref.reportNote) ?? ""
        hardwareCheck = monitor.hardwareCheck.isEmpty ? nil : monitor.hardwareCheck
        sleep = monitor.lastSleepAnalysis
        offPeriods = monitor.lastSleepAnalysis.map(monitor.offPeriods) ?? []
        capacity = monitor.lastCapacityResult
        drain = monitor.profile.hasBattery ? monitor.drainReport(analysis: monitor.lastSleepAnalysis) : nil
    }
}

/// A4 customer report drawn with AppKit text into a PDF context (both interfaces, every
/// macOS version). Page 1: device, battery, temperatures and tests. Page 2 (only when
/// used): the hardware checklist, the battery capacity test and the sleep / wake analysis.
public enum ReportPDF {
    public static let pageSize = CGSize(width: 595, height: 842)

    public static func render(_ data: ReportData) -> Data? {
        let output = NSMutableData()
        guard let writer = ReportWriter(output: output, data: data) else { return nil }
        writer.firstPage()
        if data.hardwareCheck != nil || data.sleep != nil || data.capacity != nil {
            writer.secondPage()
        }
        writer.close()
        return output.length > 0 ? output as Data : nil
    }
}

/// Lays out the report top to bottom; starts a new page when the content does not fit.
private final class ReportWriter {
    private let context: CGContext
    private let data: ReportData
    private let margin: CGFloat = 36
    private var y: CGFloat = 0
    private var pageOpen = false
    private var width: CGFloat { ReportPDF.pageSize.width - 2 * margin }
    private var bottom: CGFloat { ReportPDF.pageSize.height - margin - 26 }

    private let body = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private let bold = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    private let medium = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    private let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 10), toHaveTrait: .italicFontMask)
    private let gray = NSColor(white: 0.5, alpha: 1)
    private let black = NSColor.black

    init?(output: NSMutableData, data: ReportData) {
        var box = CGRect(origin: .zero, size: ReportPDF.pageSize)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        self.context = context
        self.data = data
    }

    // MARK: Pages

    private func beginPage(subtitle: String) {
        if pageOpen { endPage() }
        context.beginPDFPage(nil)
        context.saveGState()
        context.translateBy(x: 0, y: ReportPDF.pageSize.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        pageOpen = true
        y = margin
        // Header: shop name, title, date or model on the right.
        if !data.shopName.isEmpty {
            y += draw(data.shopName, at: margin, width: width, font: .systemFont(ofSize: 16, weight: .semibold)) + 3
        }
        let titleHeight = draw(L("Mac inspection report"), at: margin, width: width, font: .systemFont(ofSize: 13, weight: .medium))
        _ = draw(subtitle, at: margin, width: width, font: body, color: gray, alignment: .right, top: y + 2)
        y += titleHeight + 8
        divider()
        y += 14
    }

    private func endPage() {
        footer()
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
        context.endPDFPage()
        pageOpen = false
    }

    func close() {
        if pageOpen { endPage() }
        context.closePDF()
    }

    private func footer() {
        var top = ReportPDF.pageSize.height - margin - 12
        if !data.note.isEmpty {
            let noteHeight = height(data.note, width: width, font: body)
            top -= noteHeight + 6
            _ = draw(data.note, at: margin, width: width, font: body, top: top)
            top += noteHeight + 4
        }
        line(at: top)
        let credit = data.fullSerial
            ? L("Created with FixStat %@ — github.com/BurakFixLab/fixstat.", AboutInfo.version)
            : L("Created with FixStat %@ — github.com/BurakFixLab/fixstat. Serial numbers are masked.", AboutInfo.version)
        _ = draw(credit,
                 at: margin, width: width, font: .systemFont(ofSize: 8), color: gray, top: top + 4)
    }

    /// Starts a new page when `needed` points do not fit any more.
    private func ensure(_ needed: CGFloat) {
        if y + needed > bottom { beginPage(subtitle: data.system.marketingName ?? data.system.model) }
    }

    // MARK: Page 1

    func firstPage() {
        beginPage(subtitle: Format.dateTimeLong(data.date))
        deviceSection()
        if let battery = data.battery {
            batterySection(battery)
            powerSection(battery)
        }
        temperatureSection()
        if let ssd = data.ssd { ssdSection(ssd) }
        crashSection()
        if let memory = data.memoryResult {
            group(L("Memory test"))
            row(L("Result"), memory.passed ? L("No memory errors found") : L("Memory errors found"))
            row(L("Tested"), "\(Format.bytes(Double(memory.bytes))) · \(memory.patternsCompleted.count) / \(MemoryTest.Pattern.allCases.count)")
            endGroup()
        }
        if let test = data.test { testSection(test) }
    }

    private func deviceSection() {
        let s = data.system, d = data.device
        group(L("Device"))
        row(L("Mac"), s.marketingName ?? s.model)
        row(L("Model identifier"), [s.model, s.boardTarget].compactMap { $0 }.joined(separator: " · "))
        row(L("Part number · serial"), [d.partNumber, d.serial].compactMap { $0 }.joined(separator: " · "))
        row(L("Chip"), s.chip)
        row(L("macOS"), s.osVersion)
        row(L("Activation Lock · MDM"), [DeviceText.state(d.activationLock, on: L("On"), off: L("Off")),
                                         DeviceText.state(d.mdmEnrolled, on: L("Enrolled"), off: L("Not enrolled"))]
            .joined(separator: " · "))
        endGroup()
    }

    private func batterySection(_ b: BatteryInfo) {
        let analysis = CellAnalysis(battery: b)
        var left: [(String, String?)] = [
            (L("Health"), b.healthPercent.map { Format.percent($0, digits: 1) }),
            (L("Cycles"), b.cycleCount.map { Format.number(Double($0)) }),
            (L("Design capacity"), b.designCapacity.map(Format.milliampHours)),
            (L("Maximum capacity"), b.rawMaxCapacity.map(Format.milliampHours)),
            (L("Temperature"), b.temperature.map { Format.temperature($0) }),
            (L("Serial"), b.serial),
        ]
        if let condition = data.macOSHealth?.condition { left.append((L("macOS condition"), PartText.condition(condition))) }
        if let check = data.batteryCheck { left.append((L("Originality check"), PartText.verdict(check.verdict))) }
        let rowHeight: CGFloat = 15
        ensure(18 + CGFloat(max(left.count, analysis.cells.count + 2)) * rowHeight)
        group(L("Battery"))
        let top = y
        let columnWidth = (width - 24) / 2
        var leftY = top
        for (title, value) in left {
            leftY += row(title, value, x: margin, width: columnWidth, top: leftY)
        }
        // Cell table on the right.
        let x = margin + columnWidth + 24
        let columns: [(String, CGFloat, NSTextAlignment)] = [(L("Cell"), 0, .left), (L("Voltage"), 0.40, .right),
                                                             (L("Qmax"), 0.72, .right), (L("Resistance"), 1.0, .right)]
        var rightY = top
        func tableRow(_ values: [String], font: NSFont, color: NSColor) {
            var h: CGFloat = 0
            for (index, value) in values.enumerated() {
                let (_, position, alignment) = columns[index]
                let cellX = alignment == .left ? x : x + columnWidth * position - 80
                h = max(h, draw(value, at: cellX, width: alignment == .left ? 80 : 80, font: font, color: color,
                                alignment: alignment, top: rightY))
            }
            rightY += h + 3
        }
        tableRow(columns.map(\.0), font: body, color: gray)
        for cell in analysis.cells {
            tableRow([L("Cell %lld", cell.number), cell.voltage.map { Format.volts(millivolts: $0, digits: 3) } ?? "–",
                      cell.qmax.map(Format.milliampHours) ?? "–", cell.resistance.map { Format.number(Double($0)) } ?? "–"],
                     font: cell.isSuspect ? bold : body, color: black)
        }
        if analysis.suspects.isEmpty {
            rightY += draw(L("Cells are consistent."), at: x, width: columnWidth, font: body, color: gray, top: rightY) + 3
        } else {
            for cell in analysis.suspects {
                rightY += draw("⚠︎ " + BatteryDetailText.finding(cell), at: x, width: columnWidth, font: bold, top: rightY) + 3
            }
        }
        y = max(leftY, rightY)
        endGroup()
    }

    private func powerSection(_ b: BatteryInfo) {
        group(L("Power"))
        row(L("State"), BatteryText.state(b))
        if let adapter = b.adapter {
            row(L("Power adapter"), [adapter.name, adapter.ratedWatts.map { Format.watts(Double($0)) }]
                .compactMap { $0 }.joined(separator: " · "))
        }
        if let check = data.adapterCheck { row(L("Adapter originality"), PartText.verdict(check.verdict)) }
        if let active = b.powerDelivery?.activeProfile, b.externalConnected == true {
            row(L("Contract"), [active.maxVoltage.map { Format.volts(millivolts: $0, digits: 0) },
                               active.maxCurrent.map { Format.amps(milliamps: $0) }].compactMap { $0 }.joined(separator: " · "))
        }
        if let life = b.lifetime {
            row(L("Highest temperature (lifetime)"), life.maximumTemperature.map { Format.temperature($0) })
        }
        endGroup()
    }

    private func temperatureSection() {
        group(L("Temperatures (at report time)"))
        twoColumns(data.temperatures.map { ($0.title, Format.temperature($0.value)) })
        endGroup()
    }

    private func ssdSection(_ ssd: SSDInfo) {
        group(L("SSD"))
        row(L("Model"), [ssd.model, ssd.capacity.map { Format.bytes($0) }].compactMap { $0 }.joined(separator: " · "))
        if let space = ssd.space { row(L("Startup volume"), SSDText.space(space)) }
        if let h = ssd.health {
            let findings = SSDText.healthFindings(h)
            row(L("Health (SMART)"), ([SSDText.healthSummary(ssd)].compactMap { $0 }
                + [findings.isEmpty ? L("SSD health is good.") : findings.joined(separator: " ")]).joined(separator: " · "))
            twoColumns(Array(SSDText.healthRows(h).prefix(8)))
        } else if let a = ssd.ata {
            let findings = SSDText.ataFindings(a)
            row(L("Health (SMART)"), ([SSDText.healthSummary(ssd)].compactMap { $0 }
                + [findings.isEmpty ? L("SSD health is good.") : findings.joined(separator: " ")]).joined(separator: " · "))
            twoColumns(Array(SSDText.ataRows(a).prefix(8)))
        }
        for drive in ssd.otherDrives {
            row(drive.model ?? L("Other internal drives"), SSDText.driveSummary(drive))
        }
        if let test = data.ssdTest {
            let problems = test.findings.filter { $0 != .stoppedEarly }
            row(L("Write–verify stress test"), (problems.isEmpty ? L("No problems found") : L("Needs attention"))
                + " · " + SSDText.resultRows(test).prefix(3).map(\.1).joined(separator: " · "))
            for finding in problems { text("• " + SSDText.finding(finding)) }
        }
        endGroup()
    }

    private func crashSection() {
        group(L("Panics and shutdowns"))
        row(L("Kernel panics"), data.panics.isEmpty ? L("none") : Format.number(Double(data.panics.count)))
        for panic in data.panics.prefix(3) {
            text("• " + Format.dateTime(panic.date) + " — " + (panic.area.map(CrashText.area) ?? "") + " "
                 + String(panic.summary.prefix(90)), singleLine: true)
        }
        if let shutdowns = data.shutdowns {
            let faults = shutdowns.filter(\.isFault)
            row(L("Abnormal shutdowns (30 days)"), faults.isEmpty ? L("none") : faults.prefix(4).map { "\($0.code)" }.joined(separator: ", "))
        }
        endGroup()
    }

    private func testSection(_ test: StressTestResult) {
        let problems = test.findings.filter { $0 != .stoppedEarly }
        group(L("Post-repair test"))
        text(problems.isEmpty ? L("No problems found") : L("Needs attention"), font: .systemFont(ofSize: 11, weight: .semibold))
        for finding in test.findings { text("• " + TestText.finding(finding)) }
        twoColumns(TestText.summaryRows(test))
        endGroup()
    }

    // MARK: Page 2

    func secondPage() {
        beginPage(subtitle: data.system.marketingName ?? data.system.model)
        if let check = data.hardwareCheck { hardwareSection(check) }
        if let capacity = data.capacity {
            group(L("Battery capacity test"))
            for r in CapacityText.rows(capacity) { row(r.0, r.1) }
            for f in capacity.findings { text("• " + CapacityText.finding(f)) }
            endGroup()
        }
        if let sleep = data.sleep { sleepSection(sleep) }
    }

    private func hardwareSection(_ check: HardwareCheck) {
        group(L("Hardware check"))
        text(L("%lld passed · %lld failed · %lld not tested", check.count(.passed), check.count(.failed), check.count(.untested)),
             font: .systemFont(ofSize: 11, weight: .semibold))
        let statusX = margin + 130, detailX = margin + 225
        for item in check.items {
            let entry = check[item]
            var lines: [(String, NSFont)] = []
            if let detail = entry.detail { lines.append((detail, body)) }
            if !entry.note.isEmpty { lines.append((entry.note, italic)) }
            let detailHeight = lines.reduce(CGFloat(0)) { $0 + height($1.0, width: width - 225, font: $1.1) + 2 }
            ensure(max(14, detailHeight) + 10)
            let top = y
            var h = draw(HardwareText.title(item), at: margin, width: 125, font: medium, top: top)
            h = max(h, draw(HardwareText.status(entry.status), at: statusX, width: 90,
                            font: entry.status == .failed ? .monospacedDigitSystemFont(ofSize: 10, weight: .bold) : body,
                            color: entry.status == .untested ? gray : black, top: top))
            var lineY = top
            for (line, font) in lines {
                lineY += draw(line, at: detailX, width: width - 225, font: font, top: lineY) + 2
            }
            y = max(top + h, lineY) + 4
            line(at: y)
            y += 5
        }
        endGroup()
    }

    private func sleepSection(_ a: SleepAnalysis) {
        group(L("Sleep and wake"))
        if let from = a.from, let to = a.to {
            row(L("Period"), Format.date(from) + " – " + Format.date(to))
        }
        row(L("Sleeps · wakes · dark wakes"), "\(a.sleeps.count) · \(a.wakes.count) · \(a.darkWakes.count)")
        row(L("Drain while asleep"), a.sleepDrain.map { SleepText.drain($0.percentPerHour) })
        row(L("Battery ran empty"), Format.number(Double(a.lowPowerSleeps)))
        row(L("Drain while shut down"), OffStateDrain.summary(data.offPeriods).map(SleepText.offSummary))
        if let top = a.reasons(.wake, limit: 3).first {
            row(L("Most common wake reason"), "\(SleepText.category(top.name) ?? top.name) (\(top.count)×)")
        }
        if let drain = data.drain, drain.conclusion != .noData {
            row(L("Drain detective"), DrainText.headline(drain).text)
            twoColumns(DrainText.rows(drain))
        }
        let findings = SleepText.findings(a) + SleepText.offFindings(data.offPeriods)
        for f in findings { text("• " + f) }
        if findings.isEmpty { text(L("No sleep or wake problems found.")) }
        endGroup()
    }

    // MARK: Building blocks

    private func group(_ title: String) {
        ensure(40)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                                                         .foregroundColor: gray, .kern: 0.3]
        let string = NSAttributedString(string: title.uppercased(with: .current), attributes: attributes)
        string.draw(at: NSPoint(x: margin, y: y))
        y += string.size().height + 4
    }

    private func endGroup() {
        y += 10
    }

    /// Gray title on the left, value on the right; returns the height.
    @discardableResult
    private func row(_ title: String, _ value: String?, x: CGFloat? = nil, width: CGFloat? = nil, top: CGFloat? = nil) -> CGFloat {
        let x = x ?? margin, w = width ?? self.width
        if top == nil { ensure(15) }
        let rowTop = top ?? y
        let titleWidth = min(size(title, font: body).width + 2, w * 0.6)
        let h = max(draw(title, at: x, width: titleWidth, font: body, color: gray, top: rowTop),
                    draw(value ?? "–", at: x + titleWidth + 8, width: w - titleWidth - 8, font: body, alignment: .right, top: rowTop))
        if top == nil { y += h + 3 }
        return h + 3
    }

    private func twoColumns(_ rows: [(String, String)]) {
        let columnWidth = (width - 12) / 2
        for start in stride(from: 0, to: rows.count, by: 2) {
            ensure(15)
            var h = row(rows[start].0, rows[start].1, x: margin, width: columnWidth, top: y)
            if start + 1 < rows.count {
                h = max(h, row(rows[start + 1].0, rows[start + 1].1, x: margin + columnWidth + 12, width: columnWidth, top: y))
            }
            y += h
        }
    }

    private func text(_ string: String, font: NSFont? = nil, singleLine: Bool = false) {
        let font = font ?? body
        let h = singleLine ? size(string, font: font).height : height(string, width: width, font: font)
        ensure(h + 3)
        y += draw(string, at: margin, width: width, font: font, top: y, singleLine: singleLine) + 3
    }

    private func divider() {
        line(at: y)
    }

    private func line(at lineY: CGFloat) {
        NSColor(white: 0.8, alpha: 1).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: margin, y: lineY))
        path.line(to: NSPoint(x: margin + width, y: lineY))
        path.lineWidth = 0.5
        path.stroke()
    }

    // MARK: Text

    private func attributes(_ font: NSFont, _ color: NSColor, _ alignment: NSTextAlignment,
                            _ singleLine: Bool) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    private func size(_ string: String, font: NSFont) -> NSSize {
        (string as NSString).size(withAttributes: [.font: font])
    }

    private func height(_ string: String, width: CGFloat, font: NSFont) -> CGFloat {
        ceil((string as NSString).boundingRect(with: NSSize(width: width, height: 10_000),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading],
                                               attributes: [.font: font]).height)
    }

    /// Draws wrapped text at `top` (the current position by default); returns its height.
    @discardableResult
    private func draw(_ string: String, at x: CGFloat, width: CGFloat, font: NSFont, color: NSColor? = nil,
                      alignment: NSTextAlignment = .left, top: CGFloat? = nil, singleLine: Bool = false) -> CGFloat {
        let h = singleLine ? size(string, font: font).height : height(string, width: width, font: font)
        let rect = NSRect(x: x, y: top ?? y, width: width, height: h)
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                  attributes: attributes(font, color ?? black, alignment, singleLine))
        return h
    }
}
