// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis

/// The markers on the timeline's ruler and in the export (phase 3 design §8.3, 3d plan decisions 1 to 4): which flag
/// the mouse is on, when a press on one is a drag, where its name fits, and what "Chapters in the File" puts in the file.
public enum MarkerRulerRules {
    /// How far from a flag, in points, the mouse still points at it.
    public static let hitTolerance = 5.0
    /// A press that moves less than this, in points, is a click.
    public static let dragThreshold = 3.0
    /// Where a flag's name starts, right of its pole, and the space it leaves before the next flag, in points.
    public static let nameOffset = 10.0
    public static let nameGap = 2.0
    /// The least room a name is shown in (cut with "…" when it needs more); with less, the flag has no name.
    public static let minimumNameWidth = 24.0

    /// The flag `x` points at: of `flags` (their ids and the `x` the mouse is measured from), the nearest within
    /// `hitTolerance`; of two as near, the first. `nil` if none is that near.
    public static func hit(x: Double, flags: [(id: String, x: Double)]) -> String? {
        hit(x: x, flags: flags, playheadX: nil)
    }

    /// Half the width of the playhead's head, in points: a press this near its mast scrubs, whatever flag is under it
    /// (the playhead sits on a marker after a jump to it, and its head is then the whole of the flag's reach).
    public static let playheadHeadRadius = 5.5

    /// As `hit(x:flags:)`, but a press within `playheadHeadRadius` of the playhead's mast (`playheadX`, on the same
    /// scale as `x`) grabs the playhead, not a flag. A flag is still grabbed right of the head, and wherever the
    /// playhead is elsewhere.
    public static func hit(x: Double, flags: [(id: String, x: Double)], playheadX: Double?) -> String? {
        if let playheadX, abs(x - playheadX) <= playheadHeadRadius { return nil }
        var best: (id: String, distance: Double)?
        for flag in flags {
            let distance = abs(flag.x - x)
            guard distance <= hitTolerance, distance < best?.distance ?? .infinity else { continue }
            best = (flag.id, distance)
        }
        return best?.id
    }

    /// Whether the mouse, pressed at `from` and now at `to` (along the ruler), drags the flag: `dragThreshold` or more.
    public static func isDrag(from: Double, to: Double) -> Bool {
        abs(to - from) >= dragThreshold
    }

    /// The width the name of the flag whose pole is at `x` is shown in: from `nameOffset` right of it up to `nameGap`
    /// before the next flag's pole `nextX`, or before the end of the area (`areaWidth`); `nil` if that is under
    /// `minimumNameWidth`.
    public static func nameRoom(x: Double, nextX: Double?, areaWidth: Double) -> Double? {
        let end = min(nextX ?? areaWidth, areaWidth) - nameGap
        let room = end - (x + nameOffset)
        return room >= minimumNameWidth ? room : nil
    }

    /// Whether the export sheet offers "Chapters in the File" (decision 4): for a video (MP4 or MOV) with chapters, the
    /// markers with a name the output shows.
    public static func offersChaptersInFile(kind: ExportKind, chapters: [Chapter]) -> Bool {
        kind == .mp4 && !chapters.isEmpty
    }

    /// What the export's settings carry of `chapters` (`ExportSettings.chapters` and `chapterLanguage`): all of them, in
    /// the app's language, when the sheet offers them and "Chapters in the File" is on; none otherwise. The language is
    /// the first of `localizations` (the app's, `Bundle.main.preferredLocalizations`) that names one ("Base" does not):
    /// the titles are in it, the intro's too, and a chapter track without a language (`und`) is not found by a player
    /// that looks for chapters in its viewer's languages.
    public static func fileChapters(
        _ chapters: [Chapter], kind: ExportKind, isOn: Bool, localizations: [String]
    ) -> (chapters: [Chapter], language: String?) {
        guard isOn, offersChaptersInFile(kind: kind, chapters: chapters) else { return ([], nil) }
        let language = localizations.first { !$0.isEmpty && $0.caseInsensitiveCompare("Base") != .orderedSame }
        return (chapters, language)
    }
}
