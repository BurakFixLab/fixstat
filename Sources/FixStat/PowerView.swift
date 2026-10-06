import MacSensors
import SwiftUI
import FixStatCore

/// SwiftUI view of the core `PowerAnalyzer`.
@available(macOS 14.0, *)
@MainActor
@Observable
final class PowerAnalysisModel {
    private(set) var ready = false
    private(set) var totals: [String: Double] = [:]
    private(set) var components: [ComponentPower] = []
    private(set) var rails: [PowerRail] = []
    private(set) var clusters: [ClusterActivity] = []
    private(set) var thermal: ThermalStatus?

    @ObservationIgnored private let analyzer = PowerAnalyzer()

    init() {
        analyzer.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    func start() { analyzer.start() }
    func stop() { analyzer.stop() }

    private func sync() {
        ready = analyzer.ready
        if analyzer.totals != totals { totals = analyzer.totals }
        if analyzer.components != components { components = analyzer.components }
        if analyzer.rails != rails { rails = analyzer.rails }
        if analyzer.clusters != clusters { clusters = analyzer.clusters }
        if analyzer.thermal != thermal { thermal = analyzer.thermal }
    }
}

/// System totals, SoC components and the board's power rails, live.
@available(macOS 14.0, *)
struct PowerView: View {
    static let windowID = "power"

    @State private var model = PowerAnalysisModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !model.ready {
                    ProgressView("Reading the power rails…").controlSize(.small)
                } else {
                    content
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 600, minHeight: 520)
        .monospacedDigit()
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder private var content: some View {
        let totals = PowerText.totals(model.totals)
        if !totals.isEmpty {
            HStack(spacing: Design.cardSpacing) {
                ForEach(totals, id: \.0) { title, value in
                    MetricTile(verbatim: title, value: value)
                }
            }
        }

        let components = PowerText.components(model.components)
        if !components.isEmpty {
            Card {
                CardHeader("Components", systemImage: "square.stack.3d.up")
                ForEach(components, id: \.self) { row in
                    CardRow(title: Text(verbatim: row[0]), value: row[1])
                }
            }
        }

        let clusters = PowerText.clusters(model.clusters)
        if !clusters.isEmpty || model.thermal != nil {
            Card {
                CardHeader("CPU", systemImage: "cpu")
                if !clusters.isEmpty {
                    Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: Design.rowSpacing) {
                        GridRow {
                            Text("Cluster").gridColumnAlignment(.leading)
                            Text("Active")
                            Text("Average while active")
                            Text("Highest")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ForEach(clusters, id: \.self) { row in
                            GridRow {
                                Text(row[0]).gridColumnAlignment(.leading)
                                Text(row[1])
                                Text(row[2])
                                Text(row[3]).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
                if let status = model.thermal {
                    let thermal = PowerText.thermal(status)
                    CardRow(title: Text("Thermal state"), value: thermal.state)
                    if let limit = thermal.limit {
                        CardRow(title: Text("CPU speed limit"), value: limit,
                                valueStyle: thermal.throttled ? TemperatureColor.hot : nil)
                    }
                    if thermal.throttled {
                        FindingRow(text: String(localized: "The CPU is held back for heat or power."))
                    }
                }
            }
        }

        let rails = PowerText.rails(model.rails)
        if model.rails.isEmpty {
            Label("This Mac reports no power rails.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        } else {
            Card {
                CardHeader("Power rails", systemImage: "bolt") {
                    if let idle = PowerText.idleRails(model.rails) {
                        Text(idle).foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: Design.rowSpacing) {
                    GridRow {
                        Text("Rail").gridColumnAlignment(.leading)
                        Text("Key").gridColumnAlignment(.leading)
                        Text("Voltage")
                        Text("Current")
                        Text("Power")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(rails, id: \.self) { row in
                        GridRow {
                            Text(row[0]).gridColumnAlignment(.leading)
                            Text(row[1]).font(.caption.monospaced()).foregroundStyle(.tertiary)
                            Text(row[2])
                            Text(row[3])
                            Text(row[4])
                        }
                    }
                }
            }
        }

        Text(PowerText.explanation)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
