// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Report",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Report", targets: ["Report"]),
    ],
    targets: [
        .target(name: "Report"),
        .testTarget(name: "ReportTests", dependencies: ["Report"]),
    ]
)
