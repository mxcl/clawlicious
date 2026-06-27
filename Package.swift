// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Clawlicious",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Clawlicious", targets: ["Clawlicious"])
    ],
    targets: [
        .target(name: "ClawliciousCore"),
        .executableTarget(
            name: "Clawlicious",
            dependencies: ["ClawliciousCore"]
        ),
        .testTarget(
            name: "ClawliciousTests",
            dependencies: ["Clawlicious", "ClawliciousCore"]
        )
    ]
)
