// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation
import ProjectFormat

/// What a closed segment contains.
public struct SegmentResult: Equatable, Sendable {
    /// Host time of the first sample, which is time zero in the file. `nil` if nothing was written.
    public var startHostTime: HostTime?
    /// Host time where the segment ends.
    public var endHostTime: HostTime
    /// Source samples written. Heartbeats and the repeat of the last frame at `finish` are not counted.
    public var sampleCount: Int
    /// Samples taken from the source and discarded because the encoder had no room (real time only).
    public var droppedSampleCount: Int
    /// Repeats of the last video frame written by `appendHeartbeat(at:)`.
    public var heartbeatSampleCount: Int

    public init(
        startHostTime: HostTime? = nil,
        endHostTime: HostTime,
        sampleCount: Int,
        droppedSampleCount: Int,
        heartbeatSampleCount: Int
    ) {
        self.startHostTime = startHostTime
        self.endHostTime = endHostTime
        self.sampleCount = sampleCount
        self.droppedSampleCount = droppedSampleCount
        self.heartbeatSampleCount = heartbeatSampleCount
    }
}

/// An audio sample in its segment's file: the frame it starts at and when it was captured.
public struct AudioFilePosition: Equatable, Sendable {
    /// Frames before it in the file, counted from 0 at the segment's start.
    public var frame: Int
    /// Its presentation time on the host clock.
    public var hostTime: HostTime

    public init(frame: Int, hostTime: HostTime) {
        self.frame = frame
        self.hostTime = hostTime
    }
}

public enum WriterError: Error, Equatable {
    /// The sample's format cannot be encoded by this writer (wrong media, compressed, or refused settings).
    case unsupportedFormat
    /// The sample could not be written. A failed writer also exposes the cause in `TrackWriting.failure`.
    case appendFailed(String)
    /// `finish(at:)` was already called.
    case alreadyFinished
    /// The segment file already exists. It is never overwritten or deleted.
    case fileExists
}

/// Writes one segment of one track. Used by a single owner, one call at a time.
public protocol TrackWriting: AnyObject {
    /// Called once, with the host time of the first sample, when the segment file has been created.
    var onStart: ((HostTime) -> Void)? { get set }
    /// Format of the first sample (the source format), or `nil` before it.
    var formatDescription: CMFormatDescription? { get }
    /// Set when the underlying writer failed; every later `append` throws `appendFailed`.
    var failure: NSError? { get }
    /// Samples discarded so far because the encoder had no room (real time only). `finish` reports the
    /// final count, which may be higher, as `SegmentResult.droppedSampleCount`.
    var droppedSampleCount: Int { get }
    /// The audio sample handed to the encoder last: its frame counts every frame written before it, and
    /// none that was dropped. `nil` before the first one, and for video.
    var lastWrittenAudio: AudioFilePosition? { get }
    func append(_ sample: CMSampleBuffer) throws
    /// Repeats the last video frame at `time`, so a static screen keeps producing fragments.
    func appendHeartbeat(at time: HostTime) throws
    /// Closes the segment at `stopTime`. Called once; later calls throw `alreadyFinished`.
    ///
    /// Once the segment has started (`onStart` was called), `finish` always returns a result with
    /// the counts, and a writer error is reported through `failure`, never thrown. `endHostTime` is
    /// `stopTime` (never before the last sample taken) when the file was finished, or the last sample
    /// written when the writer failed and the file keeps only the fragments written before it. With
    /// nothing started, the result has `startHostTime == nil` and `endHostTime == stopTime`.
    /// Besides `alreadyFinished`, a conformer may throw only when nothing was started and closing
    /// itself failed; `FragmentedTrackWriter` never touches a file it did not start, so it never does.
    ///
    /// Runs on the caller's actor (`nonisolated(nonsending)`), so the pipeline actor that owns the
    /// non-Sendable writer can await it without sending the writer to another executor.
    nonisolated(nonsending) func finish(at stopTime: HostTime) async throws -> SegmentResult
}
