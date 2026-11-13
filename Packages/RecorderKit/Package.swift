// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "RecorderKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RecorderKit", targets: ["ProjectFormat"]),
    ],
    targets: [
        .target(name: "ProjectFormat"),
        .testTarget(name: "ProjectFormatTests", dependencies: ["ProjectFormat"]),
    ],
    swiftLanguageModes: [.v6]
)
