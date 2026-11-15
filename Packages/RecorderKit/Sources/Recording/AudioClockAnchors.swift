// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// When an audio segment logs an `audioClock` event: after each append, for the sample the writer wrote
/// last (`TrackWriting.lastWrittenAudio`), once `interval` seconds of host time have passed since the last
/// anchor; frame 0, the segment's start, is the first. The frame is the writer's count of frames written, so
/// audio it drops in real time never shifts the anchors: they always name a frame that is in the file.
package struct AudioClockAnchors: Equatable, Sendable {
    /// Seconds of host time between two anchors of a segment.
    package static let interval = 5.0

    private var last: HostTime

    package init(segmentStart: HostTime) {
        last = segmentStart
    }

    /// The anchor to log now that `written` is the sample written last, or `nil` if none is due.
    package mutating func anchor(for written: AudioFilePosition) -> AudioFilePosition? {
        guard written.frame > 0, written.hostTime.seconds(since: last) >= Self.interval else { return nil }
        last = written.hostTime
        return written
    }
}
