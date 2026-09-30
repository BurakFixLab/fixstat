import AppKit

/// Version information and the standard About panel.
public enum AboutInfo {
    public static let repositoryURL = URL(string: "https://github.com/BurakFixLab/fixstat")!

    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }

    /// Shows the standard macOS About panel with license and project link.
    public static func show() {
        let credits = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let description = L("Menu bar monitor for Mac repair technicians. Reads sensors only — never writes to the SMC.")
        credits.append(NSAttributedString(string: description + "\n\n", attributes: body))
        credits.append(NSAttributedString(string: L("Free and open source (MIT License).") + "\n", attributes: body))
        var link = body
        link[.link] = repositoryURL
        credits.append(NSAttributedString(string: repositoryURL.absoluteString.replacingOccurrences(of: "https://", with: ""),
                                          attributes: link))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationVersion: version,
            .version: build,
        ])
    }
}
