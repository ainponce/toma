// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Editing

/// The rows of the chapters' review sheet: each can be retitled or left out before «Add».
public struct ChapterReviewRules: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: Int
        public let start: Int64
        public var title: String
        public var included: Bool

        public init(id: Int, start: Int64, title: String, included: Bool) {
            self.id = id
            self.start = start
            self.title = title
            self.included = included
        }
    }

    public private(set) var rows: [Row]

    /// Every chapter included, in output order; the id is its position there.
    public init(_ chapters: [Chapter]) {
        rows = chapters.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .enumerated().map { Row(id: $0.offset, start: $0.element.element.start, title: $0.element.element.title, included: true) }
    }

    /// The title of row `id`, as a marker's name (trimmed, at most 100 characters).
    public mutating func setTitle(_ title: String, of id: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].title = MarkerCommands.normalized(title)
    }

    public mutating func toggle(_ id: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].included.toggle()
    }

    /// The included rows with a title.
    public var chapters: [Chapter] {
        rows.filter { $0.included && !$0.title.isEmpty }.map { Chapter(start: $0.start, title: $0.title) }
    }

    /// For «Add N chapters».
    public var count: Int { chapters.count }
}
