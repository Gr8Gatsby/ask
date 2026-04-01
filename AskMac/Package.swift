// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AskMac",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "AskMacCore",
            path: "Sources/AskMacCore"
        ),
        .executableTarget(
            name: "AskMac",
            dependencies: [
                "AskMacCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
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
