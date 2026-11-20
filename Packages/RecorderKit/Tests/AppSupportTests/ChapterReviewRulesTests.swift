// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

import Analysis

@testable import AppSupport

private let chapters = [Chapter(start: 0, title: "A"), Chapter(start: 10, title: "B"), Chapter(start: 20, title: "C")]

@Test func excludedAndEmptyRowsAreNotAdded() {
    var rules = ChapterReviewRules(chapters)
    #expect(rules.count == 3)
    rules.toggle(1)
    rules.setTitle(" ", of: 2)
    #expect(rules.chapters == [Chapter(start: 0, title: "A")])
    #expect(rules.count == 1)
    rules.toggle(1)
    #expect(rules.count == 2)
}

@Test func titlesAreBoundedLikeMarkers() {
    var rules = ChapterReviewRules(chapters)
    rules.setTitle(String(repeating: "t", count: 150), of: 0)
    #expect(rules.rows[0].title.count == 100)
}

@Test func rowsAreInOutputOrderWithTheirPosition() {
    let rules = ChapterReviewRules([Chapter(start: 20, title: "C"), Chapter(start: 0, title: "A")])
    #expect(rules.rows.map(\.id) == [0, 1])
    #expect(rules.rows.map(\.title) == ["A", "C"])
    #expect(rules.rows.allSatisfy { $0.included })
}
