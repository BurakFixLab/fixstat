import Foundation

/// Power of one SoC component (W), from the energy counters of IOReport's "Energy Model" group.
public struct ComponentPower: Codable, Sendable, Equatable {
    /// Channel name as IOReport reports it ("CPU Energy", "GPU Energy", "ECPU", "PACC0_CPU" …).
    public var name: String
    public var watts: Double

    public init(name: String, watts: Double) {
        self.name = name
        self.watts = watts
    }
}

/// Reads IOReport's energy counters (Apple Silicon): CPU clusters, GPU, ANE, DRAM where the chip
/// reports them. The private libIOReport is loaded with dlopen, so nothing links against it;
/// no root needed. Not thread safe: use one sampler from one thread.
public final class EnergySampler {
    private typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
                                                           UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?,
                                                           UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias SamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntegerValue = @convention(c) (CFDictionary, Int32) -> Int64

    private struct API {
        let createSamples: CreateSamples
        let delta: SamplesDelta
        let name: ChannelString
        let unit: ChannelString
        let value: IntegerValue
    }

    private let api: API
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary
    private var last: (sample: CFDictionary, date: Date)?

    /// nil where IOReport or its energy group is missing (Intel, old macOS).
    public init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return nil }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let copy = symbol("IOReportCopyChannelsInGroup", CopyChannels.self),
              let subscribe = symbol("IOReportCreateSubscription", CreateSubscription.self),
              let createSamples = symbol("IOReportCreateSamples", CreateSamples.self),
              let delta = symbol("IOReportCreateSamplesDelta", SamplesDelta.self),
              let name = symbol("IOReportChannelGetChannelName", ChannelString.self),
              let unit = symbol("IOReportChannelGetUnitLabel", ChannelString.self),
              let value = symbol("IOReportSimpleGetIntegerValue", IntegerValue.self),
              let group = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = subscribe(nil, group, &subscribed, 0, nil), let channels = subscribed?.takeRetainedValue()
        else { return nil }
        api = API(createSamples: createSamples, delta: delta, name: name, unit: unit, value: value)
        self.subscription = subscription
        self.channels = channels
    }

    deinit {
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(subscription)).release()
    }

    /// Power since the previous call (the first call only starts the count and returns []).
    /// Per-core and internal detail channels are left out; zero channels too.
    public func sample() -> [ComponentPower] {
        guard let current = api.createSamples(subscription, channels, nil)?.takeRetainedValue() else { return [] }
        let now = Date()
        defer { last = (current, now) }
        guard let last, now.timeIntervalSince(last.date) > 0.2,
              let delta = api.delta(last.sample, current, nil)?.takeRetainedValue() as NSDictionary?,
              let list = delta["IOReportChannels"] as? [NSDictionary]
        else { return [] }
        let seconds = now.timeIntervalSince(last.date)
        var out: [ComponentPower] = []
        for channel in list {
            let dict = channel as CFDictionary
            guard let name = api.name(dict)?.takeUnretainedValue() as String?, Self.isSummary(name) else { continue }
            let unit = (api.unit(dict)?.takeUnretainedValue() as String? ?? "").trimmingCharacters(in: .whitespaces)
            let scale: Double
            switch unit {
            case "mJ": scale = 1e-3
            case "uJ", "µJ": scale = 1e-6
            case "nJ": scale = 1e-9
            default: continue
            }
            let watts = Double(api.value(dict, 0)) * scale / seconds
            if watts > 0.0005 { out.append(ComponentPower(name: name, watts: watts)) }
        }
        return out
    }

    /// Totals and clusters; not per-core channels ("PCPU2", "PACC0_CPU3"), DTL / CPM details.
    static func isSummary(_ name: String) -> Bool {
        if name.contains("DTL") || name.hasSuffix("CPM") { return false }
        if name.range(of: "^[EP]CPU[0-9]+$", options: .regularExpression) != nil { return false }
        if name.range(of: "_CPU[0-9]+$", options: .regularExpression) != nil { return false }
        return true
    }
}
