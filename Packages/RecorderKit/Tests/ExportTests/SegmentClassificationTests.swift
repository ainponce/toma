// SPDX-License-Identifier: GPL-3.0-or-later
import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Recovery
import Render
import Testing

// Recovery and the verifier inspect a segment's file, the screen reader and the microphone timeline classify
// it from the manifest and the file system: a file of 0 bytes, one that is not a movie and one that is gone
// come out the same way in all four.

private let settings = ExportSettings(outputSize: [640, 360], framesPerSecond: 30)

/// A screen and a microphone track with one readable second each, then segments 2, 3 and 4, a second apart,
/// whose files are of 0 bytes, 4096 bytes that are not a movie, and gone. Each ends with its `endReasons`
/// entry, a second after it starts, or is left open when that is `nil`.
private func addTracksWithBrokenSegments(to builder: TakeBuilder, endReasons: [SegmentEndReason?]) async throws {
    try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 1)])
    try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 1)])
    let files: [SegmentFileFixture] = [.zeroBytes, .garbage(bytes: 4096), .absent]
    for track in [displayID, micID] {
        for (k, (file, endReason)) in zip(files, endReasons).enumerated() {
            let start = base.adding(seconds: Double(k + 1))
            try builder.addEmptySegment(
                track: track, index: k + 2, start: start, end: endReason.map { _ in start.adding(seconds: 1) },
                endReason: endReason, file: file)
        }
    }
}

@Test func recoveryClassifiesOpenSegments() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await addTracksWithBrokenSegments(to: builder, endReasons: [nil, nil, nil])
        let package = try builder.write(status: .recording).package

        let recovered = try await TakeRecovery.recover(package: package, takeID: takeID)

        try #require(recovered.tracks.map(\.id) == [displayID, micID])
        for track in recovered.tracks {
            #expect(track.segments.map(\.endReason) == [.stopped, .empty, .unreadable(bytes: 4096), .empty], "\(track.id)")
        }
        let verdicts = await TakeVerifier.verify(try LoadedProject.load(package.url), minDuration: 0, maxDropRatio: nil)
        try #require(verdicts.map(\.trackID) == [displayID, micID])
        for verdict in verdicts {
            let reason = try #require(verdict.reason, "\(verdict.trackID)")
            #expect(reason.contains("seg-0002.mov is empty"), "\(reason)")
            #expect(reason.contains("seg-0003.mov (4096 bytes) cannot be read"), "\(reason)")
            #expect(reason.contains("seg-0004.mov is missing"), "\(reason)")
            #expect(!reason.contains("seg-0001.mov"), "\(reason)")
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func readersClassifyClosedSegments() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await addTracksWithBrokenSegments(to: builder, endReasons: [.stopped, .unreadable(bytes: 4096), .stopped])
        let project = try builder.write()

        // From the manifest and the file system alone: before a single frame is drawn.
        let renderer = try FrameRenderer(project: project, outputSize: settings.outputSize)
        #expect(renderer.missingVideo.map(\.reason) == [.empty, .unreadable, .fileMissing])

        let summary = try await MP4Exporter(project: project, settings: settings).export(to: dir.appending(path: "out.mp4")) { _ in }
        #expect(summary.missingAudio.map(\.reason) == [.empty, .unreadable, .fileMissing])
        #expect(summary.missingVideo.map(\.reason) == [.empty, .unreadable, .fileMissing])
    }
}
