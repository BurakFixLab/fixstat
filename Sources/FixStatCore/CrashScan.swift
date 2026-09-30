import Foundation
import MacSensors

/// Panics and shutdown causes found by the last scan (for reports).
public struct CrashScan {
    public let panics: [PanicReport]
    public let shutdowns: [ShutdownEvent]
    public var date = Date()

    public init(panics: [PanicReport], shutdowns: [ShutdownEvent], date: Date = Date()) {
        self.panics = panics
        self.shutdowns = shutdowns
        self.date = date
    }
}
