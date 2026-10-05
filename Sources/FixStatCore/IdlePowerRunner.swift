import AppKit
import MacSensors

/// Idle power with the display off: turns the backlight off (brightness 0, restored
/// afterwards; display sleep where the brightness cannot be set), keeps the Mac awake, waits
/// for the power to settle and averages the system power. The backlight is the largest and most
/// variable idle load, so without it a leak on a powered rail or a busy process stands out.
/// Main thread; `onChange` every second.
public final class IdlePowerRunner {
    public enum State: Equatable {
        case idle
        case settling
        case measuring
        case finished
        case failed(String)
    }

    public static let settleSeconds = 45
    public static let measureSeconds = 90
    static let allowedWakes = 5

    public private(set) var state = State.idle
    public private(set) var elapsed = 0
    /// Times the display came back on (a touch, or phantom touches of the trackpad).
    public private(set) var displayWakes = 0
    public var onChange: (() -> Void)?

    private let monitor: MonitorCore
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var samples: [Double] = []
    private var cpu: [Double] = []
    private let stats = SystemStats()
    private let smc = try? SMC()
    private var usedSMC = false
    /// Brightness before the measurement (nil: the display is put to sleep instead).
    private var savedBrightness: Float?

    /// The brightness is also kept in the defaults, so a crash during the measurement does not
    /// leave the backlight off: `restoreAfterCrash()` puts it back at the next launch.
    static let savedBrightnessKey = "idlePower.savedBrightness"

    public static func restoreAfterCrash() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: savedBrightnessKey) != nil else { return }
        DisplayPower.setBrightness(defaults.float(forKey: savedBrightnessKey))
        defaults.removeObject(forKey: savedBrightnessKey)
    }

    private var quitObserver: NSObjectProtocol?

    public init(monitor: MonitorCore) {
        self.monitor = monitor
        // Quitting during the measurement must not leave the backlight off.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            self?.cancel()
        }
    }

    deinit {
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
    }

    public var isRunning: Bool { state == .settling || state == .measuring }

    /// Seconds left in the whole measurement.
    public var remaining: Int { max(0, Self.settleSeconds + Self.measureSeconds - elapsed) }

    public func start() {
        guard !isRunning else { return }
        usedSMC = smc?.systemPower() != nil
        guard usedSMC || BatteryReader.read()?.systemPowerWatts != nil else {
            state = .failed(L("The system power cannot be read with the adapter connected on this Mac: unplug the power adapter and start again."))
            onChange?()
            return
        }
        samples = []
        cpu = []
        elapsed = 0
        displayWakes = 0
        _ = stats.cpuUsage()
        // Keep the system awake; the display may (and should) sleep.
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Idle power measurement")
        state = .settling
        if let brightness = DisplayPower.brightness(), DisplayPower.setBrightness(0) {
            savedBrightness = brightness
            UserDefaults.standard.set(brightness, forKey: Self.savedBrightnessKey)
        } else {
            savedBrightness = nil
            DisplayPower.sleepNow()
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        onChange?()
    }

    public func cancel() {
        guard isRunning else { return }
        end()
        state = .idle
        onChange?()
    }

    private func tick() {
        elapsed += 1
        if savedBrightness != nil {
            // Automatic brightness or the brightness keys may raise it again.
            if let brightness = DisplayPower.brightness(), brightness > 0.01 { DisplayPower.setBrightness(0) }
        } else if elapsed > 3, !DisplayPower.isAsleep {
            // A touch (or a phantom touch of the trackpad) woke the display: turn it off again
            // and leave this second out; give up when it keeps waking.
            displayWakes += 1
            guard displayWakes <= Self.allowedWakes else {
                end()
                state = .failed(L("The display was woken during the measurement. Start again and do not touch the Mac for two minutes."))
                onChange?()
                return
            }
            DisplayPower.sleepNow()
            onChange?()
            return
        }
        if elapsed >= Self.settleSeconds {
            state = .measuring
            let watts = usedSMC ? smc?.systemPower() : BatteryReader.read()?.systemPowerWatts
            if let watts, watts > 0 { samples.append(watts) }
            if let usage = stats.cpuUsage() { cpu.append(usage) }
        } else {
            _ = stats.cpuUsage()
        }
        if elapsed >= Self.settleSeconds + Self.measureSeconds {
            end()
            if samples.count >= 10 {
                let battery = BatteryReader.read()
                monitor.lastIdlePower = IdlePowerResult(date: Date(), samples: samples,
                                                        cpu: cpu.isEmpty ? nil : cpu.reduce(0, +) / Double(cpu.count),
                                                        onBattery: battery?.externalConnected != true,
                                                        source: usedSMC ? "smc" : "gauge")
                state = .finished
            } else {
                state = .failed(L("Too few power readings: the battery gauge did not report the power."))
            }
        }
        onChange?()
    }

    /// Stops the timer and the activity and turns the display back on (every way out).
    private func end() {
        timer?.invalidate()
        timer = nil
        if let savedBrightness {
            DisplayPower.setBrightness(savedBrightness)
            UserDefaults.standard.removeObject(forKey: Self.savedBrightnessKey)
            self.savedBrightness = nil
        } else {
            DisplayPower.wake()
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
