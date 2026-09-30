import Foundation
import MacSensors

/// One temperature sensor as shown in the UI.
public struct DisplaySensor: Identifiable, Equatable {
    public let descriptor: SensorDescriptor
    public let resolved: ResolvedSensor?

    public init(descriptor: SensorDescriptor, resolved: ResolvedSensor?) {
        self.descriptor = descriptor
        self.resolved = resolved
    }

    public var id: String { descriptor.uid }
    public var isMatched: Bool { resolved != nil }
    public var isModelMatch: Bool { resolved?.level == .model }
    public var isEstimated: Bool { resolved?.confidence != .verified }
    public var group: SensorMap.Group { resolved?.group ?? .other }
    public var name: String { SensorNames.name(for: self) }
}
