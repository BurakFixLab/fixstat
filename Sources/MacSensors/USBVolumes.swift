import Foundation
import IOKit

/// A mounted, writable volume on a USB drive, with the USB device it is on.
public struct USBVolume: Equatable, Sendable {
    public var url: URL
    public var name: String
    /// "disk4s1"
    public var bsdName: String
    /// Free space in bytes.
    public var availableBytes: Int64
    public var device: USBDeviceInfo
    /// The XHCI root hub port above the device (Macs without `IOPort` services).
    public var rootPortLocation: Int?

    public init(url: URL, name: String, bsdName: String, availableBytes: Int64, device: USBDeviceInfo,
                rootPortLocation: Int? = nil) {
        self.url = url
        self.name = name
        self.bsdName = bsdName
        self.availableBytes = availableBytes
        self.device = device
        self.rootPortLocation = rootPortLocation
    }

    /// The port the drive is plugged into, among `ports` from `PortReader.read()`.
    public func port(in ports: [PortStatus]) -> PortStatus? {
        if let number = device.portNumber, let port = ports.first(where: { $0.type == "USB-C" && $0.number == number }) {
            return port
        }
        // XHCI ports list their devices; the same USB device (ignoring the port number).
        return ports.first { port in
            port.devices.contains { $0.vendorID == device.vendorID && $0.productID == device.productID
                && $0.speed == device.speed && $0.name == device.name }
        }
    }
}

public enum USBVolumes {
    /// Mounted volumes that are writable and sit on a USB device.
    public static func mounted() -> [USBVolume] {
        if UserDefaults.standard.bool(forKey: "FixStatSampleUSBDrive") { return [sampleDrive()] }
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsReadOnlyKey,
                                      .volumeIsLocalKey, .volumeAvailableCapacityKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                               options: [.skipHiddenVolumes]) else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == true, values.volumeIsReadOnly != true, values.volumeIsInternal != true,
                  let bsd = bsdName(of: url), let found = usbDevice(bsdName: bsd) else { return nil }
            return USBVolume(url: url, name: values.volumeName ?? url.lastPathComponent, bsdName: bsd,
                             availableBytes: Int64(values.volumeAvailableCapacity ?? 0),
                             device: found.device, rootPortLocation: found.rootPortLocation)
        }
    }

    /// `-FixStatSampleUSBDrive YES`: a made-up memory stick (the one `-FixStatSampleUSBA` shows in
    /// USB-A 1) whose "volume" is a folder in the temporary directory, to try the speed test.
    static func sampleDrive() -> USBVolume {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FixStat sample drive")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0
        return USBVolume(url: url, name: "SAMPLE", bsdName: "disk99s1", availableBytes: Int64(free),
                         device: USBDeviceInfo(name: "USB Flash Drive", vendorID: 0x0781, productID: 0x5581,
                                               speed: 3, portNumber: nil))
    }

    /// "/dev/disk4s1" of the mount → "disk4s1".
    static func bsdName(of url: URL) -> String? {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return nil }
        let from = withUnsafePointer(to: &fs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return from.hasPrefix("/dev/") ? String(from.dropFirst(5)) : nil
    }

    /// Walks up the service plane from the volume's media to the USB device it is on.
    static func usbDevice(bsdName: String) -> (device: USBDeviceInfo, rootPortLocation: Int?)? {
        guard let matching = IOBSDNameMatching(ioMainPort, 0, bsdName) else { return nil }
        var current = IOServiceGetMatchingService(ioMainPort, matching)
        guard current != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(current) }
        // APFS volumes sit a few levels above the physical media: container, scheme, partition.
        for _ in 0..<32 {
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 {
                let p = Registry.properties(of: current) ?? [:]
                let device = USBDeviceInfo(name: p.string("USB Product Name") ?? p.string("kUSBProductString"),
                                           vendorID: p.int("idVendor"), productID: p.int("idProduct"),
                                           speed: p.int("Device Speed"),
                                           portNumber: PortReader.usbCPortNumber(above: current))
                return (device, PortReader.rootPortLocation(above: current))
            }
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent
        }
        return nil
    }
}
