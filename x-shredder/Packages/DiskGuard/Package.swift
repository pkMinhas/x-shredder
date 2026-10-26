// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DiskGuard",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DiskGuard", targets: ["DiskGuard"]),
    ],
    targets: [
        .target(name: "DiskGuard"),
        // Read-only tool that prints the description of every disk as JSON.
        // Used to record fixtures from real hardware. It never opens a device.
        .executableTarget(name: "diskguard-dump", dependencies: ["DiskGuard"]),
        .testTarget(
            name: "DiskGuardTests",
            dependencies: ["DiskGuard"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
