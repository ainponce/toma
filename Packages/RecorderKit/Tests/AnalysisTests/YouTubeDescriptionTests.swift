// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Analysis

private let second: Int64 = 1_000_000_000
private let chapters = [Chapter(start: 0, title: "Intro"), Chapter(start: 72 * second, title: "Instalar")]

@Test func summaryThenABlankLineThenChapters() {
    #expect(
        YouTubeDescription.text(summary: "Resumen.", chapters: chapters, duration: 300 * second)
            == "Resumen.\n\n00:00 Intro\n01:12 Instalar")
}

@Test func eitherAloneOrNothing() {
    #expect(YouTubeDescription.text(summary: nil, chapters: chapters, duration: 300 * second) == "00:00 Intro\n01:12 Instalar")
    #expect(YouTubeDescription.text(summary: "  ", chapters: chapters, duration: 300 * second) == "00:00 Intro\n01:12 Instalar")
    #expect(YouTubeDescription.text(summary: "Solo.", chapters: [], duration: 300 * second) == "Solo.")
    #expect(YouTubeDescription.text(summary: nil, chapters: [], duration: 300 * second) == "")
    #expect(YouTubeDescription.text(summary: " \n", chapters: [], duration: 300 * second) == "")
}
