// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpaceWidget",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "SpaceWidget",
            path: "Sources/SpaceWidget"
        )
    ]
)
