import Foundation
import MacSensors

/// Runs the SSD write–verify test on a background thread; progress arrives on the main
/// thread through `onChange`. Its state is only touched on the main thread.
public final class SSDRunner: @unchecked Sendable {
    public enum State: Equatable { case idle, running, finished }

    public private(set) var state = State.idle
    public private(set) var phase = SSDStressTest.Phase.write
    public private(set) var fraction = 0.0
    /// MB/s per chunk, in chunk order.
    public private(set) var writeSpeeds: [Double] = []
    public private(set) var readSpeeds: [Double] = []
    public private(set) var result: SSDStressTest.Result?
    public var onChange: (() -> Void)?

    private var test: SSDStressTest?
    private let monitor: MonitorCore
    private var activity: NSObjectProtocol?

    public init(monitor: MonitorCore) {
        self.monitor = monitor
    }

    /// Free space the test may use, in bytes.
    public static var availableBytes: Int64 {
        SSDStressTest.availableBytes(in: FileManager.default.temporaryDirectory)
    }

    public func start(gigabytes: Double) {
        guard state != .running else { return }
        let test = SSDStressTest()
        self.test = test
        state = .running
        phase = .write
        fraction = 0
        writeSpeeds = []
        readSpeeds = []
        result = nil
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "SSD stress test")
        onChange?()
        let bytes = Int64(gigabytes * 1_000_000_000)
        let directory = FileManager.default.temporaryDirectory
        Thread.detachNewThread { [weak self] in
            let result = test.run(bytes: bytes, directory: directory) { progress in
                DispatchQueue.main.async { self?.update(progress) }
            }
            DispatchQueue.main.async { self?.finish(result) }
        }
    }

    public func stop() {
        test?.cancel()
    }

    private func update(_ progress: SSDStressTest.Progress) {
        phase = progress.phase
        let done = Double(progress.chunk) / Double(max(progress.chunkCount, 1))
        fraction = progress.phase == .write ? done / 2 : 0.5 + done / 2
        switch progress.phase {
        case .write: writeSpeeds.append(progress.throughput)
        case .verify: readSpeeds.append(progress.throughput)
        }
        onChange?()
    }

    private func finish(_ result: SSDStressTest.Result) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        test = nil
        self.result = result
        monitor.lastSSDResult = result
        state = .finished
        onChange?()
    }

    /// The SSD's own cache makes single write blocks spiky; charts show a moving average.
    public static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, !values.isEmpty else { return values }
        var result: [Double] = []
        result.reserveCapacity(values.count)
        var sum = 0.0
        for (index, value) in values.enumerated() {
            sum += value
            if index >= window { sum -= values[index - window] }
            result.append(sum / Double(min(index + 1, window)))
        }
        return result
    }
}
