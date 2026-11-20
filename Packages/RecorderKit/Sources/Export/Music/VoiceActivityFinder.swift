// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// Where an audio track has a voice, for the ducking (`ducking-1`, plan 3c decision 8): inside the spans where the track is
/// heard, what `SilenceFinder` does not find quiet. A pause between two segments is not voice.
public enum VoiceActivityFinder {
    /// The stretches of `audio` with voice, in host time, in order and apart from one another (the ones that touch are one).
    /// - Throws: `CancellationError` if the task is cancelled.
    public static func voiced(_ audio: TrackAudio) async throws -> VoiceActivity {
        let quiet = try await SilenceFinder.quietSpans(audio).map { frame(of: $0.lowerBound, in: audio)..<frame(of: $0.upperBound, in: audio) }
        try Task.checkCancellation()
        var voiced: [Range<Int64>] = []
        for span in audio.spans {
            var cursor = span.frames.lowerBound
            for gap in quiet where gap.upperBound > cursor && gap.lowerBound < span.frames.upperBound {
                if gap.lowerBound > cursor { add(cursor..<gap.lowerBound, to: &voiced) }
                cursor = max(cursor, gap.upperBound)
            }
            if cursor < span.frames.upperBound { add(cursor..<span.frames.upperBound, to: &voiced) }
        }
        return VoiceActivity(spans: voiced.map { audio.host(atFrame: $0.lowerBound)..<audio.host(atFrame: $0.upperBound) })
    }

    private static func add(_ frames: Range<Int64>, to list: inout [Range<Int64>]) {
        if let last = list.last, last.upperBound >= frames.lowerBound {
            list[list.count - 1] = last.lowerBound..<max(last.upperBound, frames.upperBound)
        } else {
            list.append(frames)
        }
    }

    /// The timeline frame of `host`: the inverse of `TrackAudio.host(atFrame:)`.
    private static func frame(of host: HostTime, in audio: TrackAudio) -> Int64 {
        let ns = Int64(clamping: host.nanoseconds) - Int64(clamping: audio.origin.nanoseconds)
        let (scaled, overflow) = ns.multipliedReportingOverflow(by: 3)
        if overflow { return ns > 0 ? Int64.max / 2 : Int64.min / 2 }
        // ns × 48 000 / 10⁹ = ns × 3 / 62 500, to the nearest frame.
        return scaled >= 0 ? (scaled + 31_250) / 62_500 : -((-scaled + 31_250) / 62_500)
    }
}
