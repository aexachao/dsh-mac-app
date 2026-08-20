// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSHWeb",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DSHWeb",
            path: "Sources/DSHWeb"
        )
    ]
)
