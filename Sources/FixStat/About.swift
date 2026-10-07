import AppKit
import SwiftUI
import FixStatCore

/// Version line and About button at the bottom of the General settings.
@available(macOS 14.0, *)
struct AboutSection: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage(Pref.checkForUpdates) private var checkForUpdates = true

    var body: some View {
        Section {
            LabeledContent("Version") {
                Text(verbatim: "\(AboutInfo.version) (\(AboutInfo.build))").monospacedDigit()
            }
            Toggle(isOn: $checkForUpdates) {
                Text("Check for updates automatically")
                Text(verbatim: UpdateText.privacy)
            }
            LabeledContent {
                HStack {
                    if case let .available(release) = monitor.update {
                        Link("Download", destination: release.url)
                    }
                    Button("Check now") { UpdateChecker.shared.check() }
                        .disabled(monitor.update == .checking)
                }
            } label: {
                Text(verbatim: UpdateText.status(monitor.update, lastCheck: UpdateChecker.shared.lastCheck))
            }
            HStack {
                Button("About FixStat") { AboutInfo.show() }
                Spacer()
                Link("Project page", destination: AboutInfo.repositoryURL)
            }
        }
    }
}
