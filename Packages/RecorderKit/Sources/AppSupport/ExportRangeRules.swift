// SPDX-License-Identifier: GPL-3.0-or-later

/// The export sheet's Range (1c design §7.1): the whole video, or the stretch between the timeline's marks, as output
/// nanoseconds `[start, end)` of the document's `TimeMap`. The app makes the `ExportRange` the exporters take from it.
public enum ExportRangeRules {
    /// What "Between the Marks" exports: from the in mark to the out (`TimelineMarks.range`), cut to the video,
    /// `[0, duration)`; `nil` without both marks. Marks an edit left past the end leave nothing, at the end: a range that
    /// does not last a frame.
    public static func markedRange(_ marks: TimelineMarks, duration: Int64) -> Range<Int64>? {
        marks.range.map { cut($0, duration: duration) }
    }

    /// The range the sheet starts at for `kind`: for a GIF, the marked range (`marks`) if there is one; for an MP4, and
    /// without marks, the whole video, `[0, duration)`. The range is never remembered.
    public static func defaultRange(kind: ExportKind, marks: Range<Int64>?, duration: Int64) -> Range<Int64> {
        switch (kind, marks) {
        case (.gif, let marks?): cut(marks, duration: duration)
        case (.gif, nil), (.mp4, _): 0..<max(0, duration)
        }
    }

    /// Whether `range` lasts at least a frame at `fps`, give or take the marks' nanosecond: `(end − start + 1) × fps ≥
    /// 10⁹`, the rule the exporters check (`ExportRange.lastsAFrame(fps:)`, which the sheet asks). A shorter one is
    /// not exported, and the sheet disables Export: "The range has to last at least one frame."
    public static func canExport(_ range: Range<Int64>, fps: Int) -> Bool {
        guard fps > 0, !range.isEmpty else { return false }
        // (end − start + 1) × fps ≥ 10⁹, without the + 1 overflowing.
        let (product, overflow) = (range.upperBound - range.lowerBound).multipliedReportingOverflow(by: Int64(fps))
        return overflow || product >= 1_000_000_000 - Int64(fps)
    }

    /// `range` within `[0, duration)`; empty at the nearer end if it is all outside.
    private static func cut(_ range: Range<Int64>, duration: Int64) -> Range<Int64> {
        let end = max(0, duration)
        let lower = min(max(range.lowerBound, 0), end)
        return lower..<max(lower, min(range.upperBound, end))
    }
}
