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
            dependencies: ["ClawliciousCore"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Clawlicious/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "ClawliciousTests",
            dependencies: ["Clawlicious", "ClawliciousCore"]
        )
    ]
)
