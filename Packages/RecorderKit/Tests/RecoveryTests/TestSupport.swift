// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import ProjectFormat
import Testing

/// An arbitrary host time well after boot.
let base = HostTime(nanoseconds: 5_000_000_000_000)

/// `<directory>/<name>.toma` with an empty manifest.
func makePackage(in directory: URL, name: String = "Test") throws -> ProjectPackage {
    try ProjectPackage.create(in: directory, name: name, app: AppInfo(name: "Tests", version: "0"), now: Date())
}

/// Adds `take` to the manifest and creates its folder and one folder per track, like the recorder: in a package that
/// has a take already, after raising it to version 5 (`Manifest.needsFormatVersion5`).
func addTake(_ take: TakeRecord, to package: ProjectPackage) throws {
    try FileManager.default.createDirectory(at: package.takeDirectory(take.id), withIntermediateDirectories: false)
    for track in take.tracks {
        try FileManager.default.createDirectory(
            at: package.trackDirectory(take: take.id, track: track.id), withIntermediateDirectories: false)
    }
    let store = try ManifestStore(package: package)
    if !store.manifest.takes.isEmpty { try store.raiseFormatVersion(to: 5) }
    try store.update { $0.takes.append(take) }
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
let cameraSource = TrackSource(name: "Synthetic Camera", deviceUniqueID: "synthetic-camera")
let systemAudioSource = TrackSource(name: "Synthetic System Audio", excludedBundleIDs: ["dev.toma.Toma"])

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

/// The movie's duration as AVFoundation reads it now, or 0 if it cannot open it.
func readableDuration(of url: URL) async -> Double {
    (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
}

func fileSize(_ url: URL) throws -> Int64 {
    try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
}

/// `withExtendedLifetime` for an async `body`, which the standard library does not have: `value` is
/// not released before `body` returns. Keeps a `TakeBuilder`'s unfinished writers alive while a test reads
/// their files.
func withExtendedLifetime<T, Result>(_ value: T, _ body: () async throws -> Result) async rethrows -> Result {
    defer { Swift.withExtendedLifetime(value) {} }
    return try await body()
}
