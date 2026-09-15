// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Solas",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Solas",
            path: "Sources/Solas"
        ),
        .testTarget(
            name: "SolasTests",
            dependencies: ["Solas"],
            path: "Tests/SolasTests"
        ),
    ]
)
