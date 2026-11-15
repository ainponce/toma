// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia

/// Puts the samples of an `AVCaptureSession` (a microphone, a camera) on the host clock: their timestamps are
/// on the session's `synchronizationClock`.
enum CaptureClock {
    /// A copy of `sample` whose presentation (and decode, if any) timestamps go through `convert`. The media
    /// (audio, or the image buffer and its attachments) is the same.
    static func retimed(_ sample: CMSampleBuffer, _ convert: (CMTime) -> CMTime) throws -> CMSampleBuffer {
        var timings = try sample.sampleTimingInfos()
        for i in timings.indices {
            timings[i].presentationTimeStamp = convert(timings[i].presentationTimeStamp)
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = convert(timings[i].decodeTimeStamp)
            }
        }
        return try CMSampleBuffer(copying: sample, withNewTiming: timings)
    }

    /// `sample` with its timestamps converted from `clock` to the host clock. `nil` (a session that has no
    /// clock yet) is taken as the host clock.
    static func retimed(_ sample: CMSampleBuffer, from clock: CMClock?) throws -> CMSampleBuffer {
        let hostClock = CMClockGetHostTimeClock()
        let sourceClock = clock ?? hostClock
        return try retimed(sample) { CMSyncConvertTime($0, from: sourceClock, to: hostClock) }
    }
}
