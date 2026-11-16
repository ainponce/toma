// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ProjectFormat
import os

/// Decoded frames of one video track (the screen or the camera) at any host time, across all its segments: the
/// frame with the latest presentation time at or before the time asked for.
///
/// Segments that are not `SegmentAvailability.present` (marked `.empty` or `.unreadable`, a file of 0 bytes or
/// none) and files AVFoundation cannot open or read are gaps: the last frame before them is held. Reading
/// forward by less than `sequentialWindow` keeps decoding the open reader (the export path); a step back or a
/// longer jump opens a new reader at the frame presented at or before the time, which its file's sample cursor finds
/// (`AVSampleCursor`), so it hands over that frame first and decodes no more than its group of pictures up to it; for
/// a file that has no sample cursor, `preroll` before the time. At most one `AVAssetReader` reads at a time: the one
/// it leaves is cancelled on a queue of its own, without waiting for it.
///
/// When decoding stops with an error partway through a segment, the next time asked for after the last
/// frame decoded opens a reader again right after that frame; if it stops at the same frame again, each
/// further attempt starts `preroll` seconds later, until one decodes or the segment ends. A segment whose
/// video track takes longer than `trackLoadTimeout` to load is skipped (a gap) for `timeoutBackoff` seconds
/// and then tried again; only a load that fails marks it unreadable. Every span shown with the frame before
/// it for one of these reasons is in `gaps`, so no gap goes unreported.
///
/// Thread-safe: calls are serialized. Blocks while it loads and decodes (`copyNextSampleBuffer`, and up to
/// `trackLoadTimeout` for a track): never call it from a Swift concurrency thread. Many blocked callers
/// there leave the cooperative pool no thread, and every task of the app stops. Use a dispatch queue
/// (`PreviewPreparation`, the exporter's queue) or the main thread for a single frame.
public final class TrackFrameReader: @unchecked Sendable {
    static let sequentialWindow = 2.0
    /// Keyframes come every second, so a reader opened this long before a time reaches it decoding at
    /// most two seconds of video.
    static let preroll = 1.0
    static let trackLoadTimeout = DispatchTimeInterval.seconds(10)
    /// The frame interval assumed until two frames of a reader give the real one.
    static let defaultFrameInterval = 1.0 / 30
    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "TrackFrameReader")

    private struct Segment {
        var index: Int
        /// `SegmentRecord.file`.
        var file: String
        var start: HostTime
        var end: HostTime?
        var url: URL
        /// False once it is known to hold nothing readable.
        var usable: Bool
        /// Its file and video track, loaded once. The asset is kept because a track does not retain it.
        var media: (asset: AVURLAsset, track: AVAssetTrack)?
        /// After a load timed out: no new attempt before this wall-clock host time.
        var retryAfter: HostTime?
        /// Why its video track could not be loaded, once a load failed.
        var loadFailure: String?
        /// Decoding last stopped with an error after the frame at `lastGood`, `attempts` times in a row;
        /// `gaveUp` once no reader can get past it before the segment ends.
        var failure: (lastGood: HostTime, attempts: Int, gaveUp: Bool)?
    }

    /// A span of host time shown with the frame before it, and why.
    struct Gap: Equatable {
        var file: String
        var start: HostTime
        var end: HostTime
        var reason: MissingVideo.Reason
    }

    /// The outcome of loading a segment's video track.
    enum TrackLoad {
        case loaded(AVAssetTrack)
        /// The file has no readable video track: it never will.
        case failed(String)
        /// No answer within `trackLoadTimeout`: maybe later.
        case timedOut
    }

    private enum Opening {
        case opened(OpenReader)
        /// Nothing can be read from the segment; why.
        case unreadable(String)
        /// Its track has not loaded yet; try again after the backoff.
        case later
    }

    private struct Frame {
        var time: HostTime
        var pixelBuffer: CVPixelBuffer
    }

    private struct OpenReader {
        var segment: Int
        var reader: AVAssetReader
        var output: AVAssetReaderTrackOutput
        /// The latest frame at or before `lastRequest`.
        var current: Frame?
        /// The first frame after `lastRequest`, already decoded.
        var next: Frame?
        var finished = false
        var lastRequest: HostTime
        /// Frames presented at or before this time are dropped: a reader opened again after a read failure
        /// starts after the frame it holds.
        var skipThrough: HostTime?
        /// Seconds between the last two frames decoded.
        var frameInterval = TrackFrameReader.defaultFrameInterval
    }

    private let lock = NSLock()
    /// The track read (`TrackRecord.id`).
    let trackID: String
    private var segments: [Segment]
    private var open: OpenReader?
    private var openedReaders = 0
    private var recordedGaps: [Gap] = []
    private var asked: ClosedRange<HostTime>?
    /// Loads a segment's video track; tests replace it. Called with the lock held.
    var trackLoader: (AVURLAsset) -> TrackLoad = TrackFrameReader.loadFirstVideoTrack(of:)
    /// Wall-clock seconds a segment whose track load timed out is skipped before the next attempt.
    var timeoutBackoff = 2.0

    /// How many readers have been opened, for tests.
    var openedReaderCount: Int { lock.withLock { openedReaders } }

    /// The earliest and the latest host times a frame was asked for so far (`nil` before the first), for tests.
    var askedFor: ClosedRange<HostTime>? { lock.withLock { asked } }

    /// The spans shown with the frame before them so far, in the order they were found: the segments that are
    /// not `SegmentAvailability.present` from the start, the others as frames were asked for.
    /// Consecutive spans of a segment for the same reason are merged.
    var gaps: [Gap] { lock.withLock { recordedGaps } }

    /// Never throws and reads nothing yet: every segment is classified without opening it, and opened when it
    /// is first needed.
    public init(package: ProjectPackage, track: TrackRecord) {
        trackID = track.id
        let records = track.segments.sorted { $0.startHostTime < $1.startHostTime }
        segments = records.map { record in
            Segment(
                index: record.index, file: record.file, start: record.startHostTime, end: record.endHostTime,
                url: package.fileURL(record.file), usable: true, media: nil, retryAfter: nil, loadFailure: nil, failure: nil)
        }
        for (k, record) in records.enumerated() {
            let reason: MissingVideo.Reason
            switch SegmentAvailability.classify(record, in: package) {
            case .present: continue
            case .missing: reason = .fileMissing
            case .empty: reason = .empty
            case .unreadable: reason = .unreadable
            }
            segments[k].usable = false
            noteGap(k, from: segments[k].start, to: segments[k].end ?? segments[k].start, reason)
        }
    }

    deinit {
        open?.reader.cancelReading()
    }

    /// A segment's file and video track, and the host time its file starts at.
    struct Media: @unchecked Sendable {
        var start: HostTime
        /// Where the segment ends; `nil` for one left open.
        var end: HostTime?
        var asset: AVURLAsset
        var track: AVAssetTrack
    }

    /// The segment that shows `time` (the last usable one starting at or before it), with its file and video track,
    /// loaded as `pixelBuffer(at:)` loads them (it blocks the same way, up to `trackLoadTimeout`); `nil` before the track's
    /// first segment, in a segment that cannot be used, and while its load is backing off after timing out. Opens no
    /// reader: for `KeyFrameDecoder`, which reads the file on its own.
    func media(at time: HostTime) -> Media? {
        lock.withLock {
            guard let k = segments.lastIndex(where: { $0.usable && $0.start <= time }), let (asset, track) = loadMedia(k)
            else { return nil }
            return Media(start: segments[k].start, end: segments[k].end, asset: asset, track: track)
        }
    }

    /// A BGRA, IOSurface-backed, Metal-compatible frame: the latest one presented at or before `time`.
    /// `nil` before the first readable frame of the track.
    public func pixelBuffer(at time: HostTime) -> CVPixelBuffer? {
        lock.withLock {
            asked = asked.map { min($0.lowerBound, time)...max($0.upperBound, time) } ?? time...time
            return frame(at: time)?.pixelBuffer
        }
    }

    private func frame(at time: HostTime) -> Frame? {
        // Segments are sorted by start, so every usable one before `k` also starts at or before `time`.
        var candidate = segments.lastIndex { $0.usable && $0.start <= time }
        while let k = candidate {
            if let frame = frame(at: time, in: k) { return frame }
            candidate = segments[..<k].lastIndex { $0.usable }
        }
        return nil
    }

    /// The latest frame of segment `k` at or before `time`, or `nil` (marking the segment unusable when it
    /// holds no frame at all).
    private func frame(at time: HostTime, in k: Int) -> Frame? {
        // A step back that stays on the frame held (no frame comes between it and the last time asked for): that frame.
        if let reader = open, reader.segment == k, let current = reader.current, time >= current.time, time < reader.lastRequest {
            return current
        }
        if var reader = open, reader.segment == k, reader.current != nil, time >= reader.lastRequest,
           time.seconds(since: reader.lastRequest) < Self.sequentialWindow {
            advance(&reader, to: time)
            open = reader
            return readOnIfStoppedEarly(k, at: time) ?? reader.current
        }

        let segment = segments[k]
        let offset = time.seconds(since: segment.start)
        let end = segment.end.map { $0.seconds(since: segment.start) } ?? offset
        let target = min(offset, end)
        var from = max(0, target - Self.preroll)
        // Loaded once here (`openReader` does not try again): right at the frame shown at `target`, a little before it
        // so a rounding never leaves it out.
        let media = loadMedia(k)
        if target > 0, let track = media?.track, let shown = Self.presentationTime(atOrBefore: target, of: track) {
            from = max(0, shown - Self.seekMargin)
        }
        // From 0 too if nothing turns up, in case the frame shown at `time` came more than `preroll` earlier.
        var failure: String?
        for start in from > 0 ? [from, 0] : [0] {
            var reader: OpenReader
            switch openReader(k, from: start, media: media) {
            case .opened(let opened):
                reader = opened
            case .later:
                noteGap(k, from: time, to: time, .loadTimedOut)
                return nil
            case .unreadable(let why):
                markUnusable(k, .cannotOpen(why))
                return nil
            }
            advance(&reader, to: time)
            open = reader
            if reader.current != nil { return readOnIfStoppedEarly(k, at: time) ?? reader.current }
            if start == 0, reader.next != nil { return nil }  // it has frames, all after `time`
            if reader.reader.status == .failed { failure = Self.describe(reader.reader.error) }
        }
        markUnusable(k, failure.map { .readFailed($0) } ?? .unreadable)
        return nil
    }

    /// Whether the open reader of segment `k` stopped with an error before `time`, inside the segment:
    /// it has no frame after the one it holds, and more of the segment comes after that frame.
    private func stoppedEarly(_ reader: OpenReader, at time: HostTime) -> Bool {
        guard reader.finished, reader.next == nil, reader.reader.status == .failed,
              let held = reader.current, time > held.time
        else { return false }
        if let failure = segments[reader.segment].failure, failure.lastGood == held.time, failure.gaveUp { return false }
        return segments[reader.segment].end.map { held.time.adding(seconds: reader.frameInterval) < $0 } ?? true
    }

    /// When the open reader of segment `k` stopped with an error before `time`, opens one again after the
    /// frame it holds (later and later if it keeps stopping there), records the span it skips, and returns
    /// the frame to show at `time`: the new reader's, or the held one. `nil` if it did not stop early.
    private func readOnIfStoppedEarly(_ k: Int, at time: HostTime) -> Frame? {
        guard let failed = open, failed.segment == k, stoppedEarly(failed, at: time), let held = failed.current else {
            return nil
        }
        let error = Self.describe(failed.reader.error)
        let attempts = segments[k].failure.map { $0.lastGood == held.time ? $0.attempts + 1 : 1 } ?? 1
        segments[k].failure = (held.time, attempts, false)
        let interval = failed.frameInterval
        let firstMissing = held.time.adding(seconds: interval)
        // Right after the held frame first: a read error that does not come back costs nothing. Then past it.
        let resumeAt = firstMissing.adding(seconds: Double(attempts - 1) * Self.preroll)
        if let end = segments[k].end, resumeAt >= end {
            segments[k].failure = (held.time, attempts, true)
            noteGap(k, from: firstMissing, to: end, .readFailed(error))
            Self.logger.error(
                "Track \(self.trackID, privacy: .public) segment \(self.segments[k].index): cannot read past \(held.time.nanoseconds) ns; holding that frame to the segment's end")
            return held
        }
        if attempts > 1 { noteGap(k, from: firstMissing, to: resumeAt, .readFailed(error)) }
        switch openReader(k, from: resumeAt.seconds(since: segments[k].start)) {
        case .opened(var reader):
            reader.current = held
            reader.skipThrough = held.time
            reader.frameInterval = interval
            advance(&reader, to: time)
            open = reader
            return reader.current
        case .later:
            noteGap(k, from: firstMissing, to: time, .loadTimedOut)
        case .unreadable(let why):
            segments[k].failure = (held.time, attempts, true)
            noteGap(k, from: firstMissing, to: segments[k].end ?? time, .cannotOpen(why))
        }
        return held
    }

    /// Seconds a reader opened at a frame starts before it: less than any frame lasts.
    static let seekMargin = 0.001

    /// The presentation time, in seconds into its file, of the sample of `track` presented at or before `seconds`;
    /// `nil` when the file has no sample cursor or no sample at or before it.
    static func presentationTime(atOrBefore seconds: Double, of track: AVAssetTrack) -> Double? {
        let time = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: time) else { return nil }
        while cursor.presentationTimeStamp > time {
            guard cursor.stepInPresentationOrder(byCount: -1) == -1 else { return nil }
        }
        let shown = cursor.presentationTimeStamp.seconds
        return shown.isFinite ? shown : nil
    }

    /// Decodes up to the first frame after `time`.
    private func advance(_ reader: inout OpenReader, to time: HostTime) {
        let segmentStart = segments[reader.segment].start
        while true {
            if let next = reader.next {
                guard next.time <= time else { break }
                if let current = reader.current, next.time > current.time {
                    reader.frameInterval = next.time.seconds(since: current.time)
                }
                reader.current = next
                reader.next = nil
            }
            if reader.finished { break }
            guard let sample = reader.output.copyNextSampleBuffer() else {
                reader.finished = true
                if reader.reader.status == .failed {
                    let index = segments[reader.segment].index
                    let error = String(describing: reader.reader.error)
                    Self.logger.error(
                        "Track \(self.trackID, privacy: .public) segment \(index): reading stopped: \(error, privacy: .public)")
                }
                break
            }
            let pts = sample.presentationTimeStamp
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample), pts.isNumeric else { continue }
            let frameTime = HostTime(nanoseconds: segmentStart.nanoseconds &+ HostTime(pts).nanoseconds)
            if let skipThrough = reader.skipThrough, frameTime <= skipThrough { continue }
            reader.next = Frame(time: frameTime, pixelBuffer: pixelBuffer)
        }
        reader.lastRequest = time
    }

    /// Opens a reader on segment `k` from `offset` seconds into its file, after closing the open one.
    /// The open reader stays open if the segment's track is not loaded yet.
    /// `media`: `loadMedia(k)`, just called (the default calls it).
    private func openReader(
        _ k: Int, from offset: Double, media: (asset: AVURLAsset, track: AVAssetTrack)?? = .none
    ) -> Opening {
        guard let (asset, track) = media ?? loadMedia(k) else {
            return segments[k].retryAfter == nil ? .unreadable(segments[k].loadFailure ?? "the file has no readable video track") : .later
        }
        close()
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            Self.logger.error(
                "Track \(self.trackID, privacy: .public) segment \(self.segments[k].index): no reader: \(String(describing: error), privacy: .public)")
            return .unreadable(Self.describe(error))
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return .unreadable("the reader takes no output for the video track") }
        reader.add(output)
        if offset > 0 {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: offset, preferredTimescale: 1_000_000_000), duration: .positiveInfinity)
        }
        guard reader.startReading() else {
            Self.logger.error(
                "Track \(self.trackID, privacy: .public) segment \(self.segments[k].index): cannot start reading: \(String(describing: reader.error), privacy: .public)")
            return .unreadable(Self.describe(reader.error))
        }
        openedReaders += 1
        return .opened(OpenReader(segment: k, reader: reader, output: output, lastRequest: segments[k].start))
    }

    /// Lets the open reader go. Cancelling a reader waits for what it is decoding ahead, tens of milliseconds at 4K, so
    /// it is cancelled on a queue of its own: a jump opens its new reader at once, while the old one winds down.
    private func close() {
        if let reader = open?.reader {
            let closing = ClosingReader(reader)
            Self.closingQueue.async { closing.reader.cancelReading() }
        }
        open = nil
    }

    /// Where readers let go are cancelled.
    private static let closingQueue = DispatchQueue(label: "dev.toma.TrackFrameReader.close", qos: .userInitiated)

    private func markUnusable(_ k: Int, _ reason: MissingVideo.Reason) {
        segments[k].usable = false
        if open?.segment == k { close() }
        noteGap(k, from: segments[k].start, to: segments[k].end ?? segments[k].start, reason)
        Self.logger.error(
            "Track \(self.trackID, privacy: .public) segment \(self.segments[k].index) cannot be used (\(String(describing: reason), privacy: .public)): holding the frame before it")
    }

    /// Records that `from ... to` of segment `k` is shown with the frame before it, merged into the last
    /// span when it is of the same segment and reason and starts within `sequentialWindow` of its end.
    private func noteGap(_ k: Int, from: HostTime, to: HostTime, _ reason: MissingVideo.Reason) {
        let file = segments[k].file
        let end = max(from, to)
        if let last = recordedGaps.indices.last, recordedGaps[last].file == file, recordedGaps[last].reason == reason,
           from.seconds(since: recordedGaps[last].end) <= Self.sequentialWindow, from >= recordedGaps[last].start {
            recordedGaps[last].end = max(recordedGaps[last].end, end)
            return
        }
        recordedGaps.append(Gap(file: file, start: from, end: end, reason: reason))
    }

    /// The file of segment `k` and its video track, loaded once. `nil` with `retryAfter` set while a
    /// timed-out load is backing off, `nil` without it when the file has no readable video track.
    private func loadMedia(_ k: Int) -> (asset: AVURLAsset, track: AVAssetTrack)? {
        if let media = segments[k].media { return media }
        // A load that failed never succeeds: it is not tried again.
        if segments[k].loadFailure != nil { return nil }
        if let retryAfter = segments[k].retryAfter, HostTime.now() < retryAfter { return nil }
        let asset = AVURLAsset(url: segments[k].url)
        switch trackLoader(asset) {
        case .loaded(let track):
            segments[k].media = (asset, track)
            segments[k].retryAfter = nil
            return (asset, track)
        case .failed(let reason):
            segments[k].retryAfter = nil
            segments[k].loadFailure = reason
            Self.logger.error(
                "Track \(self.trackID, privacy: .public) segment \(self.segments[k].index): no video track: \(reason, privacy: .public)")
            return nil
        case .timedOut:
            segments[k].retryAfter = HostTime.now().adding(seconds: timeoutBackoff)
            Self.logger.error(
                "Track \(self.trackID, privacy: .public) segment \(self.segments[k].index): loading timed out, trying again in \(self.timeoutBackoff) s")
            return nil
        }
    }

    /// `domain code: description` of an error and of the one under it: the same text for the same failure
    /// every time (unlike `String(describing:)`, which shows addresses), so spans of one failure merge.
    static func describe(_ error: (any Error)?) -> String {
        guard let error = error.map({ $0 as NSError }) else { return "no error given" }
        var text = "\(error.domain) \(error.code): \(error.localizedDescription)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (\(underlying.domain) \(underlying.code))"
        }
        return text
    }

    /// Loads the first video track of `asset`, waiting at most `trackLoadTimeout`.
    static func loadFirstVideoTrack(of asset: AVURLAsset) -> TrackLoad {
        let loaded = LoadedTrack()
        let done = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .video) { tracks, error in
            loaded.set(tracks?.first, error)
            done.signal()
        }
        guard done.wait(timeout: .now() + trackLoadTimeout) == .success else { return .timedOut }
        let (track, error) = loaded.get()
        guard let track else { return .failed(error.map { String(describing: $0) } ?? "the file has no video track") }
        return .loaded(track)
    }

    /// BGRA in IOSurfaces, so `CVMetalTextureCache` can wrap the frames without copying.
    private static var outputSettings: [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    }
}

/// A reader handed to `TrackFrameReader.closingQueue` to be cancelled there; nothing else uses it any more.
private final class ClosingReader: @unchecked Sendable {
    let reader: AVAssetReader

    init(_ reader: AVAssetReader) {
        self.reader = reader
    }
}

/// The result of `loadTracks`, handed from AVFoundation's queue to the waiting caller.
private final class LoadedTrack: @unchecked Sendable {
    private let lock = NSLock()
    private var track: AVAssetTrack?
    private var error: (any Error)?

    func set(_ track: AVAssetTrack?, _ error: (any Error)?) {
        lock.withLock { (self.track, self.error) = (track, error) }
    }

    func get() -> (AVAssetTrack?, (any Error)?) {
        lock.withLock { (track, error) }
    }
}
