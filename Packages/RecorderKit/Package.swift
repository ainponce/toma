// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "RecorderKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RecorderKit", targets: ["ProjectFormat", "Recording", "SyntheticCapture"]),
    ],
    targets: [
        .target(name: "ProjectFormat"),
        .target(name: "Recording", dependencies: ["ProjectFormat"]),
        .target(name: "SyntheticCapture", dependencies: ["Recording", "ProjectFormat"]),
        .testTarget(name: "ProjectFormatTests", dependencies: ["ProjectFormat"]),
        .testTarget(name: "RecordingTests", dependencies: ["Recording", "SyntheticCapture", "ProjectFormat"]),
    ],
    swiftLanguageModes: [.v6]
)
