// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// A chapter: from `start` ns of the output, up to the next one.
public struct Chapter: Equatable, Sendable {
    public var start: Int64
    public var title: String

    public init(start: Int64, title: String) {
        self.start = start
        self.title = title
    }
}

/// The chapters of an output (`chapters-1`, phase 3 plan 3d, decisions 4 and 5): the markers with a name that show, as
/// the text of YouTube and the track of the MP4 and the MOV read them.
public enum Chapters {
    public static let id = "chapters-1"
    private static let second: Int64 = 1_000_000_000

    /// One chapter per marker with a name, by output, in whole seconds rounded down; of two in the same second, the first.
    /// The first of the markers in the first second is the one at 0; if there is none and there are chapters, `introTitle`
    /// opens at 0. A chapter that starts at or after `duration` is left out. No named marker, no chapters.
    public static func list(_ markers: [VisibleMarker], duration: Int64, introTitle: String) -> [Chapter] {
        var chapters: [Chapter] = []
        for marker in markers.sorted(by: { ($0.output, $0.id) < ($1.output, $1.id) }) where !marker.name.isEmpty {
            let start = max(marker.output, 0) / second * second
            guard start < duration, chapters.last?.start != start else { continue }
            chapters.append(Chapter(start: start, title: marker.name))
        }
        if let first = chapters.first, first.start != 0 {
            chapters.insert(Chapter(start: 0, title: introTitle), at: 0)
        }
        return chapters
    }

    /// The text for YouTube's description, a line per chapter: `MM:SS title`, or `H:MM:SS title` on every line if the
    /// video lasts `duration` of an hour or more.
    public static func youTubeText(_ chapters: [Chapter], duration: Int64) -> String {
        let hours = duration / second >= 3600
        return chapters.map { chapter in
            let total = max(chapter.start, 0) / second
            let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
            let clock = hours ? "\(h):\(two(m)):\(two(s))" : "\(two(total / 60)):\(two(s))"
            let title = chapter.title.split(whereSeparator: \.isNewline).joined(separator: " ")
            return "\(clock) \(title)"
        }.joined(separator: "\n")
    }

    /// The chapters of the output range `range`, as the file of that range has them: the one in force at its start is at 0,
    /// the ones inside it shifted by the start, the ones from its end on left out.
    public static func within(_ chapters: [Chapter], range: Range<Int64>) -> [Chapter] {
        var result: [Chapter] = []
        let inForce = chapters.last { $0.start <= range.lowerBound }
        if let inForce { result.append(Chapter(start: 0, title: inForce.title)) }
        for chapter in chapters where chapter.start > range.lowerBound && chapter.start < range.upperBound {
            result.append(Chapter(start: chapter.start - range.lowerBound, title: chapter.title))
        }
        return result
    }

    private static func two(_ n: Int64) -> String { n < 10 ? "0\(n)" : "\(n)" }
}
