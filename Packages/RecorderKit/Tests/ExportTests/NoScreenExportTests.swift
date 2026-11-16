// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Render
import SyntheticCapture
import Testing

// A take without screen segments (design §7.6, plan decision 18): an editable document exports its background, camera
// and audio for as long as its sequence lasts; the legacy document still refuses it, as phase 0 and 1a do.

/// A take of 2 s of the microphone alone: a 440 Hz tone.
private func microphoneOnly(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir)
    try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 2)])
    return try builder.write()
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func editableTakeWithoutScreenExportsAudioOverTheBackground() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await microphoneOnly(in: dir)
        let bounds = TakeTimeline.editableBounds(take: project.take, events: project.events)
        #expect(bounds.start == base && bounds.end == base.adding(seconds: 2))
        var document = EditDocument.legacy(for: project)
        document.sequence = [Clip(id: "c-00000001", take: project.take.id, start: bounds.start, end: bounds.end, speed: 1)]
        document.audio.limiter = true
        let destination = dir.appending(path: "out.mp4")
        let summary = try await MP4Exporter(
            project: project, document: document, settings: ExportSettings(outputSize: [320, 180], framesPerSecond: 30)
        ).export(to: destination) { _ in }
        #expect(summary == ExportSummary())

        let asset = AVURLAsset(url: destination)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let videoSeconds = try await video.load(.timeRange).duration.seconds
        #expect(abs(videoSeconds - 2) <= 1.0 / 30 + 1e-6, "\(videoSeconds) s of video")
        let frames = try await readVideoFrames(of: destination, into: [DecodedFrame]()) { $0.append($1) }
        #expect(abs(frames.count - 60) <= 1, "\(frames.count) frames")
        // The background, the classic gradient: never black.
        let middle = try #require(frames.dropFirst(30).first)
        let centre = pixel(middle.bytes, width: middle.width, x: middle.width / 2, y: middle.height / 2)
        #expect(Int(centre.x) + Int(centre.y) + Int(centre.z) > 150, "\(centre)")
        // The microphone's tone, all along.
        let (start, samples) = try await decodedAudio(of: destination)
        #expect(abs(Double(samples.count) / 48_000 - 2) <= 0.05, "\(samples.count) samples")
        #expect(toneAmplitude(samples, start: start, frequency: 440, from: 0.2, to: 1.8) > 0.2)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func legacyTakeWithoutScreenStillFails() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await microphoneOnly(in: dir)
        let destination = dir.appending(path: "out.mp4")
        await #expect(throws: ExportError.noDisplayTrack) {
            try await MP4Exporter(project: project, settings: ExportSettings(outputSize: [320, 180], framesPerSecond: 30))
                .export(to: destination) { _ in }
        }
        await #expect(throws: ExportError.noDisplayTrack) {
            try await MP4Exporter(
                project: project, document: .legacy(for: project), settings: ExportSettings(outputSize: [320, 180], framesPerSecond: 30)
            ).export(to: destination) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try partialFiles(in: dir).isEmpty)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func editedOldTakeWithoutScreenExportsAllItRecorded() async throws {
    try await withTemporaryDirectory { dir in
        // The microphone for 2 s and the camera from 0.5 s to 2.5 s: the legacy document's clip is all of it.
        let builder = try TakeBuilder(in: dir)
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 2)])
        let camera = TrackSource(name: "Synthetic Camera", deviceUniqueID: "synthetic-camera")
        try await builder.addVideoTrack(
            id: "camera", kind: .camera, source: camera, segments: [VideoSegmentSpec(start: base.adding(seconds: 0.5), seconds: 2)])
        let project = try builder.write()
        var document = EditDocument.legacy(for: project)
        #expect(document.sequence.map { $0.start..<$0.end } == [base..<base.adding(seconds: 2.5)])
        // Edited, it is no longer the legacy document, and exports the whole take.
        document.style.background = .color(RGBA(0.2, 0.3, 0.4, 1))
        let destination = dir.appending(path: "out.mp4")
        let settings = ExportSettings(outputSize: [320, 180], framesPerSecond: 30)
        _ = try await MP4Exporter(project: project, document: document, settings: settings).export(to: destination) { _ in }
        let video = try #require(try await AVURLAsset(url: destination).loadTracks(withMediaType: .video).first)
        let seconds = try await video.load(.timeRange).duration.seconds
        #expect(abs(seconds - 2.5) <= 1.0 / 30 + 1e-6, "\(seconds) s of video")
        let (start, samples) = try await decodedAudio(of: destination)
        #expect(abs(Double(samples.count) / 48_000 - 2.5) <= 0.05, "\(samples.count) samples")
        #expect(toneAmplitude(samples, start: start, frequency: 440, from: 0.2, to: 1.8) > 0.2)
        // Untouched, it still refuses the take, as phase 0 and 1a do.
        await #expect(throws: ExportError.noDisplayTrack) {
            try await MP4Exporter(project: project, settings: settings).export(to: dir.appending(path: "legacy.mp4")) { _ in }
        }
    }
}
