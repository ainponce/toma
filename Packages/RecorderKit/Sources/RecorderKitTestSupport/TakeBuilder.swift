// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation
import ImageIO
import ProjectFormat
import Recording
import SyntheticCapture
import VideoToolbox

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

/// An audio segment `TakeBuilder` writes: `seconds` of the `SampleFactory` sine (`frequency` Hz at `amplitude`, 440 Hz
/// at 1/4 of full scale by default) from `start` in 10 ms blocks (`sampleRate / 100` frames, 480 at 48 kHz, as
/// `SyntheticAudioSource` delivers them). Block *k* is presented at
/// `start + k · frames / sampleRate × (1 + clockSkewPPM / 1e6)`, the rule of `SyntheticAudioSource(clockSkewPPM:)`,
/// and the file is finished where the next block would start.
public struct AudioSegmentSpec: Sendable {
    public var start: HostTime
    public var seconds: Double
    public var sampleRate: Double = 48_000
    public var channels: Int = 1
    public var frequency: Double = 440
    public var amplitude: Float = 0.25
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
        start: HostTime, seconds: Double, sampleRate: Double = 48_000, channels: Int = 1, frequency: Double = 440,
        amplitude: Float = 0.25, clockSkewPPM: Double = 0, logsAudioClock: Bool = true,
        endReason: SegmentEndReason? = .stopped, leaveOpen: Bool = false,
        transform: (@Sendable (_ blockIndex: Int, CMSampleBuffer) -> CMSampleBuffer)? = nil
    ) {
        self.start = start
        self.seconds = seconds
        self.sampleRate = sampleRate
        self.channels = channels
        self.frequency = frequency
        self.amplitude = amplitude
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
/// any added with `addEvents`. `init(appendingTo:take:)` writes another take into a package that has some.
///
/// What the builder does not produce (a segment the manifest does not list, a file without its
/// `segmentStarted`, a lock or a reserve) a test writes by hand on `package`.
public final class TakeBuilder {
    public let package: ProjectPackage
    /// The writers of the segments written with `leaveOpen`, alive as long as the builder is.
    public private(set) var openWriters: [any TrackWriting] = []
    /// The take's `cameraStyle`, written with it: how the camera looks from the start. `nil`, as in a take without a
    /// camera or of version 1.
    public var cameraStyle: CameraStyle?
    /// The HEVC encoder the video segments are written with, `defaultVideoEncoder` unless a test sets another.
    ///
    /// With `.hardwareOnly`, a segment whose writer fails in the encoder, as it does when the media engine takes no
    /// more sessions (other processes hold them), is written again from its first frame every
    /// `hardwareEncoderRetryInterval` seconds until it is written, and the builder throws once `hardwareEncoderTimeout`
    /// seconds passed since its first such failure (one wait for the whole take, however many segments it has): it is
    /// never written by another encoder, whose bitstream decodes to other pixels. While other checkouts run their tests,
    /// the media engine has been seen to take no session for 90 s. Any other error is thrown at once.
    public var videoEncoder: VideoEncoderChoice = TakeBuilder.defaultVideoEncoder
    public var hardwareEncoderTimeout = 300.0
    public var hardwareEncoderRetryInterval = 0.5
    /// When this builder stops writing again with `.hardwareOnly`: `hardwareEncoderTimeout` after its first encoder
    /// failure, `nil` before one.
    public private(set) var hardwareEncoderDeadline: ContinuousClock.Instant?
    /// Makes the writer of a video segment for `url`, at `framesPerSecond`, with `encoder`: a `FragmentedTrackWriter`
    /// outside real time. Tests replace it, for one to make the hardware encoder look busy: a factory that throws
    /// `WriterError.appendFailed` stands for a media engine that gives no session, which `.hardwareOnly` waits out.
    public var makeVideoWriter: VideoWriterFactory = { url, framesPerSecond, encoder in
        try FragmentedTrackWriter(url: url, media: .video(framesPerSecond: framesPerSecond), realTime: false, videoEncoder: encoder)
    }

    /// The encoder of every builder's video unless a test sets another: `.hardwareOnly` on a Mac with a hardware HEVC
    /// encoder, `.any` in CI (`TOMA_CI=1`) or without one.
    ///
    /// The tests' fixtures are written outside real time, and with `.any` VideoToolbox writes them with its software
    /// encoder while the media engine takes no more sessions: 23 s for 3 s of 640 × 480 and 452 s for 1512 × 982 under
    /// load, against a fraction of a second, which spent the time limits of the tests on their fixtures. Waiting for the
    /// hardware encoder costs nothing while it is free and little CPU while it is not. A runner's virtual machine need
    /// not have one, and has no other checkouts to share the engine with.
    public static let defaultVideoEncoder: VideoEncoderChoice =
        ProcessInfo.processInfo.environment["TOMA_CI"] != "1" && hasHardwareHEVCEncoder ? .hardwareOnly : .any

    /// Whether VideoToolbox lists a hardware-accelerated HEVC encoder on this Mac.
    public static let hasHardwareHEVCEncoder: Bool = {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let encoders = list as? [[String: Any]] else { return false }
        return encoders.contains { encoder in
            (encoder[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == kCMVideoCodecType_HEVC
                && (encoder[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) == true
        }
    }()

    public typealias VideoWriterFactory = (_ url: URL, _ framesPerSecond: Int, _ encoder: VideoEncoderChoice) throws -> FragmentedTrackWriter

    private let takeID: String
    private var tracks: [TrackRecord] = []
    private var events: [InputEvent] = []
    /// Frames written to each video track so far: the number of its next frame.
    private var framesWritten: [String: Int] = [:]
    private var written = false

    /// Creates `<directory>/<name>.toma` with an empty manifest of `formatVersion`. With a version below 3, the
    /// package an earlier version of the app would have created, which keeps that version: without `projectID` and
    /// `upgradedFrom`, so its id is the derived one (`upgradedFrom` must be `nil`). From version 3, the `projectID` of
    /// `ProjectPackage.create` and `upgradedFrom` as given: a package an edit upgraded from that version. Version 4 is
    /// the one of a take with a track of a device (`TrackKind.device`, `.deviceAudio`) or `keyPress` events, which a
    /// package of an earlier version refuses when the take is written, as the recorder's would.
    public init(
        in directory: URL, name: String = "Fixture", formatVersion: Int = Manifest.currentFormatVersion,
        upgradedFrom: Int? = nil
    ) throws {
        guard formatVersion >= 3 || upgradedFrom == nil else {
            throw TestSupportError.failed("a package of version \(formatVersion) has no upgradedFrom")
        }
        package = try ProjectPackage.create(in: directory, name: name, app: AppInfo(name: "Tests", version: "0"), now: Date())
        takeID = "take-001"
        if formatVersion != Manifest.currentFormatVersion || upgradedFrom != nil {
            // Written here: `ManifestStore` keeps the version a package was created with.
            var manifest = try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
            manifest.formatVersion = formatVersion
            manifest.upgradedFrom = upgradedFrom
            if formatVersion < 3 { manifest.projectID = nil }
            try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(manifest), to: package.manifestURL)
        }
    }

    /// Writes the take `take` into `package`, which has a manifest (of the takes written before, which it never
    /// touches): `write(status:)` appends it to the manifest's takes, in the version the package has (raising the
    /// version for a second take is the recorder's rule, not the builder's). Throws for a take the manifest already has.
    public init(appendingTo package: ProjectPackage, take: String) throws {
        let manifest = try ManifestStore(package: package).manifest
        guard !manifest.takes.contains(where: { $0.id == take }) else {
            throw TestSupportError.failed("the package already has a take \(take)")
        }
        guard !FileManager.default.fileExists(atPath: package.takeDirectory(take).path) else {
            throw TestSupportError.failed("the package already has a folder for take \(take)")
        }
        self.package = package
        takeID = take
    }

    /// Adds a video track of `segments`, numbered from 1. Called again for the same track (same kind and
    /// source), it adds its segments after the track's last one.
    public nonisolated(nonsending) func addVideoTrack(
        id: String, kind: TrackKind = .display, source: TrackSource, segments: [VideoSegmentSpec]
    ) async throws {
        try addTrack(id: id, kind: kind, source: source)
        for spec in segments {
            let (index, url) = try nextSegment(of: id, start: spec.start)
            let first = framesWritten[id, default: 0]
            let count = Int((spec.seconds * Double(spec.framesPerSecond)).rounded())
            let end = try await writeVideoSegment(spec, to: url, frames: first..<(first + count))
            framesWritten[id] = first + count
            try record(index: index, of: id, url: url, start: spec.start, end: end, endReason: spec.endReason)
        }
    }

    /// Writes the frames `frames` of a track as the segment `spec` at `url` and returns where it ends; with
    /// `.hardwareOnly`, again and again while it fails in the encoder, as `videoEncoder` says.
    private nonisolated(nonsending) func writeVideoSegment(
        _ spec: VideoSegmentSpec, to url: URL, frames: Range<Int>
    ) async throws -> HostTime {
        while true {
            var writer: FragmentedTrackWriter?
            do {
                let made = try makeVideoWriter(url, spec.framesPerSecond, videoEncoder)
                writer = made
                for (i, frameIndex) in frames.enumerated() {
                    let pts = spec.start.adding(seconds: Double(i) / Double(spec.framesPerSecond))
                    let sample = SampleFactory.videoSample(width: spec.width, height: spec.height, pts: pts, frameIndex: frameIndex)
                    try made.append(spec.transform?(frameIndex, sample) ?? sample)
                }
                return try await close(made, at: spec.start.adding(seconds: spec.seconds), leaveOpen: spec.leaveOpen, url: url)
            } catch {
                guard videoEncoder == .hardwareOnly, Self.isEncoderFailure(error, of: writer) else { throw error }
                writer = nil
                // What a failed writer left; a new one refuses a path that is there.
                try? FileManager.default.removeItem(at: url)
                let deadline = hardwareEncoderDeadline ?? ContinuousClock.now + .seconds(hardwareEncoderTimeout)
                hardwareEncoderDeadline = deadline
                guard ContinuousClock.now < deadline else {
                    throw TestSupportError.failed("""
                        \(url.lastPathComponent): the hardware HEVC encoder still failed \(hardwareEncoderTimeout) s after this \
                        take's first encoder failure (the media engine takes no more sessions while other processes hold \
                        them); last error: \(error)
                        """)
                }
                try await Task.sleep(for: .seconds(hardwareEncoderRetryInterval))
            }
        }
    }

    /// Whether `error`, thrown while writing a segment with `writer` (`nil` when making it threw), is a failure of the
    /// encoder, which writing again may get past: the writer stopped (`failure`, a session the media engine refused or
    /// lost), it waited for the encoder past its readiness timeout, or making it threw `appendFailed` (a factory's
    /// refused session). A refused format or sample is a fault of the segment, which writing again would only repeat.
    private static func isEncoderFailure(_ error: any Error, of writer: FragmentedTrackWriter?) -> Bool {
        if writer?.failure != nil { return true }
        switch error {
        case WriterError.appendFailed("timeout"): return true
        case WriterError.appendFailed: return writer == nil
        default: return false
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
                    pts: pts(ofBlock: k), frames: frames, sampleRate: spec.sampleRate, channels: spec.channels,
                    amplitude: spec.amplitude, frequency: spec.frequency)
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

    /// Adds the cursor image `png` as the recorder saves one: written to `cursors/<hash>.png` now (unless that file is
    /// there), with `hash` the recorder's `CursorImageHash` of the decoded image and this hotspot, and its `cursorImage`
    /// event at `t`. `hotspot` is a fraction of the image from its top left and `size` is in points, as in the event.
    /// Returns the hash. Throws if `png` is not an image.
    @discardableResult
    public func addCursorImage(
        _ png: Data, hotspot: SIMD2<Double>, size: SIMD2<Double>, kind: CursorKind? = nil, at t: HostTime
    ) throws -> String {
        try checkNotWritten()
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw TestSupportError.failed("the cursor image is not an image") }
        let hash = CursorImageHash.hash(CursorSnapshot(image: image, pointSize: size, hotspot: hotspot * size, fingerprint: 0))
        let url = package.cursorImageURL(take: takeID, hash: hash)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: package.cursorsDirectory(take: takeID), withIntermediateDirectories: true)
            try png.write(to: url, options: .withoutOverwriting)
        }
        events.append(InputEvent(t: t, kind: .cursorImage(hash: hash, hotspot: hotspot, size: size, kind: kind)))
        return hash
    }

    /// Adds `events` to `events.jsonl`.
    public func addEvents(_ events: [InputEvent]) throws {
        try checkNotWritten()
        self.events += events
    }

    /// Writes the take with `status` to the manifest (after the takes it has) and its events to `events.jsonl`, in
    /// time order (events at the same time in the order they were added), as the pipeline logs them; returns the take
    /// as `LoadedProject.load` reads it. Call it once, after adding everything.
    public func write(status: TakeStatus = .complete) throws -> LoadedProject {
        try checkNotWritten()
        if let key = events.first(where: \.kind.requiresFormatVersion4) {
            let version = try ManifestStore(package: package).manifest.formatVersion
            if version < 4 {
                throw TestSupportError.failed("a package of version \(version) has no \(key.kind) event: make it with formatVersion 4")
            }
        }
        written = true
        try FileManager.default.createDirectory(at: package.takeDirectory(takeID), withIntermediateDirectories: true)
        var tracks = tracks
        for i in tracks.indices { tracks[i].segments.sort { $0.index < $1.index } }
        let take = TakeRecord(
            id: takeID, status: status, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: tracks, cameraStyle: cameraStyle)
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
