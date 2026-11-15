// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation
import ProjectFormat
import Recording
import SyntheticCapture

/// A video segment `TakeBuilder` writes: `seconds` of `SampleFactory` video from `start`, one frame every
/// `1 / framesPerSecond` s, the file finished at `start + seconds` unless `leaveOpen`.
public struct VideoSegmentSpec: Sendable {
    public var start: HostTime
    public var seconds: Double
    public var framesPerSecond: Int = 30
    public var width: Int = 640
    public var height: Int = 360
    /// `nil` leaves the segment open in the manifest, as a crash does.
    public var endReason: SegmentEndReason? = .stopped
    /// The file is never finished: its writer stays in `TakeBuilder.openWriters`, as a crash leaves it.
    public var leaveOpen: Bool = false
    /// Replaces each frame before it is written, given its number in the track (the one `SampleFactory`
    /// paints, counting the frames of the track's earlier segments).
    public var transform: (@Sendable (_ frameIndex: Int, CMSampleBuffer) -> CMSampleBuffer)? = nil

    public init(
        start: HostTime, seconds: Double, framesPerSecond: Int = 30, width: Int = 640, height: Int = 360,
        endReason: SegmentEndReason? = .stopped, leaveOpen: Bool = false,
        transform: (@Sendable (_ frameIndex: Int, CMSampleBuffer) -> CMSampleBuffer)? = nil
    ) {
        self.start = start
        self.seconds = seconds
        self.framesPerSecond = framesPerSecond
        self.width = width
        self.height = height
        self.endReason = endReason
        self.leaveOpen = leaveOpen
        self.transform = transform
    }
}

/// An audio segment `TakeBuilder` writes: `seconds` of the `SampleFactory` sine from `start` in 10 ms blocks
/// (`sampleRate / 100` frames, 480 at 48 kHz, as `SyntheticAudioSource` delivers them). Block *k* is presented
/// at `start + k · frames / sampleRate × (1 + clockSkewPPM / 1e6)`, the rule of
/// `SyntheticAudioSource(clockSkewPPM:)`, and the file is finished where the next block would start.
public struct AudioSegmentSpec: Sendable {
    public var start: HostTime
    public var seconds: Double
    public var sampleRate: Double = 48_000
    public var channels: Int = 1
    public var clockSkewPPM: Double = 0
    /// Logs the `audioClock` anchors the pipeline would; without them the export assumes the nominal rate.
    public var logsAudioClock: Bool = true
    /// `nil` leaves the segment open in the manifest, as a crash does.
    public var endReason: SegmentEndReason? = .stopped
    /// The file is never finished: its writer stays in `TakeBuilder.openWriters`, as a crash leaves it.
    public var leaveOpen: Bool = false
    /// Replaces each block before it is written, given its number in the segment.
    public var transform: (@Sendable (_ blockIndex: Int, CMSampleBuffer) -> CMSampleBuffer)? = nil

    public init(
        start: HostTime, seconds: Double, sampleRate: Double = 48_000, channels: Int = 1, clockSkewPPM: Double = 0,
        logsAudioClock: Bool = true, endReason: SegmentEndReason? = .stopped, leaveOpen: Bool = false,
        transform: (@Sendable (_ blockIndex: Int, CMSampleBuffer) -> CMSampleBuffer)? = nil
    ) {
        self.start = start
        self.seconds = seconds
        self.sampleRate = sampleRate
        self.channels = channels
        self.clockSkewPPM = clockSkewPPM
        self.logsAudioClock = logsAudioClock
        self.endReason = endReason
        self.leaveOpen = leaveOpen
        self.transform = transform
    }
}

/// What `TakeBuilder.addEmptySegment` leaves at a segment's path.
public enum SegmentFileFixture: Sendable {
    /// A file of 0 bytes, as a writer leaves one that never got a sample written.
    case zeroBytes
    /// `bytes` bytes that are not a movie.
    case garbage(bytes: Int = 4096)
    /// No file at all.
    case absent
}

/// Writes one take, `take-001`, into a new package the way the recorder does: segments with
/// `FragmentedTrackWriter` (not in real time) and `SampleFactory` media, the manifest, and `events.jsonl` with
/// the events the pipeline logs (`segmentStarted` at the start of every segment, `audioClock` anchors) plus
/// any added with `addEvents`.
///
/// What the builder does not produce (a segment the manifest does not list, a file without its
/// `segmentStarted`, a lock or a reserve) a test writes by hand on `package`.
public final class TakeBuilder {
    public let package: ProjectPackage
    /// The writers of the segments written with `leaveOpen`, alive as long as the builder is.
    public private(set) var openWriters: [any TrackWriting] = []

    private let takeID = "take-001"
    private var tracks: [TrackRecord] = []
    private var events: [InputEvent] = []
    /// Frames written to each video track so far: the number of its next frame.
    private var framesWritten: [String: Int] = [:]
    private var written = false

    /// Creates `<directory>/<name>.toma` with an empty manifest of `formatVersion`: with an older one, the package
    /// an earlier version of the app would have created, which keeps that version.
    public init(in directory: URL, name: String = "Fixture", formatVersion: Int = Manifest.currentFormatVersion) throws {
        package = try ProjectPackage.create(in: directory, name: name, app: AppInfo(name: "Tests", version: "0"), now: Date())
        if formatVersion != Manifest.currentFormatVersion {
            // Written here: `ManifestStore` keeps the version a package was created with.
            var manifest = try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
            manifest.formatVersion = formatVersion
            try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(manifest), to: package.manifestURL)
        }
    }

    /// Adds a video track of `segments`, numbered from 1. Called again for the same track (same kind and
    /// source), it adds its segments after the track's last one.
    public nonisolated(nonsending) func addVideoTrack(
        id: String, kind: TrackKind = .display, source: TrackSource, segments: [VideoSegmentSpec]
    ) async throws {
        try addTrack(id: id, kind: kind, source: source)
        for spec in segments {
            let (index, url) = try nextSegment(of: id, start: spec.start)
            let writer = try FragmentedTrackWriter(url: url, media: .video(framesPerSecond: spec.framesPerSecond), realTime: false)
            let first = framesWritten[id, default: 0]
            let count = Int((spec.seconds * Double(spec.framesPerSecond)).rounded())
            for i in 0..<count {
                let pts = spec.start.adding(seconds: Double(i) / Double(spec.framesPerSecond))
                let sample = SampleFactory.videoSample(width: spec.width, height: spec.height, pts: pts, frameIndex: first + i)
                try writer.append(spec.transform?(first + i, sample) ?? sample)
            }
            framesWritten[id] = first + count
            let end = try await close(writer, at: spec.start.adding(seconds: spec.seconds), leaveOpen: spec.leaveOpen, url: url)
            try record(index: index, of: id, url: url, start: spec.start, end: end, endReason: spec.endReason)
        }
    }

    /// Adds an audio track of `segments`, numbered from 1. Called again for the same track (same kind and
    /// source), it adds its segments after the track's last one.
    public nonisolated(nonsending) func addAudioTrack(
        id: String, kind: TrackKind = .microphone, source: TrackSource, segments: [AudioSegmentSpec]
    ) async throws {
        try addTrack(id: id, kind: kind, source: source)
        for spec in segments {
            let (index, url) = try nextSegment(of: id, start: spec.start)
            let writer = try FragmentedTrackWriter(url: url, media: .audio, realTime: false)
            let frames = Int(spec.sampleRate / 100)
            let rate = 1 + spec.clockSkewPPM / 1_000_000
            func pts(ofBlock k: Int) -> HostTime {
                spec.start.adding(seconds: Double(k * frames) / spec.sampleRate * rate)
            }
            let blocks = Int((spec.seconds * spec.sampleRate / Double(frames)).rounded())
            // The pipeline's rule: after each block, the anchor for the block the writer wrote last.
            var anchors = AudioClockAnchors(segmentStart: spec.start)
            for k in 0..<blocks {
                let sample = SampleFactory.audioSample(
                    pts: pts(ofBlock: k), frames: frames, sampleRate: spec.sampleRate, channels: spec.channels)
                try writer.append(spec.transform?(k, sample) ?? sample)
                guard spec.logsAudioClock, let written = writer.lastWrittenAudio,
                      let anchor = anchors.anchor(for: written)
                else { continue }
                events.append(InputEvent(t: anchor.hostTime, kind: .audioClock(track: id, frame: anchor.frame)))
            }
            let end = try await close(writer, at: pts(ofBlock: blocks), leaveOpen: spec.leaveOpen, url: url)
            try record(index: index, of: id, url: url, start: spec.start, end: end, endReason: spec.endReason)
        }
    }

    /// Adds segment `index` of `track` (added before) without media: what is at its path is `file`, and it
    /// is closed with `endReason` at `end` (at `start` when `end` is `nil`), or open when `endReason` is `nil`.
    public func addEmptySegment(
        track: String, index: Int, start: HostTime, end: HostTime? = nil, endReason: SegmentEndReason?,
        file: SegmentFileFixture
    ) throws {
        try checkNotWritten()
        guard let existing = tracks.first(where: { $0.id == track }) else { throw TestSupportError.missing("track \(track)") }
        guard !existing.segments.contains(where: { $0.index == index }) else {
            throw TestSupportError.failed("segment \(index) of \(track) is already in the take")
        }
        guard endReason != nil || end == nil else { throw TestSupportError.failed("an open segment has no end") }
        let url = package.segmentURL(take: takeID, track: track, index: index)
        switch file {
        case .zeroBytes:
            try Data().write(to: url, options: .withoutOverwriting)
        case .garbage(let bytes):
            try Data(repeating: 0x5A, count: bytes).write(to: url, options: .withoutOverwriting)
        case .absent:
            break
        }
        events.append(InputEvent(t: start, kind: .segmentStarted(track: track, index: index)))
        try record(index: index, of: track, url: url, start: start, end: end ?? start, endReason: endReason)
    }

    /// Adds `events` to `events.jsonl`.
    public func addEvents(_ events: [InputEvent]) throws {
        try checkNotWritten()
        self.events += events
    }

    /// Writes the take with `status` to the manifest and its events to `events.jsonl`, in time order (events
    /// at the same time in the order they were added), as the pipeline logs them; returns the take as
    /// `LoadedProject.load` reads it. Call it once, after adding everything.
    public func write(status: TakeStatus = .complete) throws -> LoadedProject {
        try checkNotWritten()
        written = true
        try FileManager.default.createDirectory(at: package.takeDirectory(takeID), withIntermediateDirectories: true)
        var tracks = tracks
        for i in tracks.indices { tracks[i].segments.sort { $0.index < $1.index } }
        let take = TakeRecord(id: takeID, status: status, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: tracks)
        try ManifestStore(package: package).update { $0.takes.append(take) }
        let log = try EventLogWriter(url: package.eventsURL(take: takeID))
        let ordered = events.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }
        for (_, event) in ordered { log.append(event) }
        try log.close()
        return try LoadedProject.load(package.url, take: takeID)
    }

    // MARK: - Private

    private func checkNotWritten() throws {
        guard !written else { throw TestSupportError.failed("the take is already written") }
    }

    /// Adds track `id` and creates its folder, unless it is there with this kind and source.
    private func addTrack(id: String, kind: TrackKind, source: TrackSource) throws {
        try checkNotWritten()
        if let existing = tracks.first(where: { $0.id == id }) {
            guard existing.kind == kind, existing.source == source else {
                throw TestSupportError.failed("track \(id) is already in the take with another kind or source")
            }
            return
        }
        try FileManager.default.createDirectory(at: package.trackDirectory(take: takeID, track: id), withIntermediateDirectories: true)
        tracks.append(TrackRecord(id: id, kind: kind, source: source, segments: []))
    }

    /// The index and file of the segment after the last one of `track`, logging its `segmentStarted`.
    private func nextSegment(of track: String, start: HostTime) throws -> (Int, URL) {
        let index = (tracks.first { $0.id == track }?.segments.map(\.index).max() ?? 0) + 1
        events.append(InputEvent(t: start, kind: .segmentStarted(track: track, index: index)))
        return (index, package.segmentURL(take: takeID, track: track, index: index))
    }

    /// Finishes `writer` at `stopTime` and returns where its segment ends; with `leaveOpen`, keeps it open
    /// in `openWriters` and returns `stopTime`.
    private nonisolated(nonsending) func close(
        _ writer: FragmentedTrackWriter, at stopTime: HostTime, leaveOpen: Bool, url: URL
    ) async throws -> HostTime {
        if leaveOpen {
            if let failure = writer.failure { throw TestSupportError.failed("writing \(url.lastPathComponent): \(failure)") }
            openWriters.append(writer)
            return stopTime
        }
        let result = try await writer.finish(at: stopTime)
        if let failure = writer.failure { throw TestSupportError.failed("finishing \(url.lastPathComponent): \(failure)") }
        return result.endHostTime
    }

    /// Adds the manifest record of segment `index` of `track`, closed at `end` unless `endReason` is `nil`.
    private func record(index: Int, of track: String, url: URL, start: HostTime, end: HostTime, endReason: SegmentEndReason?) throws {
        let segment = SegmentRecord(
            index: index, file: try package.relativePath(of: url), startHostTime: start,
            endHostTime: endReason == nil ? nil : end, endReason: endReason, droppedFrames: 0, heartbeatFrames: 0)
        guard let i = tracks.firstIndex(where: { $0.id == track }) else { throw TestSupportError.missing("track \(track)") }
        tracks[i].segments.append(segment)
    }
}
