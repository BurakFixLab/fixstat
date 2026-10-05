import Foundation
import MacSensors

/// Live power of the Mac while the power analysis window is open: system totals and rails from
/// the SMC, SoC components from IOReport. One reading per second on the main thread (the SMC
/// keys are discovered once, in the background).
public final class PowerAnalyzer: NSObject {
    public private(set) var totals: [String: Double] = [:]
    public private(set) var components: [ComponentPower] = []
    public private(set) var rails: [PowerRail] = []
    /// CPU clusters' activity and frequency (Apple Silicon).
    public private(set) var clusters: [ClusterActivity] = []
    public private(set) var thermal: ThermalStatus?
    /// False until the rail keys are known.
    public private(set) var ready = false
    public var onChange: () -> Void = {}

    private var smc: SMC?
    private var railKeys: [PowerRails.Keys] = []
    private var energy: EnergySampler?
    private var activity: ClusterActivitySampler?
    private var ticks = 0
    private var timer: Timer?

    public var isRunning: Bool { timer != nil }

    public func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        guard smc == nil else { return tick() }
        DispatchQueue.global(qos: .userInitiated).async {
            let smc = try? SMC()
            let keys = smc.map(PowerRails.discover) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.smc = smc
                self.railKeys = keys
                self.energy = EnergySampler()
                self.activity = ClusterActivitySampler()
                self.ready = true
                self.tick()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick() {
        guard ready else { return }
        if let smc {
            totals = PowerRails.readTotals(smc: smc)
            rails = PowerRails.read(smc: smc, keys: railKeys)
        }
        if let energy { components = energy.sample() }
        if let activity { clusters = activity.sample() }
        // pmset is a process: every 5 s is enough for a limit that changes slowly.
        if ticks % 5 == 0 { thermal = ThermalStatus.read() }
        ticks += 1
        onChange()
    }
}
