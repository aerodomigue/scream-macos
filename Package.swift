// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ScreamBar",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "ScreamBar",
            dependencies: [
                "KeyboardShortcuts",
            ],
            path: "Sources/ScreamBar",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
