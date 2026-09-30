import Foundation
import MacSensors

/// Runs the memory test on a background thread; state changes arrive on the main thread
/// through `onChange`. Its state is only touched on the main thread.
public final class MemoryRunner: @unchecked Sendable {
    public enum State: Equatable { case idle, running, finished }

    public private(set) var state = State.idle
    public private(set) var fraction = 0.0
    public private(set) var pattern: MemoryTest.Pattern?
    public private(set) var result: MemoryTest.Result?
    public var onChange: (() -> Void)?

    private var test: MemoryTest?
    private let monitor: MonitorCore
    private var activity: NSObjectProtocol?

    public init(monitor: MonitorCore) {
        self.monitor = monitor
    }

    public func start(bytes: UInt64, rounds: Int) {
        guard state != .running else { return }
        let test = MemoryTest()
        self.test = test
        state = .running
        fraction = 0
        pattern = nil
        result = nil
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Memory test")
        onChange?()
        Thread.detachNewThread { [weak self] in
            let result = test.run(bytes: bytes, rounds: rounds) { progress in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.fraction = progress.fraction
                    self.pattern = progress.pattern
                    self.onChange?()
                }
            }
            DispatchQueue.main.async { self?.finish(result) }
        }
    }

    public func stop() { test?.cancel() }

    private func finish(_ result: MemoryTest.Result) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        test = nil
        self.result = result
        monitor.lastMemoryResult = result
        state = .finished
        onChange?()
    }
}
