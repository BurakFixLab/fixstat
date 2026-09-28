// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FixStat",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacSensors", targets: ["MacSensors"]),
        .executable(name: "sensordump", targets: ["sensordump"]),
    ],
    targets: [
        // C shims for the AppleSMC user client (read-only) and the private
        // IOHIDEventSystemClient API. Kept in C so struct layouts match the kernel.
        .target(
            name: "CMacSensors",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "MacSensors",
            dependencies: ["CMacSensors"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "sensordump",
            dependencies: ["MacSensors"]
        ),
        .testTarget(
            name: "MacSensorsTests",
            dependencies: ["MacSensors"]
        ),
    ]
)
