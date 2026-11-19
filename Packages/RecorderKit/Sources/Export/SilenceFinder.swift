// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// Where an audio track is quiet, for "hide the camera during silences" when the take has no transcript (phase 2 design
/// §5.5, plan decision 9): where its RMS, over every channel of a window of 50 ms, is under −45 dBFS.
///
/// The windows tile the take's timeline from its frame 0 (`TrackAudio.origin`), one every `windowFrames`, up to the end
/// of what a document can show of the take (`TakeTimeline.editableBounds`); one that starts there or later is not looked
/// at. A window wholly outside the track's spans (before the first segment, in a pause between two, after the last) is
/// quiet without being read; one that is partly sound is measured over all of its frames, the silence included. Quiet
/// windows next to each other are one span, the last one cut at the end of the timeline.
public enum SilenceFinder {
    public static let thresholdDBFS: Float = -45
    /// 50 ms at 48 kHz.
    public static let windowFrames = 2_400
    /// The windows read at a time: 1 s.
    static let chunkWindows: Int64 = 20

    /// The quiet spans of `audio`, in host time, in order and apart from one another. Reads 1 s at a time on a thread of
    /// its own, never on Swift's cooperative pool, and never more of the track than that.
    /// - Throws: `CancellationError` if the task is cancelled (seen between two reads).
    public static func quietSpans(_ audio: TrackAudio) async throws -> [Range<HostTime>] {
        try Task.checkCancellation()
        let cancelled = CancellationFlag()
        let frames = try await withTaskCancellationHandler {
            try await offTheCooperativePool { try quietFrames(audio, cancelled: cancelled) }
        } onCancel: {
            cancelled.cancel()
        }
        return frames.map { audio.host(atFrame: $0.lowerBound)..<audio.host(atFrame: $0.upperBound) }
    }

    /// The quiet spans of `audio` in timeline frames.
    static func quietFrames(_ audio: TrackAudio, cancelled: CancellationFlag) throws -> [Range<Int64>] {
        let window = Int64(windowFrames)
        let end = max(audio.endFrame, 0)
        // One past the last window that starts before the end.
        let windowsEnd = (end + window - 1) / window * window
        // Under −45 dBFS RMS: a mean square under 10^(−4.5).
        let limit = pow(10, Double(thresholdDBFS) / 10)
        let samplesPerWindow = windowFrames * audio.channels
        var quiet: [Range<Int64>] = []
        func mark(_ frames: Range<Int64>) {
            let frames = frames.lowerBound..<max(frames.lowerBound, min(frames.upperBound, end))
            guard !frames.isEmpty else { return }
            if let last = quiet.last, last.upperBound == frames.lowerBound {
                quiet[quiet.count - 1] = last.lowerBound..<frames.upperBound
            } else {
                quiet.append(frames)
            }
        }
        let reader = audio.makeReader()
        var samples: [Float] = []
        // The first window not looked at yet.
        var cursor: Int64 = 0
        for span in audio.spans {
            // The windows that hold any of the span's frames, and every one before them not looked at: all silence.
            let first = max(0, span.frames.lowerBound) / window * window
            let last = min((max(0, span.frames.upperBound) + window - 1) / window * window, windowsEnd)
            if cursor < first { mark(cursor..<first) }
            cursor = max(cursor, first)
            while cursor < last {
                if cancelled.isCancelled { throw CancellationError() }
                let to = min(cursor + chunkWindows * window, last)
                reader.read(cursor..<to, into: &samples)
                for start in stride(from: cursor, to: to, by: Int(window)) {
                    let offset = Int(start - cursor) * audio.channels
                    var sum = 0.0
                    for i in offset..<(offset + samplesPerWindow) { sum += Double(samples[i]) * Double(samples[i]) }
                    if sum / Double(samplesPerWindow) < limit { mark(start..<(start + window)) }
                }
                cursor = to
            }
        }
        if cursor < end { mark(cursor..<end) }
        return quiet
    }
}
