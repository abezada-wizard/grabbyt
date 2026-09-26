// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Grabbyt",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "GrabbytCore",
            path: "Sources/Grabbyt/Core"
        ),
        .executableTarget(
            name: "Grabbyt",
            dependencies: ["GrabbytCore"],
            path: "Sources/Grabbyt",
            exclude: ["Core"]
        ),
        // Autopruebas sin XCTest/Testing (no están en las Command Line Tools): `swift run SelfTest`
        .executableTarget(
            name: "SelfTest",
            dependencies: ["GrabbytCore"],
            path: "Sources/SelfTest",
            swiftSettings: [.unsafeFlags(["-enable-testing"])]
        ),
    ]
)
