// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import ProjectFormat
import Recording
import Recovery
import Render
import SyntheticCapture
import Testing

@testable import Export

// Video the export cannot decode is never left out silently: the summary lists it.

private let settings = ExportSettings(outputSize: [640, 360], framesPerSecond: 30)

/// Adds display segments to the synthetic package's take, after the one it has.
private func appendDisplaySegments(_ package: ProjectPackage, _ segments: [SegmentRecord]) throws {
    try ManifestStore(package: package).update { manifest in
        let display = try #require(manifest.takes[0].tracks.firstIndex { $0.id == displayID })
        manifest.takes[0].tracks[display].segments += segments
    }
}

private func displaySegment(_ package: ProjectPackage, index: Int, from start: Double, to end: Double, reason: SegmentEndReason) throws -> SegmentRecord {
    SegmentRecord(
        index: index, file: try package.relativePath(of: package.segmentURL(take: takeID, track: displayID, index: index)),
        startHostTime: base.adding(seconds: start), endHostTime: base.adding(seconds: end), endReason: reason,
        droppedFrames: 0, heartbeatFrames: 0)
}

@Test(.enabled(if: metalAvailable))
func unreadableAndMissingScreenSegmentsAreListed() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await makeSyntheticPackage(in: dir, seconds: 1, mic: [MicSegment(start: 0, seconds: 3)])
        try appendDisplaySegments(package, [
            try displaySegment(package, index: 2, from: 1, to: 2, reason: .unreadable(bytes: 4096)),
            try displaySegment(package, index: 3, from: 2, to: 3, reason: .recoveredAfterCrash),  // its file is gone
        ])
        let summary = try await MP4Exporter(project: try LoadedProject.load(package.url), settings: settings)
            .export(to: dir.appending(path: "out.mp4")) { _ in }
        #expect(summary.missingAudio.isEmpty)
        #expect(summary.missingVideo == [
            MissingVideo(file: "takes/take-001/display-1/seg-0002.mov", start: 1, end: 2, reason: .unreadable),
            MissingVideo(file: "takes/take-001/display-1/seg-0003.mov", start: 2, end: 3, reason: .fileMissing),
        ])
    }
}

@Test(.enabled(if: metalAvailable))
func screenSegmentThatCannotBeOpenedIsListed() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await makeSyntheticPackage(in: dir, seconds: 1, mic: [MicSegment(start: 0, seconds: 2)])
        try Data(repeating: 0x5A, count: 4096).write(to: package.segmentURL(take: takeID, track: displayID, index: 2))
        try appendDisplaySegments(package, [try displaySegment(package, index: 2, from: 1, to: 2, reason: .stopped)])
        let summary = try await MP4Exporter(project: try LoadedProject.load(package.url), settings: settings)
            .export(to: dir.appending(path: "out.mp4")) { _ in }
        try #require(summary.missingVideo.count == 1, "\(summary.missingVideo)")
        let missing = summary.missingVideo[0]
        #expect(missing.file == "takes/take-001/display-1/seg-0002.mov" && missing.start == 1 && missing.end == 2)
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
/// synthetic media and were never finalized, as a crash leaves them. `body` runs while their writers are
/// still alive (a dead writer would finish its file).
private func withCrashedPackage<T>(
    in dir: URL, seconds: Int, _ body: (ProjectPackage) async throws -> T
) async throws -> T {
    let package = try ProjectPackage.create(in: dir, name: "Crashed", app: AppInfo(name: "Tests", version: "0"), now: Date())
    let videoURL = package.segmentURL(take: takeID, track: displayID, index: 1)
    let audioURL = package.segmentURL(take: takeID, track: micID, index: 1)
    for url in [videoURL, audioURL] {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    let video = try FragmentedTrackWriter(url: videoURL, media: .video(framesPerSecond: 30), realTime: false)
    for i in 0..<(seconds * 30) {
        try video.append(SampleFactory.videoSample(width: 640, height: 360, pts: base.adding(seconds: Double(i) / 30), frameIndex: i))
    }
    let audio = try FragmentedTrackWriter(url: audioURL, media: .audio, realTime: false)
    for k in 0..<(seconds * 100) {
        try audio.append(SampleFactory.audioSample(pts: base.adding(seconds: Double(k) / 100), frames: 480, sampleRate: 48_000, channels: 1))
    }
    let take = TakeRecord(id: takeID, status: .recording, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: [
        TrackRecord(
            id: displayID, kind: .display,
            source: TrackSource(name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 640, height: 360), pixelScale: 1),
            segments: [SegmentRecord(index: 1, file: try package.relativePath(of: videoURL), startHostTime: base, droppedFrames: 0, heartbeatFrames: 0)]),
        TrackRecord(
            id: micID, kind: .microphone, source: TrackSource(name: "Mic", deviceUniqueID: "mic"),
            segments: [SegmentRecord(index: 1, file: try package.relativePath(of: audioURL), startHostTime: base, droppedFrames: 0, heartbeatFrames: 0)]),
    ])
    try ManifestStore(package: package).update { $0.takes.append(take) }
    return try await withExtendedLifetime((video, audio)) { try await body(package) }
}

/// A take a crash left open, its segments never finalized: recovery closes it, and the export decodes its
/// screen and its microphone up to the last second recovered.
@Test(.enabled(if: metalAvailable))
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
@Test(.enabled(if: metalAvailable))
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
