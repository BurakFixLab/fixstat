import Foundation

/// The internal SSD's volumes, also when the Mac was started from another disk (an external
/// macOS, a USB installer): free space and the write–verify test must then use the internal SSD,
/// not the startup disk. Without root: URL resource values, and `diskutil` for a container that
/// is not mounted.
public enum InternalStorage {
    /// The startup volume is on an internal disk (true when that cannot be read).
    public static var startedFromInternal: Bool {
        isInternal(URL(fileURLWithPath: "/")) ?? true
    }

    /// Space of the internal SSD: the startup volume when the Mac runs from it; otherwise a
    /// mounted internal volume (an APFS volume shows its container's space); otherwise the
    /// largest internal APFS container as `diskutil` reports it (also when it is locked).
    public static func space() -> VolumeSpace? {
        if startedFromInternal { return VolumeSpace.startup() }
        if let volume = mountedInternalVolumes().first, var space = VolumeSpace.of(volume) {
            space.startedFromOtherDisk = true
            return space
        }
        return containerSpace()
    }

    /// A writable folder on the internal SSD for the write–verify test: the temporary folder
    /// when the Mac runs from the internal SSD; otherwise a world-writable folder of a mounted
    /// internal volume; nil when there is none (not mounted, locked with FileVault, read-only).
    public static func testDirectory() -> URL? {
        if startedFromInternal { return FileManager.default.temporaryDirectory }
        for volume in mountedInternalVolumes() {
            for folder in ["private/tmp", "Users/Shared"] {
                let url = volume.appendingPathComponent(folder, isDirectory: true)
                if FileManager.default.isWritableFile(atPath: url.path) { return url }
            }
        }
        return nil
    }

    static func isInternal(_ url: URL) -> Bool? {
        (try? url.resourceValues(forKeys: [.volumeIsInternalKey]))?.volumeIsInternal
    }

    /// Mounted volumes on internal disks, largest first.
    static func mountedInternalVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeTotalCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        let found = urls.compactMap { url -> (URL, Int)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsInternal == true,
                  let total = values.volumeTotalCapacity else { return nil }
            return (url, total)
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// The largest APFS container on an internal disk, from `diskutil apfs list`.
    static func containerSpace() -> VolumeSpace? {
        guard let list = diskutil(["apfs", "list", "-plist"]),
              let containers = list["Containers"] as? [[String: Any]] else { return nil }
        let onInternalDisks = containers.filter { container in
            let stores = (container["PhysicalStores"] as? [[String: Any]] ?? []).compactMap { $0["DeviceIdentifier"] as? String }
            return stores.contains { (diskutil(["info", "-plist", $0])?["Internal"] as? Bool) == true }
        }
        return containerSpace(onInternalDisks)
    }

    static func containerSpace(_ containers: [[String: Any]]) -> VolumeSpace? {
        let sizes = containers.compactMap { container -> (Double, Double)? in
            guard let total = (container["CapacityCeiling"] as? NSNumber)?.doubleValue,
                  let free = (container["CapacityFree"] as? NSNumber)?.doubleValue else { return nil }
            return (total, free)
        }
        guard let largest = sizes.max(by: { $0.0 < $1.0 }) else { return nil }
        return VolumeSpace(total: largest.0, available: largest.1, startedFromOtherDisk: true)
    }

    /// The internal physical disk ("disk0"), whatever the startup disk is.
    static func internalWholeDisk() -> String? {
        let disks = diskutil(["list", "-plist", "internal", "physical"])?["WholeDisks"] as? [String] ?? []
        return disks.first { $0.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil }
    }

    static func diskutil(_ arguments: [String]) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}
