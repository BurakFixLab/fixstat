import AppKit
import FixStatLegacy

// Entry point. macOS 14 and later get the SwiftUI interface; older systems (down to
// macOS 10.13 on Intel, 11 on Apple Silicon) get the AppKit interface. Both use the same
// measurement code. `--legacy-ui` forces the AppKit interface for testing on new macOS.
if #available(macOS 14.0, *), !CommandLine.arguments.contains("--legacy-ui") {
    FixStatApp.main()
} else {
    LegacyApp.run()
}
