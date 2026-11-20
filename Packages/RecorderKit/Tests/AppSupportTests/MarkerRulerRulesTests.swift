// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppSupport
import Testing

@Suite struct MarkerRulerRulesTests {
    @Test func flagHitWithinFivePoints() {
        let flags: [(id: String, x: Double)] = [("a", 100), ("b", 200)]
        #expect(MarkerRulerRules.hit(x: 104, flags: flags) == "a")
        #expect(MarkerRulerRules.hit(x: 96, flags: flags) == "a")
        #expect(MarkerRulerRules.hit(x: 105, flags: flags) == "a")
        #expect(MarkerRulerRules.hit(x: 106, flags: flags) == nil)
        #expect(MarkerRulerRules.hit(x: 94, flags: flags) == nil)
        #expect(MarkerRulerRules.hit(x: 150, flags: flags) == nil)
        #expect(MarkerRulerRules.hit(x: 10, flags: []) == nil)
        // Two near: the nearest; as near, the first.
        let near: [(id: String, x: Double)] = [("a", 100), ("b", 104)]
        #expect(MarkerRulerRules.hit(x: 101, flags: near) == "a")
        #expect(MarkerRulerRules.hit(x: 103, flags: near) == "b")
        #expect(MarkerRulerRules.hit(x: 102, flags: near) == "a")
        #expect(MarkerRulerRules.hit(x: 108, flags: near) == "b")
    }

    @Test func aSmallMoveIsAClick() {
        #expect(!MarkerRulerRules.isDrag(from: 100, to: 102))
        #expect(!MarkerRulerRules.isDrag(from: 100, to: 98))
        #expect(MarkerRulerRules.isDrag(from: 100, to: 104))
        #expect(MarkerRulerRules.isDrag(from: 100, to: 96))
        #expect(MarkerRulerRules.isDrag(from: 100, to: 103))
        #expect(!MarkerRulerRules.isDrag(from: 100, to: 100))
    }

    @Test func theNameShowsWhereItFits() {
        // Beside the flag, up to the next one (2 pt before it) or the end of the area.
        #expect(MarkerRulerRules.nameRoom(x: 100, nextX: 200, areaWidth: 1000) == 88)
        #expect(MarkerRulerRules.nameRoom(x: 100, nextX: nil, areaWidth: 300) == 188)
        #expect(MarkerRulerRules.nameRoom(x: 100, nextX: 2000, areaWidth: 300) == 188)
        // Less than a short word: no name.
        #expect(MarkerRulerRules.nameRoom(x: 100, nextX: 130, areaWidth: 1000) == nil)
        #expect(MarkerRulerRules.nameRoom(x: 100, nextX: nil, areaWidth: 120) == nil)
        #expect(MarkerRulerRules.nameRoom(x: 100, nextX: 136, areaWidth: 1000) == 24)
    }

    @Test func chaptersInTheFileOnlyForAVideoWithChapters() {
        let chapters = [Chapter(start: 0, title: "Intro"), Chapter(start: 12_000_000_000, title: "Demo")]
        #expect(MarkerRulerRules.offersChaptersInFile(kind: .mp4, chapters: chapters))
        #expect(!MarkerRulerRules.offersChaptersInFile(kind: .gif, chapters: chapters))
        #expect(!MarkerRulerRules.offersChaptersInFile(kind: .mp4, chapters: []))
    }

    /// The chapter track says the language of its titles (the app's): a track without one (`und`) is not found by a player
    /// that looks for chapters in its viewer's languages.
    @Test func chaptersInTheFileCarryTheAppsLanguage() {
        let chapters = [Chapter(start: 0, title: "Introducción"), Chapter(start: 12_000_000_000, title: "Demo")]
        let spanish = MarkerRulerRules.fileChapters(chapters, kind: .mp4, isOn: true, localizations: ["es", "en"])
        #expect(spanish.chapters == chapters)
        #expect(spanish.language == "es")
        let english = MarkerRulerRules.fileChapters(chapters, kind: .mp4, isOn: true, localizations: ["en"])
        #expect(english.language == "en")
        // "Base" names no language: the next one does.
        #expect(MarkerRulerRules.fileChapters(chapters, kind: .mp4, isOn: true, localizations: ["Base", "es"]).language == "es")
        #expect(MarkerRulerRules.fileChapters(chapters, kind: .mp4, isOn: true, localizations: ["Base"]).language == nil)
        #expect(MarkerRulerRules.fileChapters(chapters, kind: .mp4, isOn: true, localizations: []).language == nil)
        // Off, for a GIF or without chapters: none, and no language.
        for (kind, isOn, list) in [(ExportKind.mp4, false, chapters), (.gif, true, chapters), (.mp4, true, [])] {
            let none = MarkerRulerRules.fileChapters(list, kind: kind, isOn: isOn, localizations: ["es"])
            #expect(none.chapters.isEmpty)
            #expect(none.language == nil)
        }
    }
}
