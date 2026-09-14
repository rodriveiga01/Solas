// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ask",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Ask",
            path: "Sources/Ask"
        )
    ]
)
