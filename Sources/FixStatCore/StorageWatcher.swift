import Foundation
import IOKit

/// Calls `onChange` (on the main thread) shortly after a block storage device appears or goes
/// away: a drive plugged in or out, a card inserted. IOKit matching notifications on the main
/// run loop; the short delay lets the drive finish attaching (SMART, media) and folds bursts.
public final class StorageWatcher {
    public var onChange: (() -> Void)?
    /// Seconds between the last notification and `onChange`.
    public var delay: TimeInterval = 1.5

    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var generation = 0

    public init() {}

    deinit { stop() }

    public func start() {
        guard port == nil, let port = IONotificationPortCreate(mach_port_t(MACH_PORT_NULL)) else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<StorageWatcher>.fromOpaque(refcon).takeUnretainedValue()
            StorageWatcher.drain(iterator)
            watcher.changed()
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, type, IOServiceMatching("IOBlockStorageDevice"), callback, refcon,
                                                &iterator) == KERN_SUCCESS {
                // Arms the notification; the devices already there are not a change.
                Self.drain(iterator)
                iterators.append(iterator)
            }
        }
    }

    public func stop() {
        generation += 1
        for iterator in iterators { IOObjectRelease(iterator) }
        iterators = []
        if let port {
            IONotificationPortDestroy(port)
            self.port = nil
        }
    }

    private func changed() {
        generation += 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == current, self.port != nil else { return }
            self.onChange?()
        }
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            IOObjectRelease(service)
        }
    }
}
