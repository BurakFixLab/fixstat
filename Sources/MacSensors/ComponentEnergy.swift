import Foundation
import IOKit

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

/// One subscription to an IOReport group (Apple Silicon). The private libIOReport is loaded
/// with dlopen, so nothing links against it; no root needed. Each `delta()` returns the
/// channels' change since the previous call. Not thread safe.
final class IOReportSubscription {
    typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
                                                   UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?,
                                                   UInt64, CFTypeRef?) -> OpaquePointer?
    typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias SamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias IntegerValue = @convention(c) (CFDictionary, Int32) -> Int64
    typealias StateCount = @convention(c) (CFDictionary) -> Int32
    typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    struct API {
        let copy: CopyChannels
        let subscribe: CreateSubscription
        let createSamples: CreateSamples
        let delta: SamplesDelta
        let name: ChannelString
        let subGroup: ChannelString
        let unit: ChannelString
        let value: IntegerValue
        let stateCount: StateCount
        let stateName: StateName
        let residency: StateResidency
    }

    static let api: API? = {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return nil }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let copy = symbol("IOReportCopyChannelsInGroup", CopyChannels.self),
              let subscribe = symbol("IOReportCreateSubscription", CreateSubscription.self),
              let createSamples = symbol("IOReportCreateSamples", CreateSamples.self),
              let delta = symbol("IOReportCreateSamplesDelta", SamplesDelta.self),
              let name = symbol("IOReportChannelGetChannelName", ChannelString.self),
              let subGroup = symbol("IOReportChannelGetSubGroup", ChannelString.self),
              let unit = symbol("IOReportChannelGetUnitLabel", ChannelString.self),
              let value = symbol("IOReportSimpleGetIntegerValue", IntegerValue.self),
              let stateCount = symbol("IOReportStateGetCount", StateCount.self),
              let stateName = symbol("IOReportStateGetNameForIndex", StateName.self),
              let residency = symbol("IOReportStateGetResidency", StateResidency.self)
        else { return nil }
        return API(copy: copy, subscribe: subscribe, createSamples: createSamples, delta: delta, name: name,
                   subGroup: subGroup, unit: unit, value: value, stateCount: stateCount, stateName: stateName,
                   residency: residency)
    }()

    let api: API
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary
    private var last: (sample: CFDictionary, date: Date)?

    /// nil where IOReport or the group is missing (Intel, old macOS).
    init?(group: String) {
        guard let api = Self.api, let list = api.copy(group as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = api.subscribe(nil, list, &subscribed, 0, nil), let channels = subscribed?.takeRetainedValue()
        else { return nil }
        self.api = api
        self.subscription = subscription
        self.channels = channels
    }

    deinit {
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(subscription)).release()
    }

    /// Channels changed since the previous call and the seconds between them; nil on the first call.
    func delta() -> (channels: [CFDictionary], seconds: Double)? {
        guard let current = api.createSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        let now = Date()
        defer { last = (current, now) }
        guard let last, now.timeIntervalSince(last.date) > 0.2,
              let delta = api.delta(last.sample, current, nil)?.takeRetainedValue() as NSDictionary?,
              let list = delta["IOReportChannels"] as? [NSDictionary]
        else { return nil }
        return (list.map { $0 as CFDictionary }, now.timeIntervalSince(last.date))
    }

    func name(_ channel: CFDictionary) -> String { api.name(channel)?.takeUnretainedValue() as String? ?? "" }
    func subGroup(_ channel: CFDictionary) -> String { api.subGroup(channel)?.takeUnretainedValue() as String? ?? "" }
}

/// Reads IOReport's energy counters (Apple Silicon): CPU clusters, GPU, ANE, DRAM where the chip
/// reports them.
public final class EnergySampler {
    private let report: IOReportSubscription

    public init?() {
        guard let report = IOReportSubscription(group: "Energy Model") else { return nil }
        self.report = report
    }

    /// Power since the previous call (the first call only starts the count and returns []).
    /// Per-core and internal detail channels are left out; zero channels too.
    public func sample() -> [ComponentPower] {
        guard let (channels, seconds) = report.delta() else { return [] }
        var out: [ComponentPower] = []
        for channel in channels {
            let name = report.name(channel)
            guard Self.isSummary(name) else { continue }
            let unit = (report.api.unit(channel)?.takeUnretainedValue() as String? ?? "").trimmingCharacters(in: .whitespaces)
            let scale: Double
            switch unit {
            case "mJ": scale = 1e-3
            case "uJ", "µJ": scale = 1e-6
            case "nJ": scale = 1e-9
            default: continue
            }
            let watts = Double(report.api.value(channel, 0)) * scale / seconds
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

/// How a CPU cluster ran since the previous reading.
public struct ClusterActivity: Codable, Sendable, Equatable {
    /// IOReport channel name ("ECPU", "PCPU", "PACC0_CPU" …).
    public var name: String
    /// Share of the time the cluster was not idle (0…1).
    public var active: Double
    /// Mean frequency while active and the cluster's highest frequency (MHz); nil when the
    /// frequency table did not match the performance states.
    public var averageMHz: Double?
    public var maximumMHz: Double?

    public init(name: String, active: Double, averageMHz: Double?, maximumMHz: Double?) {
        self.name = name
        self.active = active
        self.averageMHz = averageMHz
        self.maximumMHz = maximumMHz
    }
}

/// Residency of the CPU clusters' performance states (IOReport "CPU Stats"), with the
/// frequency of each state from the power manager's tables in the IORegistry (Apple Silicon).
public final class ClusterActivitySampler {
    private let report: IOReportSubscription
    private let tables: (efficiency: [Double], performance: [Double])

    public init?() {
        guard let report = IOReportSubscription(group: "CPU Stats") else { return nil }
        self.report = report
        tables = (Self.frequencies("voltage-states1-sram"), Self.frequencies("voltage-states5-sram"))
    }

    public func sample() -> [ClusterActivity] {
        guard let (channels, _) = report.delta() else { return [] }
        var out: [ClusterActivity] = []
        for channel in channels where report.subGroup(channel) == "CPU Complex Performance States" {
            let name = report.name(channel)
            guard !name.hasSuffix("CPM") else { continue }
            let count = Int(report.api.stateCount(channel))
            var idle: Int64 = 0
            var states: [Int64] = []
            for index in 0..<count {
                let state = report.api.stateName(channel, Int32(index))?.takeUnretainedValue() as String? ?? ""
                let residency = report.api.residency(channel, Int32(index))
                if state == "IDLE" || state == "OFF" || state == "DOWN" { idle += residency } else { states.append(residency) }
            }
            let busy = states.reduce(0, +)
            guard busy + idle > 0 else { continue }
            let table = name.hasPrefix("E") ? tables.efficiency : tables.performance
            var average: Double?
            if table.count == states.count, busy > 0 {
                average = zip(states, table).map { Double($0) * $1 }.reduce(0, +) / Double(busy)
            }
            out.append(ClusterActivity(name: name, active: Double(busy) / Double(busy + idle), averageMHz: average,
                                       maximumMHz: table.count == states.count ? table.max() : nil))
        }
        return out
    }

    /// Frequencies (MHz) of a `pmgr` voltage-state table: 8-byte entries, frequency first
    /// (Hz on M1 – M3, kHz on later chips).
    static func frequencies(_ property: String) -> [Double] {
        let service = IOServiceGetMatchingService(mach_port_t(MACH_PORT_NULL), IOServiceNameMatching("pmgr"))
        guard service != IO_OBJECT_NULL else { return [] }
        defer { IOObjectRelease(service) }
        guard let data = IORegistryEntryCreateCFProperty(service, property as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data
        else { return [] }
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - 7, by: 8).map { offset in
            let raw = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
            return raw >= 10_000_000 ? Double(raw) / 1_000_000 : Double(raw) / 1000
        }
    }
}
