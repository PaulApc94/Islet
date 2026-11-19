// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Islet",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Islet",
            path: "Sources/Islet"
        ),
        // Run with `swift test`. Uses Swift Testing, which ships with the
        // Command Line Tools: no Xcode needed here either.
        .testTarget(
            name: "IsletTests",
            dependencies: ["Islet"],
            path: "Tests/IsletTests"
        ),
    ]
)
