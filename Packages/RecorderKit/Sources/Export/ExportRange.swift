// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The part of the output an export draws (1c design §7.1): output nanoseconds `[start, end)` of the document's
/// `TimeMap`, the whole video or the stretch between the marks.
///
/// Frame `n` of an export at `fps` frames per second is at `start + round(n / fps × 10⁹)` ns (`TimeMap.frameTime`); the
/// export's frames are those that fall before `end`. A range lasts at least a frame when `(end − start) × fps` is at
/// least 10⁹ ns: a shorter one is not exported (`GIFExportError.rangeShorterThanAFrame`), though its first frame falls
/// before its end.
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

    /// How many frames at `fps` fall before `end`: the `n` from 0 with `frameTime(n, fps:)` before it; none for an empty
    /// range.
    public func frameCount(fps: Int) -> Int {
        precondition(fps > 0, "an export of \(fps) frames per second")
        guard end > start else { return 0 }
        let length = end - start
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

    /// Whether the range lasts at least a frame at `fps`: `(end − start) × fps ≥ 10⁹`.
    func lastsAFrame(fps: Int) -> Bool {
        guard fps > 0, end > start else { return false }
        let (product, overflow) = (end - start).multipliedReportingOverflow(by: Int64(fps))
        return overflow || product >= 1_000_000_000
    }
}
