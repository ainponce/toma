// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat

/// What `toma ai chapters` and the MCP tool `suggest_chapters` give (plan 5b, Task I4): the chapters proposed and the
/// commands that would add them. Nothing here edits the project: whoever reads it applies the `commands` (`toma edit`,
/// `apply_commands`) once it has looked at them.
public struct ChapterReport: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        /// Seconds of the output.
        public var at: Double
        /// `m:ss`, or `h:mm:ss` when the video lasts an hour or more.
        public var time: String
        public var title: String

        public init(at: Double, time: String, title: String) {
            self.at = at
            self.time = time
            self.title = title
        }
    }

    public var language: String
    public var chapters: [Item]
    /// Parts of the transcript the model declined or could not read, so their chapters are missing.
    public var skippedParts: Int
    /// `{"command": "addMarker", "at": <s>, "name": <title>}`, one per chapter, in order.
    public var commands: [JSONValue]

    /// The report of `suggestions` for an output of `duration` nanoseconds.
    public init(_ suggestions: ChapterSuggestions, duration: Int64) {
        let hours = duration >= 3600 * 1_000_000_000
        language = suggestions.language
        skippedParts = suggestions.skippedParts
        chapters = suggestions.chapters.map { chapter in
            let at = Double(max(chapter.output, 0) / 1_000_000) / 1000
            return Item(at: at, time: Self.clock(chapter.output, hours: hours), title: chapter.title)
        }
        commands = chapters.map { item in
            .object(["command": .string("addMarker"), "at": .number(item.at), "name": .string(item.title)])
        }
    }

    /// One line per chapter, as the description of a YouTube video has them (`Chapters.youTubeText`).
    public var text: String {
        let hours = chapters.contains { $0.time.split(separator: ":").count == 3 }
        let duration: Int64 = hours ? 3600 * 1_000_000_000 : 0
        return Chapters.youTubeText(
            chapters.map { Chapter(start: Int64(($0.at * 1e9).rounded()), title: $0.title) }, duration: duration)
    }

    private static func clock(_ nanoseconds: Int64, hours: Bool) -> String {
        let total = Int(max(nanoseconds, 0) / 1_000_000_000)
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return hours ? "\(h):\(two(m)):\(two(s))" : "\(total / 60):\(two(s))"
    }
}

/// What `toma ai title` and `toma ai summary` give: the text proposed and the command that would set it.
public struct InfoReport: Codable, Equatable, Sendable {
    /// `"title"` or `"summary"`.
    public var kind: String
    public var text: String
    /// `{"command": "setTitle", "title": …}` or `{"command": "setSummary", "summary": …}`.
    public var command: JSONValue

    public init(kind: InfoKind, text: String) {
        self.kind = kind == .title ? "title" : "summary"
        self.text = text
        command =
            kind == .title
            ? .object(["command": .string("setTitle"), "title": .string(text)])
            : .object(["command": .string("setSummary"), "summary": .string(text)])
    }
}
