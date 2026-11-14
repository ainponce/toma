// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ProjectFormat
import os

/// Decoded frames of one display track at any host time, across all its segments: the frame with the
/// latest presentation time at or before the time asked for.
///
/// Segments marked `.empty` or `.unreadable`, files that are missing, and files AVFoundation cannot open or
/// read are gaps: the last frame before them is held. Reading forward by less than `sequentialWindow` keeps
/// decoding the open reader (the export path); a step back or a longer jump opens a new reader `preroll`
/// before the time. At most one `AVAssetReader` is open at a time.
///
/// A segment whose video track takes longer than `trackLoadTimeout` to load is skipped (a gap) for
/// `timeoutBackoff` seconds and then tried again; only a load that fails marks it unreadable.
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
    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "TrackFrameReader")

    private struct Segment {
        var index: Int
        var start: HostTime
        var end: HostTime?
        var url: URL
        /// False once it is known to hold nothing readable.
        var usable: Bool
        /// Its file and video track, loaded once. The asset is kept because a track does not retain it.
        var media: (asset: AVURLAsset, track: AVAssetTrack)?
        /// After a load timed out: no new attempt before this wall-clock host time.
        var retryAfter: HostTime?
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
        /// Nothing can be read from the segment.
        case unreadable
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
    }

    private let lock = NSLock()
    private let trackID: String
    private var segments: [Segment]
    private var open: OpenReader?
    private var openedReaders = 0
    /// Loads a segment's video track; tests replace it. Called with the lock held.
    var trackLoader: (AVURLAsset) -> TrackLoad = TrackFrameReader.loadFirstVideoTrack(of:)
    /// Wall-clock seconds a segment whose track load timed out is skipped before the next attempt.
    var timeoutBackoff = 2.0

    /// How many readers have been opened, for tests.
    var openedReaderCount: Int { lock.withLock { openedReaders } }

    /// Never throws and reads nothing yet: every segment is opened when it is first needed.
    public init(package: ProjectPackage, track: TrackRecord) {
        trackID = track.id
        segments = track.segments
            .sorted { $0.startHostTime < $1.startHostTime }
            .map { record in
                let url = package.url.appending(path: record.file)
                let usable: Bool
                switch record.endReason {
                case .empty, .unreadable: usable = false
                default: usable = FileManager.default.fileExists(atPath: url.path)
                }
                return Segment(
                    index: record.index, start: record.startHostTime, end: record.endHostTime, url: url,
                    usable: usable, media: nil, retryAfter: nil)
            }
    }

    deinit {
        open?.reader.cancelReading()
    }

    /// A BGRA, IOSurface-backed, Metal-compatible frame: the latest one presented at or before `time`.
    /// `nil` before the first readable frame of the track.
    public func pixelBuffer(at time: HostTime) -> CVPixelBuffer? {
        lock.withLock { frame(at: time)?.pixelBuffer }
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
        if var reader = open, reader.segment == k, reader.current != nil, time >= reader.lastRequest,
           time.seconds(since: reader.lastRequest) < Self.sequentialWindow {
            advance(&reader, to: time)
            open = reader
            return reader.current
        }

        let segment = segments[k]
        let offset = time.seconds(since: segment.start)
        let end = segment.end.map { $0.seconds(since: segment.start) } ?? offset
        let from = max(0, min(offset, end) - Self.preroll)
        // From 0 too if nothing turns up, in case the frame shown at `time` came more than `preroll` earlier.
        for start in from > 0 ? [from, 0] : [0] {
            var reader: OpenReader
            switch openReader(k, from: start) {
            case .opened(let opened):
                reader = opened
            case .later:
                return nil
            case .unreadable:
                markUnusable(k, "cannot be opened")
                return nil
            }
            advance(&reader, to: time)
            open = reader
            if let current = reader.current { return current }
            if start == 0, reader.next != nil { return nil }  // it has frames, all after `time`
        }
        markUnusable(k, "has no frames")
        return nil
    }

    /// Decodes up to the first frame after `time`.
    private func advance(_ reader: inout OpenReader, to time: HostTime) {
        let segmentStart = segments[reader.segment].start
        while true {
            if let next = reader.next {
                guard next.time <= time else { break }
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
            reader.next = Frame(
                time: HostTime(nanoseconds: segmentStart.nanoseconds &+ HostTime(pts).nanoseconds),
                pixelBuffer: pixelBuffer)
        }
        reader.lastRequest = time
    }

    /// Opens a reader on segment `k` from `offset` seconds into its file, after closing the open one.
    /// The open reader stays open if the segment's track is not loaded yet.
    private func openReader(_ k: Int, from offset: Double) -> Opening {
        guard let (asset, track) = loadMedia(k) else {
            return segments[k].retryAfter == nil ? .unreadable : .later
        }
        close()
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            Self.logger.error(
                "Track \(self.trackID, privacy: .public) segment \(self.segments[k].index): no reader: \(String(describing: error), privacy: .public)")
            return .unreadable
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return .unreadable }
        reader.add(output)
        if offset > 0 {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: offset, preferredTimescale: 1_000_000_000), duration: .positiveInfinity)
        }
        guard reader.startReading() else {
            Self.logger.error(
                "Track \(self.trackID, privacy: .public) segment \(self.segments[k].index): cannot start reading: \(String(describing: reader.error), privacy: .public)")
            return .unreadable
        }
        openedReaders += 1
        return .opened(OpenReader(segment: k, reader: reader, output: output, lastRequest: segments[k].start))
    }

    private func close() {
        open?.reader.cancelReading()
        open = nil
    }

    private func markUnusable(_ k: Int, _ why: String) {
        segments[k].usable = false
        if open?.segment == k { close() }
        Self.logger.error(
            "Track \(self.trackID, privacy: .public) segment \(self.segments[k].index) \(why, privacy: .public): holding the frame before it")
    }

    /// The file of segment `k` and its video track, loaded once. `nil` with `retryAfter` set while a
    /// timed-out load is backing off, `nil` without it when the file has no readable video track.
    private func loadMedia(_ k: Int) -> (asset: AVURLAsset, track: AVAssetTrack)? {
        if let media = segments[k].media { return media }
        if let retryAfter = segments[k].retryAfter, HostTime.now() < retryAfter { return nil }
        let asset = AVURLAsset(url: segments[k].url)
        switch trackLoader(asset) {
        case .loaded(let track):
            segments[k].media = (asset, track)
            segments[k].retryAfter = nil
            return (asset, track)
        case .failed(let reason):
            segments[k].retryAfter = nil
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
