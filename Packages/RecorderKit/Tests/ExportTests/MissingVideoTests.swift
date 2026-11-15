// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Recording
import Recovery
import Render
import SyntheticCapture
import Testing

@testable import Export

// Video the export cannot decode is never left out silently: the summary lists it.

private let settings = ExportSettings(outputSize: [640, 360], framesPerSecond: 30)

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func unreadableAndMissingScreenSegmentsAreListed() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 1)])
        try builder.addEmptySegment(
            track: displayID, index: 2, start: base.adding(seconds: 1), end: base.adding(seconds: 2), endReason: .unreadable(bytes: 4096),
            file: .absent)
        try builder.addEmptySegment(  // its file is gone
            track: displayID, index: 3, start: base.adding(seconds: 2), end: base.adding(seconds: 3), endReason: .recoveredAfterCrash,
            file: .absent)
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 3)])
        let package = try builder.write().package
        let summary = try await MP4Exporter(project: try LoadedProject.load(package.url), settings: settings)
            .export(to: dir.appending(path: "out.mp4")) { _ in }
        #expect(summary.missingAudio.isEmpty)
        #expect(summary.missingVideo == [
            MissingVideo(track: displayID, file: "takes/take-001/display-1/seg-0002.mov", start: 1, end: 2, reason: .unreadable),
            MissingVideo(track: displayID, file: "takes/take-001/display-1/seg-0003.mov", start: 2, end: 3, reason: .fileMissing),
        ])
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func cameraVideoThatCannotBeReadIsListedWithItsTrack() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 2)])
        let camera = TrackSource(name: "Synthetic Camera", deviceUniqueID: "synthetic-camera")
        try await builder.addVideoTrack(id: "camera", kind: .camera, source: camera, segments: [VideoSegmentSpec(start: base, seconds: 1)])
        try builder.addEmptySegment(
            track: "camera", index: 2, start: base.adding(seconds: 1), end: base.adding(seconds: 2), endReason: .stopped,
            file: .garbage(bytes: 4096))
        let package = try builder.write().package
        let summary = try await MP4Exporter(project: try LoadedProject.load(package.url), settings: settings)
            .export(to: dir.appending(path: "out.mp4")) { _ in }
        try #require(summary.missingVideo.count == 1, "\(summary.missingVideo)")
        let missing = summary.missingVideo[0]
        #expect(missing.track == "camera" && missing.file == "takes/take-001/camera/seg-0002.mov")
        #expect(missing.start == 1 && missing.end == 2)
        guard case .cannotOpen = missing.reason else {
            Issue.record("expected cannotOpen, got \(missing.reason)")
            return
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func screenSegmentThatCannotBeOpenedIsListed() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 1)])
        try builder.addEmptySegment(
            track: displayID, index: 2, start: base.adding(seconds: 1), end: base.adding(seconds: 2), endReason: .stopped,
            file: .garbage(bytes: 4096))
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 2)])
        let package = try builder.write().package
        let summary = try await MP4Exporter(project: try LoadedProject.load(package.url), settings: settings)
            .export(to: dir.appending(path: "out.mp4")) { _ in }
        try #require(summary.missingVideo.count == 1, "\(summary.missingVideo)")
        let missing = summary.missingVideo[0]
        #expect(missing.track == displayID && missing.file == "takes/take-001/display-1/seg-0002.mov")
        #expect(missing.start == 1 && missing.end == 2)
        guard case .cannotOpen = missing.reason else {
            Issue.record("expected cannotOpen, got \(missing.reason)")
            return
        }
    }
}

/// The palette index of the screen in the exported frame nearest `time`.
private func screenIndex(of url: URL, take: TakeRecord, at time: Double) async throws -> Int {
    let rect = try #require(FrameEvaluator(take: take, events: [], style: StyleV0(), outputSize: settings.outputSize).frame(at: 0).screen?.rect)
    let frame = try await videoFrame(of: url, nearest: time)
    return SampleFactory.frameIndex(nearestTo: pixel(
        frame.bytes, width: frame.width, x: Int(rect.x + rect.width / 2), y: Int(rect.y + rect.height * 0.75)))
}

/// `<dir>/Crashed.toma` with a `recording` take whose screen and microphone segments hold `seconds` of
/// synthetic media and were never finalized, as a crash leaves them, and no `events.jsonl`. `body` runs while their writers are
/// still alive (a dead writer would finish its file).
private func withCrashedPackage<T>(
    in dir: URL, seconds: Int, _ body: (ProjectPackage) async throws -> T
) async throws -> T {
    let builder = try TakeBuilder(in: dir, name: "Crashed")
    try await builder.addVideoTrack(
        id: displayID,
        source: TrackSource(name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 640, height: 360), pixelScale: 1),
        segments: [VideoSegmentSpec(start: base, seconds: Double(seconds), endReason: nil, leaveOpen: true)])
    try await builder.addAudioTrack(
        id: micID, source: TrackSource(name: "Mic", deviceUniqueID: "mic"),
        segments: [AudioSegmentSpec(start: base, seconds: Double(seconds), endReason: nil, leaveOpen: true)])
    let package = try builder.write(status: .recording).package
    try FileManager.default.removeItem(at: package.eventsURL(take: takeID))  // a take without events.jsonl
    return try await withExtendedLifetime(builder) { try await body(package) }
}

/// A take a crash left open, its segments never finalized: recovery closes it, and the export decodes its
/// screen and its microphone up to the last second recovered.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func recoveredUnfinalizedSegmentsExportToTheirEnd() async throws {
    try await withTemporaryDirectory { dir in
        try await withCrashedPackage(in: dir, seconds: 5) { package in
            let recovered = try await TakeRecovery.recover(package: package, takeID: takeID)
            let screenEnd = try #require(recovered.track(displayID)?.segments.first?.endHostTime).seconds(since: base)
            #expect(screenEnd >= 3, "recovered \(screenEnd) s of screen")

            let destination = dir.appending(path: "out.mp4")
            let summary = try await MP4Exporter(project: try LoadedProject.load(package.url), settings: settings)
                .export(to: destination) { _ in }
            #expect(summary.missingVideo.isEmpty && summary.missingAudio.isEmpty)
            let last = screenEnd - 0.5
            #expect(try await screenIndex(of: destination, take: recovered, at: last) == Int(last * 30) % 64)
            let (start, samples) = try await decodedAudio(of: destination)
            #expect(rms(samples, start: start, from: last - 0.4, to: last + 0.4) > 0.1)
        }
    }
}

/// `withExtendedLifetime` for an async `body`: `value` is not released before `body` returns.
private func withExtendedLifetime<T, Result>(_ value: T, _ body: () async throws -> Result) async rethrows -> Result {
    defer { Swift.withExtendedLifetime(value) {} }
    return try await body()
}

/// Overwrites the payload of the `n`th `mdat` box (0-based) of a fragmented movie with garbage.
private func corruptMediaData(of url: URL, box n: Int) throws {
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    var offset: UInt64 = 0
    var found = 0
    while offset + 8 <= size {
        try handle.seek(toOffset: offset)
        let header = try #require(try handle.read(upToCount: 16))
        var length = UInt64(header[0]) << 24 | UInt64(header[1]) << 16 | UInt64(header[2]) << 8 | UInt64(header[3])
        var headerLength: UInt64 = 8
        if length == 1 {
            length = header[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
            headerLength = 16
        }
        try #require(length >= headerLength)
        if String(decoding: header[4..<8], as: UTF8.self) == "mdat" {
            if found == n {
                try handle.seek(toOffset: offset + headerLength)
                handle.write(Data(repeating: 0x5A, count: Int(length - headerLength)))
                return
            }
            found += 1
        }
        offset += length
    }
    Issue.record("no mdat box \(n) in \(url.lastPathComponent)")
}

/// A fragment in the middle of a recovered screen segment holds garbage: the export goes on past it,
/// decoding the frames after it, or lists what it could not decode. It is never silent.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func corruptFragmentIsSkippedOrListed() async throws {
    try await withTemporaryDirectory { dir in
        try await withCrashedPackage(in: dir, seconds: 6) { package in
            try corruptMediaData(of: package.segmentURL(take: takeID, track: displayID, index: 1), box: 2)
            let recovered = try await TakeRecovery.recover(package: package, takeID: takeID)
            let screenEnd = try #require(recovered.track(displayID)?.segments.first?.endHostTime).seconds(since: base)
            let project = try LoadedProject.load(package.url)
            let destination = dir.appending(path: "out.mp4")
            let summary = try await MP4Exporter(project: project, settings: settings).export(to: destination) { _ in }

            let last = screenEnd - 0.5
            let decodedAfter = try await screenIndex(of: destination, take: project.take, at: last) == Int(last * 30) % 64
            let listed = summary.missingVideo.contains { missing in
                if case .readFailed = missing.reason { missing.file == "takes/take-001/display-1/seg-0001.mov" } else { false }
            }
            #expect(decodedAfter || listed, "neither decoded after the bad fragment nor listed: \(summary.missingVideo)")
            #expect(summary.missingVideo.allSatisfy { $0.start >= 0 && $0.end <= screenEnd + 1e-6 && $0.start <= $0.end })
            // One span per failure, however many attempts it took to get past it.
            #expect(summary.missingVideo.count <= 1, "\(summary.missingVideo)")
        }
    }
}
