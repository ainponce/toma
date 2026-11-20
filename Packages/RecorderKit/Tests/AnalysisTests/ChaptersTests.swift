// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

import ProjectFormat

@testable import Analysis

private func ns(_ s: Double) -> Int64 { MarkerFixtures.ns(s) }

@Test func onlyNamedMarkersAreChapters() {
    let markers = [MarkerFixtures.marker(30, "B", id: "m-2"), MarkerFixtures.marker(10, "", id: "m-1"), MarkerFixtures.marker(5, "A", id: "m-0")]
    let chapters = Chapters.list(markers, duration: ns(60), introTitle: "Intro")
    #expect(chapters == [Chapter(start: 0, title: "Intro"), Chapter(start: ns(5), title: "A"), Chapter(start: ns(30), title: "B")])
    #expect(Chapters.list([MarkerFixtures.marker(5, "", id: "m-1")], duration: ns(60), introTitle: "Intro").isEmpty)
}

@Test func youTubeTextStartsAtZeroAndRises() {
    let first = Chapters.list([MarkerFixtures.marker(0.4, "A", id: "m-1"), MarkerFixtures.marker(65.9, "B", id: "m-2")], duration: ns(120), introTitle: "Intro")
    #expect(Chapters.youTubeText(first, duration: ns(120)) == "00:00 A\n01:05 B")
    let later = Chapters.list([MarkerFixtures.marker(5, "A", id: "m-1")], duration: ns(120), introTitle: "Intro")
    #expect(Chapters.youTubeText(later, duration: ns(120)) == "00:00 Intro\n00:05 A")
    // Two in the same second: the first.
    let same = Chapters.list([MarkerFixtures.marker(5.2, "A", id: "m-1"), MarkerFixtures.marker(5.7, "B", id: "m-2")], duration: ns(120), introTitle: "Intro")
    #expect(same.map(\.title) == ["Intro", "A"])
    // Starts rise.
    #expect(zip(first, first.dropFirst()).allSatisfy { $0.start < $1.start })
}

@Test func hoursChangeEveryLine() {
    let duration = ns(3600 + 120)
    let chapters = Chapters.list([MarkerFixtures.marker(3665, "Late", id: "m-1")], duration: duration, introTitle: "Intro")
    #expect(Chapters.youTubeText(chapters, duration: duration) == "0:00:00 Intro\n1:01:05 Late")
    #expect(Chapters.youTubeText(chapters, duration: ns(3599)) == "00:00 Intro\n61:05 Late")
}

@Test func withinARangeShiftsAndKeepsTheOneInForce() {
    let chapters = [Chapter(start: 0, title: "0"), Chapter(start: ns(30), title: "30"), Chapter(start: ns(80), title: "80")]
    #expect(Chapters.within(chapters, range: ns(10)..<ns(70)) == [Chapter(start: 0, title: "0"), Chapter(start: ns(20), title: "30")])
    #expect(Chapters.within(chapters, range: ns(30)..<ns(90)) == [Chapter(start: 0, title: "30"), Chapter(start: ns(50), title: "80")])
}

@Test func aChapterAtOrAfterTheEndIsLeftOut() {
    let chapters = Chapters.list([MarkerFixtures.marker(10, "Gone", id: "m-1")], duration: ns(10), introTitle: "Intro")
    #expect(chapters.isEmpty)
}
