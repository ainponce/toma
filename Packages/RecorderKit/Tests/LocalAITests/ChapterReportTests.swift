// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat
import Testing

@testable import LocalAI

@Suite struct ChapterReportTests {
    private func suggestions(_ chapters: [(Double, String)], language: String = "es-MX", skipped: Int = 0) -> ChapterSuggestions {
        ChapterSuggestions(
            chapters: chapters.map {
                ChapterSuggestion(output: AIFixtures.ns($0.0), title: $0.1, word: TranscriptWordRef(take: 0, word: 0))
            }, parts: 2, skippedParts: skipped, language: language)
    }

    @Test func reportHasSecondsTimesAndAddMarkerCommands() {
        let report = ChapterReport(suggestions([(0, "Intro"), (72.5, "Después")]), duration: AIFixtures.ns(300))
        #expect(report.chapters.map(\.at) == [0, 72.5])
        #expect(report.chapters.map(\.time) == ["0:00", "1:12"])
        #expect(report.chapters.map(\.title) == ["Intro", "Después"])
        #expect(report.language == "es-MX")
        #expect(
            report.commands == [
                .object(["command": .string("addMarker"), "at": .number(0), "name": .string("Intro")]),
                .object(["command": .string("addMarker"), "at": .number(72.5), "name": .string("Después")]),
            ])
        #expect(report.text == "00:00 Intro\n01:12 Después")
    }

    @Test func reportOfAnHourUsesHours() {
        let report = ChapterReport(suggestions([(0, "A"), (3725, "B")]), duration: AIFixtures.ns(3720 + 60))
        #expect(report.chapters.map(\.time) == ["0:00:00", "1:02:05"])
        #expect(report.text == "0:00:00 A\n1:02:05 B")
    }

    @Test func reportRoundTripsAsJSON() throws {
        let report = ChapterReport(suggestions([(0, "Intro"), (72.5, "Dos")], skipped: 1), duration: AIFixtures.ns(200))
        let data = try ProjectJSON.encoder().encode(report)
        #expect(try ProjectJSON.decoder().decode(ChapterReport.self, from: data) == report)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["language", "chapters", "skippedParts", "commands"])
        #expect(object["skippedParts"] as? Int == 1)
    }

    @Test func infoReportCarriesItsCommand() throws {
        let title = InfoReport(kind: .title, text: "Cómo instalar")
        #expect(title.kind == "title")
        #expect(title.command == .object(["command": .string("setTitle"), "title": .string("Cómo instalar")]))
        let summary = InfoReport(kind: .summary, text: "Dos frases. Y otra.")
        #expect(summary.kind == "summary")
        #expect(summary.command == .object(["command": .string("setSummary"), "summary": .string("Dos frases. Y otra.")]))
        let data = try ProjectJSON.encoder().encode(summary)
        #expect(try ProjectJSON.decoder().decode(InfoReport.self, from: data) == summary)
    }
}
