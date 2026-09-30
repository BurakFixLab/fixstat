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
        // Read-only raw disk scanner, run as root through sudo (askpass password dialog)
        // for the full SSD test. Shipped inside FixStat.app.
        .executableTarget(name: "fixstat-diskscan"),
        // Menu bar app. Built into FixStat.app by scripts/build-app.sh, which also
        // compiles App/Localizable.xcstrings and bundles the sensor map.
        // UI-independent app logic shared by both interfaces (formatting, texts, monitoring).
        // Swift 5 mode and macOS 10.13 APIs only, like FixStatLegacy.
        .target(
            name: "FixStatCore",
            dependencies: ["MacSensors"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // AppKit interface for macOS 10.13 – 13. Swift 5 mode: no actor isolation checks,
        // which would call the Swift concurrency runtime missing before macOS 12.
        .target(
            name: "FixStatLegacy",
            dependencies: ["MacSensors", "FixStatCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "FixStat",
            dependencies: ["MacSensors", "CMacSensors", "FixStatCore", "FixStatLegacy"]
        ),
        .testTarget(
            name: "MacSensorsTests",
            dependencies: ["MacSensors", "FixStatCore"]
        ),
    ]
)
