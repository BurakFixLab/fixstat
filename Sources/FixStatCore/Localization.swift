import Foundation

/// Localized string for code that also runs before macOS 12, where `String(localized:)` does
/// not exist: `L("Battery")`, `L("%lld cycles", count)`. Keys are the English source text,
/// exactly as `String(localized:)` would produce them (interpolations become `%@`, `%lld`),
/// so they share the catalog entries with the SwiftUI code.
///
/// The compiler does not extract these calls; `scripts/extract-strings.py` finds every
/// `L("…")` literal in the FixStatCore / FixStatLegacy sources for the string catalog. Keys
/// must be plain literals (no `\(…)` interpolation).
public func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .main, comment: "")
    return arguments.isEmpty ? format : String(format: format, locale: Locale.current, arguments: arguments)
}
