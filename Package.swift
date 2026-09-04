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
        .target(
            name: "ScreamBarCoreAudioRT",
            path: "Sources/ScreamBarCoreAudioRT",
            publicHeadersPath: "include"
        ),
        .target(
            name: "ScreamBarLoopbackTestRT",
            path: "Tests/ScreamBarLoopbackTestRT",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "ScreamBar",
            dependencies: [
                "KeyboardShortcuts",
                "ScreamBarCoreAudioRT",
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
            dependencies: [
                "ScreamBar",
                "ScreamBarCoreAudioRT",
                "ScreamBarLoopbackTestRT",
            ],
            path: "Tests/ScreamBarTests",
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("CoreAudio"),
            ]
        ),
    ]
)
