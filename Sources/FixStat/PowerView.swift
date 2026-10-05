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
            VStack(alignment: .leading, spacing: 18) {
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
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(title: "System")
                HStack(spacing: 8) {
                    ForEach(totals, id: \.0) { title, value in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.caption).foregroundStyle(.secondary)
                            Text(value).font(.title3.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }

        let components = PowerText.components(model.components)
        if !components.isEmpty {
            group("Components") {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 5) {
                    GridRow {
                        Text("Component").gridColumnAlignment(.leading)
                        Text("Power")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(components, id: \.self) { row in
                        GridRow {
                            Text(row[0]).gridColumnAlignment(.leading)
                            Text(row[1])
                        }
                    }
                }
            }
        }

        let clusters = PowerText.clusters(model.clusters)
        if !clusters.isEmpty || model.thermal != nil {
            group("CPU") {
                if !clusters.isEmpty {
                    Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 5) {
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
                }
                if let status = model.thermal {
                    let thermal = PowerText.thermal(status)
                    HStack {
                        Text("Thermal state").foregroundStyle(.secondary)
                        Spacer()
                        Text(thermal.state)
                    }
                    if let limit = thermal.limit {
                        HStack {
                            Text("CPU speed limit").foregroundStyle(.secondary)
                            Spacer()
                            Text(limit)
                        }
                    }
                    if thermal.throttled {
                        Label("The CPU is held back for heat or power.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(TemperatureColor.hot)
                    }
                }
            }
        }

        let rails = PowerText.rails(model.rails)
        if model.rails.isEmpty {
            Label("This Mac reports no power rails.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        } else {
            group("Power rails") {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 5) {
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
                            Text(row[1]).font(.callout.monospaced()).foregroundStyle(.secondary)
                            Text(row[2])
                            Text(row[3])
                            Text(row[4])
                        }
                    }
                }
                if let idle = PowerText.idleRails(model.rails) {
                    Text(idle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        Text(PowerText.explanation)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func group<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: title)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
