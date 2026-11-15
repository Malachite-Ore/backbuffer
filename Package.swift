// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Backbuffer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "BackbufferCore",
            targets: ["BackbufferCore"]
        ),
        .executable(
            name: "BackbufferApp",
            targets: ["BackbufferApp"]
        )
    ],
    targets: [
        .target(
            name: "BackbufferCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox")
            ]
        ),
        .executableTarget(
            name: "BackbufferApp",
            dependencies: ["BackbufferCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "BackbufferCoreTests",
            dependencies: ["BackbufferCore"]
        )
    ]
)
