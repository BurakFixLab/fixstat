// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FixStat",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacSensors", targets: ["MacSensors"]),
        .executable(name: "sensordump", targets: ["sensordump"]),
        .executable(name: "sensormap", targets: ["sensormap"]),
        .executable(name: "fixstat-diskscan", targets: ["fixstat-diskscan"]),
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
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Metal")]
        ),
        .executableTarget(
            name: "sensordump",
            dependencies: ["MacSensors"]
        ),
        .executableTarget(
            name: "sensormap",
            dependencies: ["MacSensors"]
        ),
        // Read-only raw disk scanner, run as root through the macOS administrator
        // prompt for the full SSD test. Shipped inside FixStat.app.
        .executableTarget(name: "fixstat-diskscan"),
        // Menu bar app. Built into FixStat.app by scripts/build-app.sh, which also
        // compiles App/Localizable.xcstrings and bundles the sensor map.
        .executableTarget(
            name: "FixStat",
            dependencies: ["MacSensors"]
        ),
        .testTarget(
            name: "MacSensorsTests",
            dependencies: ["MacSensors"]
        ),
    ]
)
