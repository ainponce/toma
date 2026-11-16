// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// Where the editor's playhead stands (design §5.3 and Task 14's rule): when an edit changes the sequence, and on the
/// frame grid of the project.
public enum PlayheadRule {
    /// Where output instant `output` (nanoseconds) of sequence `old` is in sequence `new`: the output time of the source
    /// instant shown there, if `new` keeps it (a change of speed, a trim or a cut elsewhere moves it with its instant);
    /// otherwise the output time of the edit point that took its place, the first instant of its take kept after it (the
    /// join of a cut, the new start of a trimmed clip, the start of the clip after a deleted one), or the end of `new`
    /// if none is. Unchanged when the sequences are the same; 0 when `old` has no output.
    public static func output(afterChange output: Int64, from old: [Clip], to new: [Clip]) -> Int64 {
        guard old != new else { return output }
        let oldMap = TimeMap(sequence: old), newMap = TimeMap(sequence: new)
        guard let (clip, source) = oldMap.source(atOutput: output) else { return 0 }
        let take = old[clip].take
        return newMap.output(atSource: source, take: take) ?? newMap.firstKeptOutput(atOrAfter: source, take: take)
            ?? newMap.duration
    }

    /// The frame of the grid at or before `seconds`, the one the preview shows playing there (`PreviewEngine`'s
    /// `.playing`), within the `frameCount` frames at `frameRate`.
    public static func frame(atOrBefore seconds: Double, frameRate: Int, frameCount: Int) -> Int {
        let n = seconds.isFinite ? Int((seconds * Double(frameRate) + 1e-6).rounded(.down)) : 0
        return min(max(n, 0), max(frameCount - 1, 0))
    }

    /// The frame of the grid nearest `seconds`, as a released drag pauses on it (`PreviewEngine.request(_:)`), within the
    /// `frameCount` frames at `frameRate`.
    public static func frame(nearest seconds: Double, frameRate: Int, frameCount: Int) -> Int {
        let n = seconds.isFinite ? Int((seconds * Double(frameRate)).rounded()) : 0
        return min(max(n, 0), max(frameCount - 1, 0))
    }
}
