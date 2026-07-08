// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Clawlicious",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Clawlicious", targets: ["Clawlicious"]),
        .executable(name: "ClawliciousMenuBarHelper", targets: ["ClawliciousMenuBarHelper"])
    ],
    targets: [
        .target(name: "ClawliciousBrowser"),
        .target(name: "ClawliciousCore"),
        .executableTarget(
            name: "Clawlicious",
            dependencies: ["ClawliciousBrowser", "ClawliciousCore"],
            exclude: ["Info.plist", "Resources/AppIcon.icns"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Clawlicious/Info.plist"
                ])
            ]
        ),
        .executableTarget(
            name: "ClawliciousMenuBarHelper",
            dependencies: ["ClawliciousBrowser", "ClawliciousCore"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/ClawliciousMenuBarHelper/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "ClawliciousTests",
            dependencies: ["Clawlicious", "ClawliciousCore"]
        )
    ]
)
