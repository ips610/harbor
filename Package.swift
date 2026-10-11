// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "harbor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Harbor",
            path: "Sources/Harbor"
        ),
        .testTarget(
            name: "HarborTests",
            dependencies: ["Harbor"],
            path: "Tests/HarborTests"
        ),
    ]
)
