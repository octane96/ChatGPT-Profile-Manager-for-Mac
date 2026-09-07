// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ChatGPTProfileManager",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "ChatGPTProfileManager",
            targets: ["ChatGPTProfileManager"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ChatGPTProfileManager",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "ChatGPTProfileManagerTests",
            dependencies: ["ChatGPTProfileManager"]
        )
    ]
)
