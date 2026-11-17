// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The part of the output an export draws (1c design §7.1): output nanoseconds `[start, end)` of the document's
/// `TimeMap`, the whole video or the stretch between the marks.
///
/// Frame `n` of an export at `fps` frames per second is at `start + round(n / fps × 10⁹)` ns (`TimeMap.frameTime`); the
/// export's frames are those that start more than 1 ns before `end`. A range lasts at least a frame when
/// `(end − start + 1) × fps` is at least 10⁹ ns: a shorter one is not exported (`GIFExportError.rangeShorterThanAFrame`;
/// `ExportError.nothingToExport` for the MP4), though its first frame falls before its end.
///
/// The nanosecond is the rounding of the marks. They sit on the document's frame grid, each rounded to the nanosecond
/// (`TimeMap.frameTime`), so the length between two of them can be 1 ns more or less than that many frames rounded once.
/// Without it, a frame starting 1 ns before the O mark (the frame at the mark) would be exported, and some ranges of
/// exactly one frame would be refused: with it, marks `k` frames of the document apart give the frames of the export
/// that start within those `k` frames, at every rate of the document and of the export.
public struct ExportRange: Equatable, Sendable {
    public var start: Int64
    public var end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }

    /// The whole output of `timeMap`: `[0, duration)`.
    public static func whole(_ timeMap: TimeMap) -> ExportRange {
        ExportRange(start: 0, end: timeMap.duration)
    }

    /// How many frames at `fps` the range holds: the `n` from 0 whose offset `TimeMap.frameTime(n, frameRate: fps)` is
    /// more than 1 ns before `end − start`; none for an empty range.
    public func frameCount(fps: Int) -> Int {
        precondition(fps > 0, "an export of \(fps) frames per second")
        guard end > start else { return 0 }
        // A frame that starts 1 ns before the end is the frame at the end, rounded.
        let length = end - start - 1
        // About the count, then exactly: the frames' offsets grow with `n`.
        var count = max(0, Int((Double(length) * Double(fps) / 1e9).rounded(.up)))
        while count > 0, TimeMap.frameTime(count - 1, frameRate: fps) >= length { count -= 1 }
        while TimeMap.frameTime(count, frameRate: fps) < length { count += 1 }
        return count
    }

    /// The output time of frame `n` at `fps`: `start + round(n / fps × 10⁹)` ns.
    public func frameTime(_ n: Int, fps: Int) -> Int64 {
        start + TimeMap.frameTime(n, frameRate: fps)
    }

    /// Whether the range lasts at least a frame at `fps`, give or take the marks' nanosecond: `(end − start + 1) × fps ≥
    /// 10⁹` (`TimeMap.lastsAFrame`, the one rule the export sheet checks too). An export of a range that does not is
    /// refused, and the export sheet disables Export for it (1c design §7.1).
    public func lastsAFrame(fps: Int) -> Bool {
        TimeMap.lastsAFrame(start: start, end: end, frameRate: fps)
    }
}
