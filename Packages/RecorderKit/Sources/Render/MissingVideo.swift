// SPDX-License-Identifier: GPL-3.0-or-later

/// A span of the output where a screen segment's video could not be decoded, so the frame before it is
/// shown instead (or the background, before the first readable frame).
public struct MissingVideo: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// The segment holds no samples: crash recovery marked it `SegmentEndReason.empty`, or its file has 0
        /// bytes.
        case empty
        /// Crash recovery could not read the segment's file (`SegmentEndReason.unreadable`), or it has no
        /// frame at all.
        case unreadable
        /// The segment's file is not in the package.
        case fileMissing
        /// The file has no video track AVFoundation can open, or no reader for it (the error).
        case cannotOpen(String)
        /// Decoding stopped partway with this error; reading again after it did not get past the span.
        case readFailed(String)
        /// The segment's video track did not load within `TrackFrameReader.trackLoadTimeout`, so it was
        /// skipped for a while.
        case loadTimedOut
    }

    /// The segment's file, relative to the package root (`SegmentRecord.file`).
    public var file: String
    /// Output seconds where the span starts, within the output's timeline.
    public var start: Double
    /// Output seconds where it ends, within the timeline: the segment's end for a segment that cannot be
    /// used at all, where decoding could start again for a read failure, the last frame asked for while a
    /// load timed out.
    public var end: Double
    public var reason: Reason

    public init(file: String, start: Double, end: Double, reason: Reason) {
        self.file = file
        self.start = start
        self.end = end
        self.reason = reason
    }
}
