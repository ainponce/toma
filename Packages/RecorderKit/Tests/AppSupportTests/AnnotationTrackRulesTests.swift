// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import Foundation
import ProjectFormat
import Testing

@Suite struct AnnotationTrackRulesTests {
    private static let base = HostTime(nanoseconds: 5_000_000_000_000)
    private static func at(_ s: Double) -> HostTime { base.adding(seconds: s) }
    private static func output(_ s: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: s) }

    private static let take = TakeRecord(
        id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        tracks: [
            TrackRecord(
                id: "display-1", kind: .display,
                source: TrackSource(name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 1440, height: 900), pixelScale: 2),
                segments: [
                    SegmentRecord(
                        index: 1, file: "takes/take-001/display-1/seg-0001.mov", startHostTime: base, endHostTime: at(20),
                        endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
                ])
        ])

    /// Clips [0, 10) and [12, 20) s of the take at 1×: output 0…18 s, the cut at 10 s.
    private static func document(_ annotations: [Annotation]) -> EditDocument {
        var document = EditDocument.legacy(take: take, events: [])
        document.sequence = [
            Clip(id: "c-00000001", take: "take-001", start: base, end: at(10), speed: 1),
            Clip(id: "c-00000002", take: "take-001", start: at(12), end: at(20), speed: 1),
        ]
        document.annotations.items = annotations
        return document
    }

    private static let rect = NormalizedRect(x: 0.3, y: 0.45, width: 0.4, height: 0.06)

    /// A text of the output over `[from, to)` s.
    private static func output(_ id: String, from: Double, to: Double) -> Annotation {
        Annotation(
            id: id, anchor: .output(start: output(from), end: output(to)), layer: 1,
            kind: .text(TextAnnotation(string: "Hola", preset: .plain)), rect: rect)
    }

    /// A step anchored to the take over its source `[from, to)` s.
    private static func content(_ id: String, from: Double, to: Double) -> Annotation {
        Annotation(id: id, anchor: .content(take: "take-001", start: at(from), end: at(to)), layer: 1, kind: .step(StepAnnotation()), rect: rect)
    }

    private static func whole(_ id: String) -> Annotation {
        Annotation(id: id, anchor: .whole, layer: 1, kind: .shape(ShapeAnnotation(shape: .rect)), rect: rect)
    }

    private static func lanes(_ items: [AnnotationTrackRules.Item]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.item.id, $0.lane) })
    }

    /// At 100 pt/s with the timeline not scrolled, second `s` is at `88 + 100 s`.
    private static func x(_ seconds: Double) -> Double { TimelineLayout.headerWidth + seconds * 100 }

    /// What `AnnotationTrackRules.hit` found, to compare.
    private struct Found: Equatable {
        var id: String
        var edge: ClipEdge?
    }

    /// What is at (`x`, `y`) of `document`'s row, from 100 pt down.
    private static func hit(_ document: EditDocument, _ x: Double, _ y: Double, offset: Double = 0) -> Found? {
        AnnotationTrackRules.hit(
            at: CGPoint(x: x, y: y), items: AnnotationTrackRules.items(document), rowTop: 100,
            rowHeight: AnnotationTrackRules.rowHeight(document), scale: 100, offset: offset
        ).map { Found(id: $0.id, edge: $0.edge) }
    }

    @Test func overlappingGoInLanes() {
        // [0, 3) and [1, 4) overlap; [3, 4.5) starts where the first ends, so its lane is free; [5, 6) too.
        let document = Self.document([
            Self.output("a-00000001", from: 0, to: 3), Self.output("a-00000002", from: 1, to: 4),
            Self.output("a-00000004", from: 5, to: 6), Self.output("a-00000003", from: 3, to: 4.5),
        ])
        let items = AnnotationTrackRules.items(document)
        #expect(Self.lanes(items) == ["a-00000001": 0, "a-00000002": 1, "a-00000003": 0, "a-00000004": 0])
        #expect(items.allSatisfy { $0.item.track == .annotations && !$0.whole })
        #expect(items.first { $0.item.id == "a-00000002" }?.item.output == Self.output(1)..<Self.output(4))
        #expect(AnnotationTrackRules.rowHeight(document) == 38)
    }

    @Test func wholeIsAThinBarOnTop() {
        let document = Self.document([Self.whole("a-00000001"), Self.output("a-00000002", from: 0, to: 3)])
        let items = AnnotationTrackRules.items(document)
        let bar = items.first { $0.item.id == "a-00000001" }
        #expect(bar?.whole == true)
        #expect(bar?.item.output == 0..<Self.output(18))
        // It takes no lane: the other one is in the first.
        #expect(items.first { $0.item.id == "a-00000002" }?.lane == 0)
        // 6 + 16 + 8.
        #expect(AnnotationTrackRules.rowHeight(document) == 30)
        // Its band is the top of the row (100 to 111): the bar, never an edge; under it, the lane.
        #expect(Self.hit(document, Self.x(1), 104) == Found(id: "a-00000001", edge: nil))
        #expect(Self.hit(document, Self.x(0) + 2, 104) == Found(id: "a-00000001", edge: nil))
        #expect(Self.hit(document, Self.x(1), 119) == Found(id: "a-00000002", edge: nil))
        #expect(Self.hit(document, Self.x(5), 119) == nil)
        // Alone, the bar is all of its row of 28 pt.
        let alone = Self.document([Self.whole("a-00000001")])
        #expect(AnnotationTrackRules.rowHeight(alone) == 28)
        #expect(Self.hit(alone, Self.x(9), 120) == Found(id: "a-00000001", edge: nil))
    }

    @Test func cutAwayIsNotAnItem() {
        // [10.5, 11.5) of the take is in the cut; [9, 13) shows its two kept parts, closed: 9…11 s of output. Of the output,
        // one after the end is not there and one across it ends with it.
        let document = Self.document([
            Self.content("a-00000001", from: 10.5, to: 11.5), Self.content("a-00000002", from: 9, to: 13),
            Self.output("a-00000003", from: 18.5, to: 19), Self.output("a-00000004", from: 17, to: 19),
        ])
        let items = AnnotationTrackRules.items(document)
        #expect(items.map(\.item.id).sorted() == ["a-00000002", "a-00000004"])
        #expect(items.first { $0.item.id == "a-00000002" }?.item.output == Self.output(9)..<Self.output(11))
        #expect(items.first { $0.item.id == "a-00000004" }?.item.output == Self.output(17)..<Self.output(18))
        // What is not there takes no lane.
        #expect(items.allSatisfy { $0.lane == 0 })
        #expect(AnnotationTrackRules.rowHeight(document) == 28)
    }

    @Test func rowGrowsWithLanesUpToFour() {
        #expect(AnnotationTrackRules.maxLanes == 4)
        #expect(AnnotationTrackRules.rowHeight(Self.document([Self.output("a-00000001", from: 0, to: 3)])) == 28)
        let three = Self.document((1...3).map { Self.output("a-0000000\($0)", from: Double($0), to: 9) })
        #expect(AnnotationTrackRules.rowHeight(three) == 54)
        #expect(TimelineLayout(take: Self.take, document: three).tracks.first { $0.track == .annotations }?.height == 54)

        // Seven over 4.6 s: four lanes, the last with four of them, the shortest on top (last).
        let seven = Self.document([
            Self.output("a-00000001", from: 0, to: 10), Self.output("a-00000002", from: 1, to: 10),
            Self.output("a-00000003", from: 2, to: 10), Self.output("a-00000004", from: 3, to: 10),
            Self.output("a-00000005", from: 3.5, to: 9), Self.output("a-00000006", from: 4, to: 5),
            Self.output("a-00000007", from: 4.5, to: 8),
        ])
        let items = AnnotationTrackRules.items(seven)
        #expect(Self.lanes(items).values.max() == 3)
        #expect(items.filter { $0.lane == 3 }.map(\.item.id) == ["a-00000004", "a-00000005", "a-00000007", "a-00000006"])
        #expect(AnnotationTrackRules.rowHeight(seven) == 70)
        // Lane 3 is 151…170 (from 100 + 3 + 3 × 16): the shortest under the pointer.
        #expect(Self.hit(seven, Self.x(4.6), 160) == Found(id: "a-00000006", edge: nil))
        #expect(Self.hit(seven, Self.x(6), 160) == Found(id: "a-00000007", edge: nil))
        // With the bar on top, 8 more.
        var barred = seven
        barred.annotations.items.append(Self.whole("a-00000008"))
        #expect(AnnotationTrackRules.rowHeight(barred) == 78)
    }

    @Test func hitFindsTheLaneAndTheEdge() {
        // Lane 0 is 103…119 and lane 1 119…135 of a row of 38 pt from 100.
        let document = Self.document([Self.output("a-00000001", from: 0, to: 3), Self.output("a-00000002", from: 1, to: 4)])
        #expect(Self.hit(document, Self.x(2), 110) == Found(id: "a-00000001", edge: nil))
        #expect(Self.hit(document, Self.x(2), 125) == Found(id: "a-00000002", edge: nil))
        #expect(Self.hit(document, Self.x(1) + 3, 125) == Found(id: "a-00000002", edge: .start))
        #expect(Self.hit(document, Self.x(4) - 3, 125) == Found(id: "a-00000002", edge: .end))
        #expect(Self.hit(document, Self.x(1) + 3, 110) == Found(id: "a-00000001", edge: nil))
        // Nothing in lane 0 at 3.5 s; the padding is the nearest lane's; out of the row, nothing.
        #expect(Self.hit(document, Self.x(3.5), 110) == nil)
        #expect(Self.hit(document, Self.x(2), 101) == Found(id: "a-00000001", edge: nil))
        #expect(Self.hit(document, Self.x(2), 137) == Found(id: "a-00000002", edge: nil))
        #expect(Self.hit(document, Self.x(2), 99) == nil)
        #expect(Self.hit(document, Self.x(2), 138) == nil)
        // Scrolled 50 pt, the same place is 50 pt to the left.
        #expect(Self.hit(document, Self.x(1) + 3 - 50, 125, offset: 50) == Found(id: "a-00000002", edge: .start))
        // A whole video's bar has no edges, nor does an item narrower than three times the zone keep more than a third.
        let narrow = Self.document([Self.output("a-00000001", from: 1, to: 1.12)])
        #expect(Self.hit(narrow, Self.x(1) + 2, 110) == Found(id: "a-00000001", edge: .start))
        #expect(Self.hit(narrow, Self.x(1) + 6, 110) == Found(id: "a-00000001", edge: nil))
    }

    @Test func legacyHasNoRow() {
        let legacy = EditDocument.legacy(take: Self.take, events: [])
        #expect(!TimelineLayout(take: Self.take, document: legacy).tracks.map(\.track).contains(.annotations))
        #expect(AnnotationTrackRules.items(legacy).isEmpty)
        #expect(AnnotationTrackRules.rowHeight(legacy) == TimelineLayout.annotationsHeight)
        // An annotation the output does not show still has its row (B11), at its least height.
        let cut = Self.document([Self.content("a-00000001", from: 10.5, to: 11.5)])
        #expect(TimelineLayout(take: Self.take, document: cut).tracks.first { $0.track == .annotations }?.height == 28)
    }

    @Test func bandsOfTheLanesAndTheBar() {
        // One lane fills the row as a privacy block does; with more, 16 pt each, 1 pt in from their edges.
        let one = AnnotationTrackRules.band(lane: 0, lanes: 1, bar: false, rowTop: 100, rowHeight: 28)
        #expect(one.top == 103 && one.height == 22)
        let second = AnnotationTrackRules.band(lane: 1, lanes: 2, bar: true, rowTop: 100, rowHeight: 46)
        #expect(second.top == 100 + 3 + 8 + 16 + 1 && second.height == 14)
        let bar = AnnotationTrackRules.band(lane: nil, lanes: 2, bar: true, rowTop: 100, rowHeight: 46)
        #expect(bar.top == 103 && bar.height == 4)
    }
}
