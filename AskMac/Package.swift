// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AskMac",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "AskMacCore",
            path: "Sources/AskMacCore"
        ),
        .executableTarget(
            name: "AskMac",
            dependencies: ["AskMacCore"],
            path: "Sources/AskMac",
            resources: [.process("Assets.xcassets")]
        ),
        .testTarget(
            name: "AskMacTests",
            dependencies: ["AskMacCore"],
            path: "Tests/AskMacTests"
        )
    ]
)
