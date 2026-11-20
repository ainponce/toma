// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// How much of an audio track sounds like someone speaking (plan 3d, Task T7): for a take without a microphone whose
/// system audio By App recorded in a track for each app (phase 3 design §7.1), which of them the transcription hears.
///
/// Speech comes in syllables and words with dips between them; music, loud or soft, goes on sounding. So a second of the
/// take's timeline (one every 48 000 frames from its frame 0, up to the end of what a document can show of the take, as
/// `SilenceFinder` tiles it) sounds like speech when it is not quiet (its mean power, over every channel, at least
/// `SilenceFinder.thresholdDBFS`) and at least `lowEnergyShare` of its 20 ms frames have less than half of its mean
/// power: the "low-energy frames" of the speech and music discriminator of Scheirer and Slaney (1997). A second wholly
/// outside the track's spans is quiet without being read; one partly sound is measured over all of its frames.
public enum SpeechAmount {
    /// 20 ms at 48 kHz.
    public static let frameLength = 960
    /// 1 s at 48 kHz.
    public static let secondFrames = 48_000
    /// The share of a second's frames under half its mean power that sounds like speech.
    public static let lowEnergyShare = 0.3

    /// The seconds of `audio` that sound like speech. Reads a second at a time on a thread of its own, never on Swift's
    /// cooperative pool.
    /// - Throws: `CancellationError` if the task is cancelled (seen between two seconds).
    public static func seconds(_ audio: TrackAudio) async throws -> Int {
        try Task.checkCancellation()
        let cancelled = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await offTheCooperativePool { try seconds(audio, cancelled: cancelled) }
        } onCancel: {
            cancelled.cancel()
        }
    }

    static func seconds(_ audio: TrackAudio, cancelled: CancellationFlag) throws -> Int {
        let second = Int64(secondFrames)
        let end = max(audio.endFrame, 0)
        // Under −45 dBFS: a mean square under 10^(−4.5).
        let quiet = pow(10, Double(SilenceFinder.thresholdDBFS) / 10)
        let reader = audio.makeReader()
        var samples: [Float] = []
        var powers = [Double](repeating: 0, count: secondFrames / frameLength)
        var count = 0
        // The first second not looked at yet.
        var cursor: Int64 = 0
        for span in audio.spans {
            let first = max(cursor, max(0, span.frames.lowerBound) / second * second)
            let last = min(max(0, span.frames.upperBound), end)
            var start = first
            while start < last {
                if cancelled.isCancelled { throw CancellationError() }
                reader.read(start..<(start + second), into: &samples)
                let values = frameLength * audio.channels
                for frame in powers.indices {
                    var sum = 0.0
                    for i in (frame * values)..<((frame + 1) * values) { sum += Double(samples[i]) * Double(samples[i]) }
                    powers[frame] = sum / Double(values)
                }
                let mean = powers.reduce(0, +) / Double(powers.count)
                if mean >= quiet {
                    let low = powers.count(where: { $0 < mean / 2 })
                    if Double(low) >= lowEnergyShare * Double(powers.count) { count += 1 }
                }
                start += second
            }
            cursor = max(cursor, start)
        }
        return count
    }
}
