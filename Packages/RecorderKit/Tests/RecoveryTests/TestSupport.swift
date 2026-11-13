// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import ProjectFormat
import Recording
import SyntheticCapture
import Testing

/// An arbitrary host time well after boot.
let base = HostTime(nanoseconds: 5_000_000_000_000)

/// A fresh, empty directory that is removed when `body` returns.
func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}

/// `<directory>/<name>.toma` with an empty manifest.
func makePackage(in directory: URL, name: String = "Test") throws -> ProjectPackage {
    try ProjectPackage.create(in: directory, name: name, app: AppInfo(name: "Tests", version: "0"), now: Date())
}

/// Adds `take` to the manifest and creates its folder and one folder per track, like the recorder.
func addTake(_ take: TakeRecord, to package: ProjectPackage) throws {
    try FileManager.default.createDirectory(at: package.takeDirectory(take.id), withIntermediateDirectories: false)
    for track in take.tracks {
        try FileManager.default.createDirectory(
            at: package.trackDirectory(take: take.id, track: track.id), withIntermediateDirectories: false)
    }
    try ManifestStore(package: package).update { $0.takes.append(take) }
}

func manifestOnDisk(_ package: ProjectPackage) throws -> Manifest {
    try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
}

func takeOnDisk(_ package: ProjectPackage, _ id: String) throws -> TakeRecord {
    try #require(try manifestOnDisk(package).takes.first { $0.id == id })
}

let displaySource = TrackSource(
    name: "Synthetic Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 640, height: 360), pixelScale: 1)
let micSource = TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic")

func displayTrack(_ segments: [SegmentRecord]) -> TrackRecord {
    TrackRecord(id: "display-1", kind: .display, source: displaySource, segments: segments)
}

func micTrack(_ segments: [SegmentRecord]) -> TrackRecord {
    TrackRecord(id: "mic", kind: .microphone, source: micSource, segments: segments)
}

func makeTake(_ id: String = "take-001", status: TakeStatus = .recording, tracks: [TrackRecord]) -> TakeRecord {
    TakeRecord(id: id, status: status, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: tracks)
}

/// The manifest record of segment `index` of `track` in `take`, open unless `end` is given.
func segmentRecord(
    _ package: ProjectPackage, take: String = "take-001", track: String, index: Int = 1, start: HostTime,
    end: HostTime? = nil, reason: SegmentEndReason? = nil, dropped: Int = 0
) throws -> SegmentRecord {
    SegmentRecord(
        index: index,
        file: try package.relativePath(of: package.segmentURL(take: take, track: track, index: index)),
        startHostTime: start, endHostTime: end, endReason: reason, droppedFrames: dropped, heartbeatFrames: 0)
}

/// Writes `seconds` of 30 fps synthetic video starting at `start`. When `finish` is false the writer is
/// left open, the way a crash leaves it: the caller keeps it alive while it reads the file.
func writeVideo(
    to url: URL, start: HostTime, seconds: Double, finish: Bool
) async throws -> FragmentedTrackWriter {
    let writer = try FragmentedTrackWriter(url: url, media: .video(framesPerSecond: 30), realTime: false)
    for i in 0..<Int(seconds * 30) {
        try writer.append(SampleFactory.videoSample(
            width: 640, height: 360, pts: start.adding(seconds: Double(i) / 30), frameIndex: i))
    }
    if finish { _ = try await writer.finish(at: start.adding(seconds: seconds)) }
    return writer
}

/// Writes `seconds` of 48 kHz mono audio in 10 ms blocks starting at `start`, like `writeVideo`.
func writeAudio(
    to url: URL, start: HostTime, seconds: Double, finish: Bool
) async throws -> FragmentedTrackWriter {
    let writer = try FragmentedTrackWriter(url: url, media: .audio, realTime: false)
    for k in 0..<Int(seconds * 100) {
        try writer.append(SampleFactory.audioSample(
            pts: start.adding(seconds: Double(k) / 100), frames: 480, sampleRate: 48_000, channels: 1))
    }
    if finish { _ = try await writer.finish(at: start.adding(seconds: seconds)) }
    return writer
}

/// The readable duration of the movie at `url`, polled until it reaches `target` or `timeout` passes.
/// A movie that AVFoundation cannot open yet reads as 0.
func readableDuration(of url: URL, reaching target: Double, timeout: Duration = .seconds(5)) async -> Double {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var seconds = 0.0
    while true {
        seconds = await readableDuration(of: url)
        if seconds >= target || clock.now >= deadline { return seconds }
        try? await Task.sleep(for: .milliseconds(50))
    }
}

/// The movie's duration as AVFoundation reads it now, or 0 if it cannot open it.
func readableDuration(of url: URL) async -> Double {
    (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
}

func fileSize(_ url: URL) throws -> Int64 {
    try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
}

/// `withExtendedLifetime` for an async `body`, which the standard library does not have: `value` is
/// not released before `body` returns. Keeps an unfinished writer alive while a test reads its file.
func withExtendedLifetime<T, Result>(_ value: T, _ body: () async throws -> Result) async rethrows -> Result {
    defer { Swift.withExtendedLifetime(value) {} }
    return try await body()
}
