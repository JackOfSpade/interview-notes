// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rehearse",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Rehearse", targets: ["Rehearse"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Rehearse",
            dependencies: [],
            path: "Sources"
        ),
        .testTarget(
            name: "RehearseTests",
            dependencies: ["Rehearse"],
            path: "Tests/RehearseTests"
        )
    ]
)
