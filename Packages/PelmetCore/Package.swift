// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PelmetCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "PelmetCore", targets: ["PelmetCore"]),
    ],
    targets: [
        .target(name: "PelmetCore", path: "Sources/PelmetCore"),
        .testTarget(
            name: "PelmetCoreTests",
            dependencies: ["PelmetCore"],
            path: "Tests/PelmetCoreTests"
        ),
    ]
)
