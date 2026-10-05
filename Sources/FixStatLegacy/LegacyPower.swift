import AppKit
import FixStatCore
import MacSensors

/// Power analysis: system totals, SoC components and the board's power rails, live.
final class LegacyPower {
    private let analyzer = PowerAnalyzer()
    private(set) var window: LegacyToolWindow!

    init() {
        window = LegacyToolWindow(title: L("Power analysis"), contentWidth: 640, height: 720) { [unowned self] in blocks() }
        window.onOpen = { [unowned self] in analyzer.start() }
        window.onClose = { [unowned self] in analyzer.stop() }
        analyzer.onChange = { [unowned self] in window.reload() }
    }

    private func blocks() -> [Block] {
        guard analyzer.ready else { return [.progress(L("Reading the power rails…"))] }
        var blocks: [Block] = []
        let totals = PowerText.totals(analyzer.totals)
        if !totals.isEmpty { blocks.append(.group(L("System"), [.tiles(totals, columns: 3)])) }

        let components = PowerText.components(analyzer.components)
        if !components.isEmpty {
            blocks.append(.group(L("Components"), [
                .table(header: [L("Component"), L("Power")], rows: components,
                       tones: components.map { _ in [nil, nil] }, leading: false),
            ]))
        }

        var cpu: [Block] = []
        let clusters = PowerText.clusters(analyzer.clusters)
        if !clusters.isEmpty {
            cpu.append(.table(header: [L("Cluster"), L("Active"), L("Average while active"), L("Highest")], rows: clusters,
                              tones: clusters.map { _ in [nil, nil, nil, .neutral] }, leading: false))
        }
        if let status = analyzer.thermal {
            let thermal = PowerText.thermal(status)
            var rows = [DocRow(title: L("Thermal state"), value: thermal.state)]
            if let limit = thermal.limit { rows.append(DocRow(title: L("CPU speed limit"), value: limit)) }
            cpu.append(.rows(rows, labelWidth: 200))
            if thermal.throttled { cpu.append(.status(L("The CPU is held back for heat or power."), .bad)) }
        }
        if !cpu.isEmpty { blocks.append(.group(L("CPU"), cpu)) }

        let rails = PowerText.rails(analyzer.rails)
        if rails.isEmpty, analyzer.rails.isEmpty {
            blocks.append(.status(L("This Mac reports no power rails."), .neutral))
        } else {
            var group: [Block] = [
                .table(header: [L("Rail"), L("Key"), L("Voltage"), L("Current"), L("Power")], rows: rails,
                       tones: rails.map { _ in [nil, .neutral, nil, nil, nil] }, leading: false),
            ]
            if let idle = PowerText.idleRails(analyzer.rails) { group.append(.secondary(idle)) }
            blocks.append(.group(L("Power rails"), group))
        }
        blocks.append(.caption(PowerText.explanation))
        return blocks
    }
}
