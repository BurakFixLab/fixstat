import AppKit
import SwiftUI
import FixStatCore

/// Version line and About button at the bottom of the General settings.
@available(macOS 14.0, *)
struct AboutSection: View {
    var body: some View {
        Section {
            LabeledContent("Version") {
                Text(verbatim: "\(AboutInfo.version) (\(AboutInfo.build))").monospacedDigit()
            }
            HStack {
                Button("About FixStat") { AboutInfo.show() }
                Spacer()
                Link("Project page", destination: AboutInfo.repositoryURL)
            }
        }
    }
}
