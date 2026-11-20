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
                "Library", "Transcription", "ImageAnalysis", "ProjectJobs", "LocalAI", "Sharing",
            ]),
        .library(name: "AppSupport", targets: ["AppSupport"]),
        .executable(name: "recorder-dev", targets: ["recorder-dev"]),
        .library(name: "ProjectAPI", targets: ["ProjectAPI"]),
        .executable(name: "toma", targets: ["toma"]),
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
        .target(name: "Export", dependencies: ["Render", "ProjectFormat", "Analysis"]),
        .target(name: "Library", dependencies: ["ProjectFormat", "Analysis", "Editing", "Render"]),
        .target(name: "AppSupport", dependencies: ["ProjectFormat", "Recording", "Analysis", "Editing", "Sharing"]),
        // Phase 2's analysis (design of phase 2, §10, plan decision 15): no other module depends on these three.
        .target(name: "Transcription", dependencies: ["ProjectFormat", "Export"]),
        .target(name: "ImageAnalysis", dependencies: ["ProjectFormat", "Analysis", "Render"]),
        .target(name: "ProjectJobs", dependencies: ["ProjectFormat", "Editing", "Export", "Transcription", "ImageAnalysis"]),
        // Phase 4's project API (milestone 4b): what the `toma` command and the control socket share. No AppKit.
        .target(
            name: "ProjectAPI",
            dependencies: ["ProjectFormat", "Analysis", "Editing", "Render", "Export", "ProjectJobs", "Transcription"]),
        .executableTarget(name: "toma", dependencies: ["ProjectAPI", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        // Phase 5's local AI (milestone 5b): chapters, title and summary from the transcript. FoundationModels is imported
        // only in `SystemTextModel.swift`, behind macOS 26, so it links weakly and Toma still opens on macOS 15. No AppKit.
        .target(name: "LocalAI", dependencies: ["ProjectFormat", "Analysis"]),
        // Phase 5's share links (milestone 5a): SigV4, the S3 client, the page and shares.json. No AppKit, no user text.
        .target(name: "Sharing", dependencies: ["ProjectFormat", "Analysis"]),
        // Shared by every test target; not a product. `Editing` for `MediaFixtures.imported`, which imports as the editor does.
        .target(name: "RecorderKitTestSupport", dependencies: ["ProjectFormat", "Recording", "SyntheticCapture", "Editing"]),
        .executableTarget(
            name: "recorder-dev",
            dependencies: [
                "ProjectFormat", "Recording", "SyntheticCapture", "Recovery", "Export", "Editing", "Analysis", "Render",
                "Library",
                // `fake-transcript` only: a made-up transcript (`FakeTranscript`) for screenshots.
                "RecorderKitTestSupport",
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
            dependencies: [
                "Export", "Render", "Analysis", "Recording", "Recovery", "SyntheticCapture", "ProjectFormat", "RecorderKitTestSupport",
            ]),
        .testTarget(
            name: "AppSupportTests",
            dependencies: [
                "AppSupport", "ProjectFormat", "Recording", "Analysis", "Editing", "SyntheticCapture", "RecorderKitTestSupport",
                // Only the tests: they tie what the export sheet remembers to Export's own values (plan decision 41).
                "Export",
                // Only the tests: a metered microphone's listener feeding Follow the Voice's live feed (plan 3d, T5).
                "Transcription",
                "Sharing",
            ]),
        .testTarget(name: "LibraryTests", dependencies: ["Library", "Editing", "ProjectFormat", "Render", "RecorderKitTestSupport"]),
        .testTarget(name: "TranscriptionTests", dependencies: ["Transcription", "ProjectFormat", "Export", "Recording", "SyntheticCapture", "RecorderKitTestSupport"]),
        .testTarget(name: "ImageAnalysisTests", dependencies: ["ImageAnalysis", "ProjectFormat", "RecorderKitTestSupport"]),
        .testTarget(name: "ProjectJobsTests", dependencies: ["ProjectJobs", "Editing", "ProjectFormat", "Export", "Transcription", "RecorderKitTestSupport"]),
        .testTarget(
            name: "ProjectAPITests",
            dependencies: [
                "ProjectAPI", "ProjectFormat", "Analysis", "Editing", "Export", "ProjectJobs", "Transcription", "RecorderKitTestSupport",
            ]),
        .testTarget(name: "LocalAITests", dependencies: ["LocalAI", "ProjectFormat", "Analysis", "RecorderKitTestSupport"]),
        .testTarget(
            name: "SharingTests", dependencies: ["Sharing", "ProjectFormat", "Analysis", "SyntheticCapture", "RecorderKitTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
