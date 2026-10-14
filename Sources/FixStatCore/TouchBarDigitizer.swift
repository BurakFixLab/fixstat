import Foundation
import IOKit.hid

/// The Touch Bar's own touch sensor ("Touch Bar Display", a HID digitizer: usage page 0x0D,
/// usage 5; MacBookPro15,1 dump), read directly while the touch test runs.
///
/// The test's cells are views on the bar, and macOS keeps two strips of a bar with the Esc key
/// on it for itself (the margin of the Esc slot and the gap between it and the app area, about
/// 16 pt on a 2018 15" MacBook Pro): touches there never reach a view. The sensor reports every
/// touch across the physical strip, so those strips are tested too. Opened without seizing it
/// (the bar keeps working); main run loop.
final class TouchBarDigitizer {
    /// Position along the strip, 0 (left end) … 1 (right end).
    var onTouch: ((Double) -> Void)?

    private var manager: IOHIDManager?

    /// False when there is no such sensor (no Touch Bar, Apple Silicon without a separate
    /// device) or it cannot be opened: the test then relies on the views alone.
    @discardableResult
    func start() -> Bool {
        guard manager == nil else { return true }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [kIOHIDProductKey: "Touch Bar Display",
                                       kIOHIDPrimaryUsagePageKey: kHIDPage_Digitizer]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<TouchBarDigitizer>.fromOpaque(context).takeUnretainedValue().handle(value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        guard !devices.isEmpty, IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            return false
        }
        self.manager = manager
        return true
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    deinit { stop() }

    /// X of a finger (generic desktop X inside the digitizer's finger collections).
    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == kHIDPage_GenericDesktop,
              IOHIDElementGetUsage(element) == kHIDUsage_GD_X else { return }
        let minimum = IOHIDElementGetLogicalMin(element), maximum = IOHIDElementGetLogicalMax(element)
        let raw = IOHIDValueGetIntegerValue(value)
        // Idle reports carry an empty finger slot at the minimum.
        guard maximum > minimum, raw > minimum else { return }
        let x = Double(raw - minimum) / Double(maximum - minimum)
        onTouch?(min(max(x, 0), 1))
    }
}
