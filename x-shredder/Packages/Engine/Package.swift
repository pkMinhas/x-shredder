// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Engine",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Engine", targets: ["Engine"]),
    ],
    targets: [
        // Thin C wrappers for the disk ioctls, which are macros Swift cannot import.
        .target(name: "CDiskIO"),
        .target(name: "Engine", dependencies: ["CDiskIO"]),
        .testTarget(name: "EngineTests", dependencies: ["Engine"]),
    ]
)
