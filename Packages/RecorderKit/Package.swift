// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "RecorderKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RecorderKit", targets: ["ProjectFormat", "Recording", "SyntheticCapture", "Recovery", "Render", "Export"]),
        .library(name: "AppSupport", targets: ["AppSupport"]),
        .executable(name: "recorder-dev", targets: ["recorder-dev"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "ProjectFormat"),
        .target(name: "Recording", dependencies: ["ProjectFormat"]),
        .target(name: "SyntheticCapture", dependencies: ["Recording", "ProjectFormat"]),
        .target(name: "Recovery", dependencies: ["ProjectFormat"]),
        .target(name: "Render", dependencies: ["ProjectFormat"]),
        .target(name: "Export", dependencies: ["Render", "ProjectFormat"]),
        .target(name: "AppSupport", dependencies: ["ProjectFormat", "Recording"]),
        .executableTarget(
            name: "recorder-dev",
            dependencies: [
                "ProjectFormat", "Recording", "SyntheticCapture", "Recovery", "Export",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "ProjectFormatTests", dependencies: ["ProjectFormat"]),
        .testTarget(name: "RecordingTests", dependencies: ["Recording", "SyntheticCapture", "ProjectFormat"]),
        .testTarget(name: "RecoveryTests", dependencies: ["Recovery", "Recording", "SyntheticCapture", "ProjectFormat"]),
        .testTarget(name: "RenderTests", dependencies: ["Render", "Recording", "SyntheticCapture", "ProjectFormat"]),
        .testTarget(name: "ExportTests", dependencies: ["Export", "Render", "Recording", "SyntheticCapture", "ProjectFormat"]),
        .testTarget(name: "AppSupportTests", dependencies: ["AppSupport", "ProjectFormat", "Recording", "SyntheticCapture"]),
    ],
    swiftLanguageModes: [.v6]
)
