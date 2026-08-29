// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PelmetEngine",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "PelmetEngine", targets: ["PelmetEngine"]),
        .executable(name: "pelmet-probe", targets: ["pelmet-probe"]),
    ],
    dependencies: [
        .package(path: "../PelmetCore"),
    ],
    targets: [
        // ObjC shim: dlopen/NSClassFromString access to MenuBarClientCore's
        // assessment-mode classes. Kept ObjC so exceptions from private API
        // calls can be caught (@try/@catch) without tearing the process down.
        .target(
            name: "PelmetEngineObjC",
            path: "Sources/PelmetEngineObjC"
        ),
        .target(
            name: "PelmetEngine",
            dependencies: [
                "PelmetEngineObjC",
                .product(name: "PelmetCore", package: "PelmetCore"),
            ],
            path: "Sources/PelmetEngine"
        ),
        // M1 spike harness. Throwaway: proves hide/reorder/enumerate/click on
        // this machine before any UI work starts.
        .executableTarget(
            name: "pelmet-probe",
            dependencies: ["PelmetEngine"],
            path: "Sources/pelmet-probe"
        ),
        // Pure-logic tests only (ConvergePlan and friends) — nothing here may
        // touch AX, the private framework, or the real menu bar.
        .testTarget(
            name: "PelmetEngineTests",
            dependencies: ["PelmetEngine"],
            path: "Tests/PelmetEngineTests"
        ),
    ]
)
