// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AskMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AskMac",
            path: "Sources/AskMac",
            resources: [.process("Assets.xcassets")]
        )
    ]
)
