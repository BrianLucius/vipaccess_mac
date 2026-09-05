// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VIPAccess",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "VIPAccess", targets: ["VIPAccess"])
    ],
    targets: [
        .executableTarget(
            name: "VIPAccess",
            path: "VIPAccess",
            exclude: ["Info.plist", "VIPAccess.entitlements", "VIPAccess-dev.entitlements"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("IOKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "VIPAccessTests",
            dependencies: ["VIPAccess"],
            path: "VIPAccessTests"
        )
    ]
)
