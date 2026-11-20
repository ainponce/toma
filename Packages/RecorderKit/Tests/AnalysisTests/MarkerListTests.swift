// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

import ProjectFormat

@testable import Analysis

/// Two clips of `take-001` [0, 2) and [3, 5) s and one of `take-002` [0, 1) s: output 0–2, 2–4, 4–5 s.
enum MarkerFixtures {
    static let base = HostTime(nanoseconds: 100_000_000_000)
    static func at(_ s: Double) -> HostTime { base.adding(seconds: s) }
    static func ns(_ s: Double) -> Int64 { Int64((s * 1e9).rounded()) }

    static func clips() -> [Clip] {
        [
            Clip(id: "c-00000001", take: "take-001", start: at(0), end: at(2), speed: 1),
            Clip(id: "c-00000002", take: "take-001", start: at(3), end: at(5), speed: 1),
            Clip(id: "c-00000003", take: "take-002", start: at(0), end: at(1), speed: 1),
        ]
    }

    static let recorded: MarkerList.Recorded = [
        "take-001": [at(1), at(3.5)], "take-002": [at(0.5)],
    ]

    static func document(_ items: [Marker] = [], sequence: [Clip]? = nil) -> EditDocument {
        EditDocument(
            documentVersion: 4, logSequence: 0, aspect: .landscape, frameRate: 60, sequence: sequence ?? clips(),
            screens: ScreenPlan(initial: [:], changes: []), style: DefaultStyle.toma.style, cursor: DefaultStyle.toma.cursor,
            zoom: ZoomPlan(show: true, auto: DefaultStyle.toma.zoomAuto, spring: DefaultStyle.toma.zoomSpring, motionBlur: 0, regions: [], suppressed: []),
            camera: CameraPlan(show: true, initial: [:], changes: []), audio: AudioPlan(limiter: false, tracks: [:]),
            markers: MarkerPlan(items: items))
    }

    static func visible(_ document: EditDocument) -> [VisibleMarker] {
        MarkerList.visible(document: document, recorded: recorded, timeMap: TimeMap(sequence: document.sequence))
    }

    static func marker(_ output: Double, _ name: String = "x", id: String? = nil) -> VisibleMarker {
        VisibleMarker(
            id: id ?? "m-\(output)", entryID: id, take: "take-001", t: at(output), name: name, origin: .added, output: ns(output))
    }
}

@Test func recordedMarkersShowWithoutEntries() {
    let shown = MarkerFixtures.visible(MarkerFixtures.document())
    #expect(shown.map(\.output) == [1, 2.5, 4.5].map(MarkerFixtures.ns))
    #expect(shown.allSatisfy { $0.name.isEmpty && $0.origin == .recorded && $0.entryID == nil })
    #expect(shown[0].id == "rec-take-001-\(MarkerFixtures.at(1).nanoseconds)")
    #expect(shown.map(\.take) == ["take-001", "take-001", "take-002"])
}

@Test func cutHidesAndRestoreShowsAgain() {
    let named = Marker(id: "m-00000001", take: "take-001", t: MarkerFixtures.at(1), name: "Intro", origin: .recorded)
    let cut = [
        Clip(id: "c-00000001", take: "take-001", start: MarkerFixtures.at(0), end: MarkerFixtures.at(0.5), speed: 1),
        Clip(id: "c-00000002", take: "take-001", start: MarkerFixtures.at(1.5), end: MarkerFixtures.at(2), speed: 1),
    ]
    let hidden = MarkerFixtures.visible(MarkerFixtures.document([named], sequence: cut))
    #expect(!hidden.contains { $0.name == "Intro" })
    let restored = MarkerFixtures.visible(MarkerFixtures.document([named]))
    #expect(restored.first { $0.name == "Intro" }?.output == MarkerFixtures.ns(1))
    #expect(restored.filter { $0.t == MarkerFixtures.at(1) }.count == 1)
}

@Test func markersOfTwoTakesAreKeptApart() {
    let same = MarkerFixtures.at(0.5)
    let recorded: MarkerList.Recorded = ["take-001": [same], "take-002": [same]]
    let document = MarkerFixtures.document()
    let shown = MarkerList.visible(document: document, recorded: recorded, timeMap: TimeMap(sequence: document.sequence))
    #expect(shown.count == 2)
    #expect(shown.map(\.output) == [0.5, 4.5].map(MarkerFixtures.ns))
    #expect(Set(shown.map(\.id)).count == 2)
}

@Test func aMarkerOnAFreezePointShowsAtItsStart() {
    let sequence = [
        Clip(id: "c-00000001", take: "take-001", start: MarkerFixtures.at(0), end: MarkerFixtures.at(1), speed: 1),
        Clip(id: "c-00000002", take: "take-001", start: MarkerFixtures.at(1), end: MarkerFixtures.at(1), speed: 1, content: .freeze(duration: MarkerFixtures.ns(2))),
        Clip(id: "c-00000003", take: "take-001", start: MarkerFixtures.at(1), end: MarkerFixtures.at(3), speed: 1),
    ]
    let document = MarkerFixtures.document(sequence: sequence)
    let shown = MarkerList.visible(document: document, recorded: ["take-001": [MarkerFixtures.at(1)]], timeMap: TimeMap(sequence: sequence))
    // The frozen frame shows the instant from its start, before the stretch that starts there.
    #expect(shown.map(\.output) == [MarkerFixtures.ns(1)])
}

/// A title card or a frozen frame of `take-001` at its point: at the start of the output, splitting a stretch, at the end
/// of the output, and a frozen frame at the end of a stretch with a cut after it. Each with the output where it starts.
enum PointFixtures {
    static func card(_ id: String, at s: Double) -> Clip {
        Clip(
            id: id, take: "take-001", start: MarkerFixtures.at(s), end: MarkerFixtures.at(s), speed: 1,
            content: .card(TitleCard(title: "Capítulo 2", style: .centered, background: .stage), duration: MarkerFixtures.ns(3)))
    }

    static func stretch(_ id: String, _ start: Double, _ end: Double) -> Clip {
        Clip(id: id, take: "take-001", start: MarkerFixtures.at(start), end: MarkerFixtures.at(end), speed: 1)
    }

    /// (the sequence, the point, where the point's clip starts in the output, in s)
    static let cases: [(sequence: [Clip], point: Double, start: Double)] = [
        // Card 0–3 s, then the stretch that starts at its point, 3–7 s.
        ([card("c-00000001", at: 0), stretch("c-00000002", 0, 4)], 0, 0),
        // 0–2 s, the card 2–5 s, and the rest of the stretch it split, 5–7 s.
        ([stretch("c-00000001", 0, 2), card("c-00000002", at: 2), stretch("c-00000003", 2, 4)], 2, 2),
        // 0–2 s and the card at the end, 2–5 s: no stretch starts at its point.
        ([stretch("c-00000001", 0, 2), card("c-00000002", at: 2)], 2, 2),
        // 0–2 s, the frozen frame of its end 2–4 s, and after a cut 4–6 s: no stretch starts at its point.
        ([
            stretch("c-00000001", 0, 2),
            Clip(
                id: "c-00000002", take: "take-001", start: MarkerFixtures.at(2), end: MarkerFixtures.at(2), speed: 1,
                content: .freeze(duration: MarkerFixtures.ns(2))),
            stretch("c-00000003", 3, 5),
        ], 2, 2),
    ]
}

@Test(arguments: PointFixtures.cases.indices)
func aMarkerOnACardOrAFreezeShowsAtItsStart(index: Int) {
    let (sequence, point, start) = PointFixtures.cases[index]
    let added = Marker(id: "m-00000001", take: "take-001", t: MarkerFixtures.at(point), name: "Capítulo 2", origin: .added)
    let document = MarkerFixtures.document([added], sequence: sequence)
    let map = TimeMap(sequence: sequence)
    let shown = MarkerList.visible(document: document, recorded: [:], timeMap: map)
    #expect(shown.map(\.output) == [MarkerFixtures.ns(start)])
    let chapters = Chapters.list(shown, duration: map.duration, introTitle: "Intro")
    #expect(chapters.last == Chapter(start: MarkerFixtures.ns(start), title: "Capítulo 2"))
    #expect(chapters.count == (start == 0 ? 1 : 2))
    // A recorded marker at the point shows there too.
    let recorded = MarkerList.visible(
        document: MarkerFixtures.document(sequence: sequence), recorded: ["take-001": [MarkerFixtures.at(point)]], timeMap: map)
    #expect(recorded.map(\.output) == [MarkerFixtures.ns(start)])
}

@Test func hiddenEntriesAndAddedEntries() {
    let hidden = Marker(id: "m-00000001", take: "take-001", t: MarkerFixtures.at(1), origin: .recorded, hidden: true)
    let added = Marker(id: "m-00000002", take: "take-002", t: MarkerFixtures.at(0.25), name: "Mine", origin: .added)
    let shown = MarkerFixtures.visible(MarkerFixtures.document([hidden, added]))
    #expect(shown.map(\.output) == [2.5, 4.25, 4.5].map(MarkerFixtures.ns))
    #expect(shown[1].name == "Mine" && shown[1].origin == .added && shown[1].entryID == "m-00000002")
}

@Test func neighborsSkipTheOneUnderThePlayhead() {
    let shown = MarkerFixtures.visible(MarkerFixtures.document())
    let frameCount = TimeMap(sequence: MarkerFixtures.document().sequence).frameCount(frameRate: 60)
    #expect(MarkerList.neighbor(of: 60, forward: true, in: shown, frameRate: 60, frameCount: frameCount)?.output == MarkerFixtures.ns(2.5))
    #expect(MarkerList.neighbor(of: 150, forward: false, in: shown, frameRate: 60, frameCount: frameCount)?.output == MarkerFixtures.ns(1))
    #expect(MarkerList.neighbor(of: 60, forward: false, in: shown, frameRate: 60, frameCount: frameCount) == nil)
    #expect(MarkerList.neighbor(of: 270, forward: true, in: shown, frameRate: 60, frameCount: frameCount) == nil)
    #expect(MarkerList.at(frame: 150, in: shown, frameRate: 60, frameCount: frameCount)?.output == MarkerFixtures.ns(2.5))
    #expect(MarkerList.at(frame: 151, in: shown, frameRate: 60, frameCount: frameCount) == nil)
}

@Test func recordedInstantsAreInOrderWithoutRepeats() {
    let events = [
        InputEvent(t: MarkerFixtures.at(2), kind: .marker), InputEvent(t: MarkerFixtures.at(1), kind: .cursor(x: 0, y: 0)),
        InputEvent(t: MarkerFixtures.at(2), kind: .marker), InputEvent(t: MarkerFixtures.at(3), kind: .marker),
    ]
    #expect(MarkerList.recordedInstants(in: events) == [MarkerFixtures.at(2), MarkerFixtures.at(3)])
}
