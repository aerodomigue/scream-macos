// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ScreamBar",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(
            name: "ScreamBar",
            path: "Sources/ScreamBar"
        ),
    ]
)
