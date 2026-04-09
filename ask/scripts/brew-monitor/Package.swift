// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "brew-monitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "brew-monitor", path: "Sources")
    ]
)
