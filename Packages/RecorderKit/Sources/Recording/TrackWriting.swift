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
    func append(_ sample: CMSampleBuffer) throws
    /// Repeats the last video frame at `time`, so a static screen keeps producing fragments.
    func appendHeartbeat(at time: HostTime) throws
    /// Closes the segment at `stopTime`. Called once; later calls throw `alreadyFinished`.
    /// Runs on the caller's actor (`nonisolated(nonsending)`), so the pipeline actor that owns the
    /// non-Sendable writer can await it without sending the writer to another executor.
    nonisolated(nonsending) func finish(at stopTime: HostTime) async throws -> SegmentResult
}
