import AppKit
import SwiftUI
import FixStatCore

/// Version information and the standard About panel.
@available(macOS 14.0, *)
enum AboutInfo {
    static let repositoryURL = URL(string: "https://github.com/BurakFixLab/fixstat")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }

    /// Shows the standard macOS About panel with license and project link.
    @MainActor
    static func show() {
        let credits = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let description = String(localized: "Menu bar monitor for Mac repair technicians. Reads sensors only — never writes to the SMC.")
        credits.append(NSAttributedString(string: description + "\n\n", attributes: body))
        credits.append(NSAttributedString(string: String(localized: "Free and open source (MIT License).") + "\n", attributes: body))
        var link = body
        link[.link] = repositoryURL
        credits.append(NSAttributedString(string: repositoryURL.absoluteString.replacingOccurrences(of: "https://", with: ""),
                                          attributes: link))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))

        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationVersion: version,
            .version: build,
        ])
    }
}

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
