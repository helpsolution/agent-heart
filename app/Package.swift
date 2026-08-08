// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentHeart",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AgentHeart",
            path: "Sources/AgentHeart",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
