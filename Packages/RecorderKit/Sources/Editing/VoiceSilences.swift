// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The silences of the output where the camera can be hidden (phase 2 plan decision 9, design §5.8): from the words
/// that stay, or, without a transcript, from the stretches of the microphone that are quiet. All in output nanoseconds.
public enum VoiceSilences {
    /// The shortest silence worth hiding the camera in: 3 s.
    public static let minimumSilence: Int64 = 3_000_000_000
    /// What each side of a silence keeps showing the camera: 0.5 s.
    public static let margin: Int64 = 500_000_000

    /// The silences between the words that stay, from the start of the output to the first and from the last to the end
    /// of it included, at least `minimumSilence` long. `[]` without a transcript or without words that stay.
    public static func fromWords(_ doc: EditDocument, timeMap: TimeMap) -> [Range<Int64>] {
        let words = TranscriptTiming.keptWords(of: doc, timeMap: timeMap)
        guard !words.isEmpty else { return [] }
        var gaps: [Range<Int64>] = []
        var spoken: Int64 = 0
        for word in words {
            if word.output.lowerBound > spoken { gaps.append(spoken..<word.output.lowerBound) }
            spoken = max(spoken, word.output.upperBound)
        }
        if timeMap.duration > spoken { gaps.append(spoken..<timeMap.duration) }
        return gaps.filter { $0.upperBound - $0.lowerBound >= minimumSilence }
    }

    /// The quiet stretches of `take`'s microphone `spans` (source time) in the output, each with the cuts inside it
    /// closed, the ones that overlap or touch joined, in order, at least `minimumSilence` long.
    public static func fromQuiet(_ spans: [Range<HostTime>], take: String, timeMap: TimeMap) -> [Range<Int64>] {
        let outputs = spans.compactMap { timeMap.outputRange(ofSource: $0, take: take) }
            .filter { !$0.isEmpty }
            .sorted { ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound) }
        var merged: [Range<Int64>] = []
        for range in outputs {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged.filter { $0.upperBound - $0.lowerBound >= minimumSilence }
    }

    /// The step that hides the camera (a Screen Only block) in each of `silences` that lasts at least `minimumSilence`,
    /// shrunk `margin` on each side and cut to the free space of the Camera track, in one step. `nil` if no block fits.
    public static func hideCamera(
        _ doc: EditDocument, silences: [Range<Int64>], timeMap: TimeMap, makeID: (String) -> String
    ) -> EditStep? {
        let shrunk = silences.filter { $0.upperBound - $0.lowerBound >= minimumSilence }
            .map { ($0.lowerBound + margin)..<($0.upperBound - margin) }
        return LayoutCommands.addBlocks(
            doc, kind: .screenOnly, outputs: shrunk, label: .cameraHideSilences, timeMap: timeMap, makeID: makeID)
    }
}
