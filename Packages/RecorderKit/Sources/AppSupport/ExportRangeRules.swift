// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

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

    /// Whether `range` lasts at least a frame at `fps`, give or take the marks' nanosecond: `TimeMap.lastsAFrame`, the one
    /// rule the exporters check too (`ExportRange.lastsAFrame(fps:)`). A shorter range is not exported, and the sheet
    /// disables Export: "The range has to last at least one frame."
    public static func canExport(_ range: Range<Int64>, fps: Int) -> Bool {
        TimeMap.lastsAFrame(start: range.lowerBound, end: range.upperBound, frameRate: fps)
    }

    /// What the exporter draws of `range` of a video of `duration` ns, as `kind` at `fps`: `nil` for the MP4 of all of it,
    /// 1b's export, which is never cut nor refused (a frame at least); for the MP4 of a part, the range cut, as
    /// `MP4Exporter` cuts it, to where the export of all of it ends (`TimeMap.exportEnd`, its last whole frame, up to half
    /// a frame before the video's end); for a GIF, the range itself.
    public static func exported(kind: ExportKind, range: Range<Int64>, duration: Int64, fps: Int) -> Range<Int64>? {
        switch kind {
        case .gif:
            return range
        case .mp4:
            guard range != 0..<duration else { return nil }
            let end = min(range.upperBound, TimeMap.exportEnd(duration: duration, frameRate: fps))
            let start = min(max(range.lowerBound, 0), end)
            return start..<end
        }
    }

    /// Whether the sheet can export `range` as `kind` at `fps`: what the exporter draws of it (`exported`) lasts at least
    /// a frame (`canExport(_:fps:)`). Export is disabled otherwise.
    public static func canExport(kind: ExportKind, range: Range<Int64>, duration: Int64, fps: Int) -> Bool {
        exported(kind: kind, range: range, duration: duration, fps: fps).map { canExport($0, fps: fps) } ?? true
    }

    /// `range` within `[0, duration)`; empty at the nearer end if it is all outside.
    private static func cut(_ range: Range<Int64>, duration: Int64) -> Range<Int64> {
        let end = max(0, duration)
        let lower = min(max(range.lowerBound, 0), end)
        return lower..<max(lower, min(range.upperBound, end))
    }
}
