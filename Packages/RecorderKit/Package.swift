// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "RecorderKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "RecorderKit", targets: [
                "ProjectFormat", "Analysis", "Editing", "Recording", "SyntheticCapture", "Recovery", "Render", "Export",
                "Library",
            ]),
        .library(name: "AppSupport", targets: ["AppSupport"]),
        .executable(name: "recorder-dev", targets: ["recorder-dev"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "ProjectFormat"),
        .target(name: "Analysis", dependencies: ["ProjectFormat"]),
        .target(name: "Editing", dependencies: ["ProjectFormat", "Analysis"]),
        .target(name: "Recording", dependencies: ["ProjectFormat"]),
        .target(name: "SyntheticCapture", dependencies: ["Recording", "ProjectFormat"]),
        .target(name: "Recovery", dependencies: ["ProjectFormat"]),
        .target(name: "Render", dependencies: ["ProjectFormat", "Analysis"]),
        .target(name: "Export", dependencies: ["Render", "ProjectFormat"]),
        .target(name: "Library", dependencies: ["ProjectFormat", "Analysis", "Editing", "Render"]),
        .target(name: "AppSupport", dependencies: ["ProjectFormat", "Recording"]),
        // Shared by every test target; not a product.
        .target(name: "RecorderKitTestSupport", dependencies: ["ProjectFormat", "Recording", "SyntheticCapture"]),
        .executableTarget(
            name: "recorder-dev",
            dependencies: [
                "ProjectFormat", "Recording", "SyntheticCapture", "Recovery", "Export", "Editing", "Analysis",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "ProjectFormatTests", dependencies: ["ProjectFormat", "RecorderKitTestSupport"]),
        .testTarget(name: "AnalysisTests", dependencies: ["Analysis", "ProjectFormat", "RecorderKitTestSupport"]),
        .testTarget(name: "EditingTests", dependencies: ["Editing", "Analysis", "ProjectFormat", "RecorderKitTestSupport"]),
        .testTarget(name: "RecordingTests", dependencies: ["Recording", "SyntheticCapture", "ProjectFormat", "RecorderKitTestSupport"]),
        .testTarget(
            name: "RecoveryTests", dependencies: ["Recovery", "Recording", "SyntheticCapture", "ProjectFormat", "RecorderKitTestSupport"]),
        .testTarget(
            name: "RenderTests",
            dependencies: ["Render", "Analysis", "Recording", "SyntheticCapture", "ProjectFormat", "RecorderKitTestSupport"]),
        .testTarget(
            name: "ExportTests",
            dependencies: ["Export", "Render", "Recording", "Recovery", "SyntheticCapture", "ProjectFormat", "RecorderKitTestSupport"]),
        .testTarget(
            name: "AppSupportTests", dependencies: ["AppSupport", "ProjectFormat", "Recording", "SyntheticCapture", "RecorderKitTestSupport"]),
        .testTarget(name: "LibraryTests", dependencies: ["Library", "Editing", "ProjectFormat", "RecorderKitTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
