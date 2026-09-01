// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexAccountSwitcher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "CodexAccountSwitcher",
            targets: ["CodexAccountSwitcher"]
        )
    ],
    targets: [
        .executableTarget(
            name: "CodexAccountSwitcher",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "CodexAccountSwitcherTests",
            dependencies: ["CodexAccountSwitcher"]
        )
    ]
)
