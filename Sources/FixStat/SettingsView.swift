import MacSensors
import ServiceManagement
import SwiftUI
import FixStatCore

@available(macOS 14.0, *)
struct SettingsView: View {
    @State private var tab: Int

    init(initialTab: Int = 0) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(0)
            ThresholdSettings()
                .tabItem { Label("Thresholds", systemImage: "thermometer.medium") }
                .tag(1)
            SensorSettings()
                .tabItem { Label("Sensors", systemImage: "list.bullet") }
                .tag(2)
        }
        .frame(width: 540, height: 640)
    }
}

@available(macOS 14.0, *)
private struct GeneralSettings: View {
    @AppStorage(Pref.menuBarBatteryIcon) private var batteryIcon = true
    @AppStorage(Pref.menuBarBatteryPercent) private var batteryPercent = true
    @AppStorage(Pref.menuBarCPUTemperature) private var cpuTemperature = true
    @AppStorage(Pref.technicianMode) private var technicianMode = false
    @AppStorage(Pref.appearance) private var appearance = AppearancePreference.system.rawValue
    @AppStorage(Pref.updateInterval) private var interval = Pref.defaultInterval
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Menu bar") {
                Toggle("Battery icon", isOn: $batteryIcon)
                Toggle("Battery percentage", isOn: $batteryPercent)
                Toggle("CPU temperature", isOn: $cpuTemperature)
            }
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag(AppearancePreference.system.rawValue)
                    Text("Light").tag(AppearancePreference.light.rawValue)
                    Text("Dark").tag(AppearancePreference.dark.rawValue)
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("Technician mode", isOn: $technicianMode)
            } footer: {
                Text("Shows raw battery data, cell voltages and every sensor with its raw key.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Update interval", selection: $interval) {
                    ForEach(Pref.intervals, id: \.self) { seconds in
                        Text(Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .wide)))
                            .tag(seconds)
                    }
                }
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(verbatim: loginError).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("While the menu is closed, values refresh at most every 5 seconds to save energy.")
                    .foregroundStyle(.secondary)
            }
            ReportSettingsSection()
            AboutSection()
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

@available(macOS 14.0, *)
private struct ThresholdSettings: View {
    @AppStorage(Pref.warmThreshold) private var warm = Pref.defaultWarm
    @AppStorage(Pref.hotThreshold) private var hot = Pref.defaultHot
    @AppStorage(Pref.cellImbalanceThreshold) private var imbalance = Pref.defaultCellImbalance

    var body: some View {
        Form {
            Section {
                StepperRow(title: "Warm from", value: Format.temperature(warm, digits: 0)) {
                    Stepper("Warm from", value: $warm, in: 30...(hot - 1), step: 1)
                }
                StepperRow(title: "Hot from", value: Format.temperature(hot, digits: 0)) {
                    Stepper("Hot from", value: $hot, in: (warm + 1)...100, step: 1)
                }
                HStack(spacing: 12) {
                    legend(TemperatureColor.cool, "Cool")
                    legend(TemperatureColor.warm, "Warm")
                    legend(TemperatureColor.hot, "Hot")
                }
            } header: {
                Text("Temperature colours")
            }
            Section {
                StepperRow(title: "Warn above", value: Format.millivolts(imbalance)) {
                    Stepper("Warn above", value: $imbalance, in: 5...500, step: 5)
                }
            } header: {
                Text("Cell voltage spread")
            } footer: {
                Text("Difference between the highest and lowest cell voltage.")
                    .foregroundStyle(.secondary)
            }
            NotificationSettingsSection()
            Section {
                Button("Restore defaults") {
                    warm = Pref.defaultWarm
                    hot = Pref.defaultHot
                    imbalance = Pref.defaultCellImbalance
                }
            }
        }
        .formStyle(.grouped)
    }

    private func legend(_ color: Color, _ title: LocalizedStringKey) -> some View {
        Label {
            Text(title)
        } icon: {
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .font(.caption)
    }
}

/// Title on the left, value and stepper on the right.
@available(macOS 14.0, *)
struct StepperRow<Control: View>: View {
    let title: LocalizedStringKey
    let value: String
    @ViewBuilder let control: Control

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(value).monospacedDigit()
                control.labelsHidden()
            }
        }
    }
}

@available(macOS 14.0, *)
private struct SensorSettings: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage(Pref.hiddenSensors) private var hiddenRaw = ""

    var body: some View {
        let hidden = Pref.hiddenSet(hiddenRaw)
        VStack(alignment: .leading, spacing: 8) {
            Text("Hide sensors or give them your own name. Names are saved in your sensor map.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List(monitor.sensors.sorted(by: DefaultPanel.displayOrder)) { sensor in
                SensorSettingsRow(sensor: sensor, isVisible: Binding(
                    get: { !hidden.contains(sensor.id) },
                    set: { visible in
                        var set = Pref.hiddenSet(hiddenRaw)
                        if visible { set.remove(sensor.id) } else { set.insert(sensor.id) }
                        hiddenRaw = Pref.hiddenString(set)
                    }
                ))
            }
            Text(verbatim: Monitor.userMapURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding()
    }
}

@available(macOS 14.0, *)
private struct SensorSettingsRow: View {
    @Environment(Monitor.self) private var monitor
    let sensor: DisplaySensor
    @Binding var isVisible: Bool
    @State private var name = ""

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Show", isOn: $isVisible).labelsHidden()
            TextField(text: $name, prompt: Text(verbatim: SensorNames.defaultName(for: sensor))) {
                Text("Name")
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .onSubmit { monitor.rename(sensor, to: name) }
            Text(verbatim: sensor.descriptor.rawLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
        }
        .onAppear { name = sensor.resolved?.name ?? "" }
    }
}

/// Shop name and note for the PDF customer report.
@available(macOS 14.0, *)
private struct ReportSettingsSection: View {
    @AppStorage(Pref.reportShopName) private var shopName = ""
    @AppStorage(Pref.reportNote) private var note = ""

    var body: some View {
        Section {
            TextField("Shop name", text: $shopName, prompt: Text("Optional"))
            TextField("Note at the bottom", text: $note, prompt: Text("Optional, e.g. phone or warranty terms"), axis: .vertical)
                .lineLimit(1...3)
        } header: {
            Text("PDF report")
        }
    }
}

/// Notification switches (Thresholds tab).
@available(macOS 14.0, *)
private struct NotificationSettingsSection: View {
    @AppStorage(Pref.alertsEnabled) private var enabled = false
    @AppStorage(Pref.alertChipTemperature) private var chipLimit = Pref.defaultAlertChipTemperature
    @AppStorage(AlertManager.Kind.chipTemperature.enabledKey) private var chip = true
    @AppStorage(AlertManager.Kind.batteryTemperature.enabledKey) private var battery = true
    @AppStorage(AlertManager.Kind.cellImbalance.enabledKey) private var cells = true
    @AppStorage(AlertManager.Kind.chargingStopped.enabledKey) private var charging = true
    @AppStorage(AlertManager.Kind.unexpectedShutdown.enabledKey) private var shutdown = true
    @State private var authorized: Bool?

    var body: some View {
        Section {
            Toggle("Show notifications", isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    guard on else { return }
                    Task {
                        _ = await AlertManager.requestAuthorization()
                        authorized = await AlertManager.isAuthorized()
                    }
                }
            if enabled, let authorized {
                if authorized {
                    Label("Notifications are allowed.", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Notifications are turned off for FixStat. Allow them in System Settings › Notifications.")
                        .font(.caption)
                        .foregroundStyle(TemperatureColor.hot)
                }
            }
            Group {
                Toggle("CPU / GPU temperature", isOn: $chip)
                StepperRow(title: "Alert above", value: Format.temperature(chipLimit, digits: 0)) {
                    Stepper("Alert above", value: $chipLimit, in: 60...110, step: 1)
                }
                Toggle("Battery temperature above 45 °C", isOn: $battery)
                Toggle("Cell spread above the warning threshold (on battery)", isOn: $cells)
                Toggle("Power adapter connected but not charging", isOn: $charging)
                Toggle("Mac turned off unexpectedly (possible battery problem)", isOn: $shutdown)
            }
            .disabled(!enabled)
        } header: {
            Text("Notifications")
                .task { authorized = await AlertManager.isAuthorized() }
        } footer: {
            Text("A notification is sent when a condition lasts from 30 seconds to 3 minutes, and repeated at most every 15 minutes.")
                .foregroundStyle(.secondary)
        }
    }
}
