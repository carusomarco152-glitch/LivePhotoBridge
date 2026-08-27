// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LivePhotoBridge",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "LivePhotoBridgeCore", targets: ["LivePhotoBridgeCore"])
    ],
    targets: [
        .target(
            name: "LivePhotoBridgeCore",
            path: "Sources/LivePhotoBridgeCore"
        ),
        .testTarget(
            name: "LivePhotoBridgeCoreTests",
            dependencies: ["LivePhotoBridgeCore"],
            path: "Tests/LivePhotoBridgeCoreTests"
        )
    ]
)
