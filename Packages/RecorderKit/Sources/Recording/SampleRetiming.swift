// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import ProjectFormat

/// A captured frame moved to another instant, as a source would deliver it (the Replay's rotation, fases 4 y 5 plan 5c,
/// decision 2): a still screen's next segment starts with the last frame of the one before, at the instant it rotated.
enum SampleRetiming {
    /// A copy of the video frame `frame` (one sample, whatever time it had) presenting at `host` on the host clock,
    /// without a duration or a decode time, as `TrackPipeline` hands a source's frame to a writer. The image and the
    /// attachments are `frame`'s own.
    static func sample(_ frame: CMSampleBuffer, at host: HostTime) throws -> CMSampleBuffer {
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: host.cmTime, decodeTimeStamp: .invalid)
        return try CMSampleBuffer(copying: frame, withNewTiming: [timing])
    }
}
