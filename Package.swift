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
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "ScreamBarTests",
            dependencies: ["ScreamBar"],
            path: "Tests/ScreamBarTests",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("CoreAudio"),
            ]
        ),
    ]
)
