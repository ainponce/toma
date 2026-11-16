// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// The fixture of the zoom commands' tests, namespaced so that no other file of EditingTests meets its names: a take of
/// one display of 1440 × 900 pt recorded for 60 s from `base`, and a document of one clip over all of it at 1×, so an
/// output second is a source second after `base`, with Toma's automatic zoom.
private enum ZoomFixture {
    static let takeID = "take-001"
    static let base = HostTime(nanoseconds: 5_000_000_000_000)

    static func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

    static func output(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

    static func range(_ from: Double, _ to: Double) -> Range<Int64> { output(from)..<output(to) }

    static let take = TakeRecord(
        id: takeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        tracks: [
            TrackRecord(
                id: "display-1", kind: .display,
                source: TrackSource(name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 1440, height: 900), pixelScale: 2),
                segments: [
                    SegmentRecord(
                        index: 1, file: "takes/take-001/display-1/seg-0001.mov", startHostTime: base, endHostTime: at(60),
                        endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
                ])
        ])

    /// A click in the middle of the display `seconds` after `base`.
    static func click(_ seconds: Double) -> [InputEvent] {
        [
            InputEvent(t: at(seconds), kind: .mouseDown(.left, x: 720, y: 450)),
            InputEvent(t: at(seconds + 0.05), kind: .mouseUp(.left, x: 720, y: 450)),
        ]
    }

    static func block(
        _ id: String, from: Double, to: Double, origin: Origin = .user, depth: Double? = 1.6, focus: ZoomFocus = .follow
    ) -> ZoomRegion {
        ZoomRegion(id: id, take: takeID, start: at(from), end: at(to), origin: origin, depth: depth, focus: focus, instant: false)
    }

    static func document(
        _ regions: [ZoomRegion] = [], suppressed: [SourceRange] = [], sequence: [Clip]? = nil
    ) -> EditDocument {
        var document = EditDocument.legacy(take: take, events: [])
        document.sequence = sequence ?? [Clip(id: "c-00000001", take: takeID, start: base, end: at(60), speed: 1)]
        document.screens = ScreenPlan(initial: [takeID: "display-1"], changes: [])
        document.zoom.auto = DefaultStyle.toma.zoomAuto
        document.zoom.regions = regions
        document.zoom.suppressed = suppressed
        return document
    }

    /// The document of the automatic blocks Toma's settings plan for `events`.
    static func planned(_ events: [InputEvent], regions: [ZoomRegion] = []) -> EditDocument {
        var document = document(regions)
        document.zoom.regions += AutoZoomPlanner.plan(take: take, events: events, document: document)
        document.zoom.regions.sort { $0.start < $1.start }
        return document
    }

    /// The source span of each block, in seconds after `base`.
    static func spans(_ document: EditDocument) -> [ClosedRange<Double>] {
        document.zoom.regions.map { region in
            Double(region.start.nanoseconds - base.nanoseconds) / 1e9...Double(region.end.nanoseconds - base.nanoseconds) / 1e9
        }
    }

    /// `document` with `step` applied, checking on the way that its inverse gives `document` back.
    static func applying(_ step: EditStep, to document: EditDocument) throws -> EditDocument {
        let edited = try document.applying(step.changes)
        #expect(try edited.applying(step.changes.reversed().map(\.inverse)) == document)
        return edited
    }

    /// `z-00000010`, `z-00000011`… as it is asked.
    final class IDs {
        private var next = 0x10

        func make(_ prefix: String) -> String {
            defer { next += 1 }
            return prefix + String(format: "%08x", next)
        }
    }
}

@Test func addingAZoomFillsOnlyFreeSpace() throws {
    let a = ZoomFixture.block("z-0000000a", from: 2, to: 4), b = ZoomFixture.block("z-0000000b", from: 6, to: 8)
    let document = ZoomFixture.document([a, b])
    let step = try #require(ZoomCommands.add(document, output: ZoomFixture.range(3, 7), makeID: ZoomFixture.IDs().make))
    #expect(step.label == .zoomAdd)
    #expect(step.target == "z-00000010")
    // A block of the user's, at the project's depth, following the cursor.
    let added = ZoomRegion(
        id: "z-00000010", take: ZoomFixture.takeID, start: ZoomFixture.at(4), end: ZoomFixture.at(6), origin: .user, depth: 2.0,
        focus: .follow, instant: false)
    #expect(step.changes == [document.insertChange(.zoomRegions, at: 1, added)])
    #expect(try ZoomFixture.applying(step, to: document).zoom.regions == [a, added, b])

    // 0.2 s of free space is less than the 0.3 s a block lasts at least.
    #expect(ZoomCommands.add(document, output: ZoomFixture.range(4.0, 4.2), makeID: ZoomFixture.IDs().make) == nil)
    #expect(ZoomCommands.add(document, output: ZoomFixture.range(4.0, 4.3), makeID: ZoomFixture.IDs().make) != nil)
    // Nothing free inside a block; past the end of the output, up to it.
    #expect(ZoomCommands.add(document, output: ZoomFixture.range(2.5, 3.5), makeID: ZoomFixture.IDs().make) == nil)
    let tail = try #require(ZoomCommands.add(document, output: ZoomFixture.range(50, 70), makeID: ZoomFixture.IDs().make))
    #expect(ZoomFixture.spans(try ZoomFixture.applying(tail, to: document)) == [2...4, 6...8, 50...60])
    // Over several free parts, the longest.
    let wide = try #require(ZoomCommands.add(document, output: ZoomFixture.range(1, 11), makeID: ZoomFixture.IDs().make))
    #expect(ZoomFixture.spans(try ZoomFixture.applying(wide, to: document)) == [2...4, 6...8, 8...11])
}

@Test func addCenteredIsThreeSeconds() throws {
    #expect(ZoomCommands.defaultDuration == 3_000_000_000)
    #expect(ZoomCommands.minimumDuration == 300_000_000)
    let document = ZoomFixture.document([ZoomFixture.block("z-0000000a", from: 2, to: 4), ZoomFixture.block("z-0000000b", from: 6, to: 8)])
    let step = try #require(ZoomCommands.addCentered(document, at: ZoomFixture.output(10), makeID: ZoomFixture.IDs().make))
    #expect(step.label == .zoomAdd)
    #expect(ZoomFixture.spans(try ZoomFixture.applying(step, to: document)) == [2...4, 6...8, 8.5...11.5])
    // Between two blocks it takes the free space around the instant; on a block, nothing.
    let between = try #require(ZoomCommands.addCentered(document, at: ZoomFixture.output(5), makeID: ZoomFixture.IDs().make))
    #expect(ZoomFixture.spans(try ZoomFixture.applying(between, to: document)) == [2...4, 4...6, 6...8])
    #expect(ZoomCommands.addCentered(document, at: ZoomFixture.output(3), makeID: ZoomFixture.IDs().make) == nil)
    // At the start of the output it stops there.
    let start = try #require(ZoomCommands.addCentered(document, at: ZoomFixture.output(0.5), makeID: ZoomFixture.IDs().make))
    #expect(ZoomFixture.spans(try ZoomFixture.applying(start, to: document)) == [0...2, 2...4, 6...8])
}

@Test func movingAZoomStopsAtItsNeighbour() throws {
    let a = ZoomFixture.block("z-0000000a", from: 2, to: 4, origin: .auto, depth: nil)
    let b = ZoomFixture.block("z-0000000b", from: 6, to: 8)
    let document = ZoomFixture.document([a, b])
    let step = try #require(ZoomCommands.move(document, id: a.id, toOutputStart: ZoomFixture.output(5.5)))
    #expect(step.label == .zoomMove)
    #expect(step.target == a.id)
    var moved = ZoomFixture.block(a.id, from: 4, to: 6, depth: nil)
    moved.origin = .user
    #expect(step.changes == [try #require(document.replaceChange(.zoomRegions, id: a.id, with: moved))])
    #expect(try ZoomFixture.applying(step, to: document).zoom.regions == [moved, b])
    // Back, it stops at the start of the output; where it is already, nothing.
    let back = try #require(ZoomCommands.move(document, id: a.id, toOutputStart: ZoomFixture.output(-3)))
    #expect(ZoomFixture.spans(try ZoomFixture.applying(back, to: document)) == [0...2, 6...8])
    #expect(ZoomCommands.move(document, id: a.id, toOutputStart: ZoomFixture.output(2)) == nil)
    #expect(ZoomCommands.move(document, id: "z-ffffffff", toOutputStart: 0) == nil)
    // Forward from the last block, up to the end of the output.
    let last = try #require(ZoomCommands.move(document, id: b.id, toOutputStart: ZoomFixture.output(70)))
    #expect(ZoomFixture.spans(try ZoomFixture.applying(last, to: document)) == [2...4, 58...60])
}

@Test func trimmingAZoomStopsAtItsNeighbourAndKeepsItsMinimum() throws {
    let a = ZoomFixture.block("z-0000000a", from: 2, to: 4), b = ZoomFixture.block("z-0000000b", from: 6, to: 8)
    let document = ZoomFixture.document([a, b])
    func trimmed(_ id: String, _ edge: ClipEdge, to seconds: Double) throws -> [ClosedRange<Double>]? {
        guard let step = ZoomCommands.trim(document, id: id, edge: edge, toOutput: ZoomFixture.output(seconds)) else { return nil }
        #expect(step.label == .zoomChange)
        #expect(step.target == id)
        return ZoomFixture.spans(try ZoomFixture.applying(step, to: document))
    }
    #expect(try trimmed(a.id, .end, to: 7) == [2...6, 6...8])
    #expect(try trimmed(a.id, .end, to: 3) == [2...3, 6...8])
    #expect(try trimmed(a.id, .end, to: 2.1) == [2...2.3, 6...8])
    #expect(try trimmed(a.id, .start, to: 3.9) == [3.7...4, 6...8])
    #expect(try trimmed(a.id, .start, to: 1) == [1...4, 6...8])
    #expect(try trimmed(b.id, .start, to: 3) == [2...4, 4...8])
    #expect(try trimmed(b.id, .end, to: 99) == [2...4, 6...60])
    #expect(try trimmed(a.id, .start, to: 2) == nil)
}

@Test func touchingAnAutoZoomMakesItUser() throws {
    let auto = ZoomFixture.block("z-0000000a", from: 10, to: 12, origin: .auto, depth: nil)
    let document = ZoomFixture.document([auto])
    let step = try #require(ZoomCommands.change(document, id: auto.id, depth: 1.6))
    #expect(step.label == .zoomChange)
    #expect(step.target == auto.id)
    var touched = auto
    touched.origin = .user
    touched.depth = 1.6
    #expect(step.changes == [try #require(document.replaceChange(.zoomRegions, id: auto.id, with: touched))])
    let edited = try ZoomFixture.applying(step, to: document)
    #expect(edited.zoom.regions == [touched])

    // `nil` leaves a field alone; `.some(nil)` goes back to the project's depth.
    #expect(ZoomCommands.change(edited, id: auto.id) == nil)
    #expect(ZoomCommands.change(edited, id: auto.id, depth: 1.6, instant: false) == nil)
    let projectDepth = try #require(ZoomCommands.change(edited, id: auto.id, depth: .some(nil)))
    #expect(try ZoomFixture.applying(projectDepth, to: edited).zoom.regions.first?.depth == nil)
    let fixed = try #require(ZoomCommands.change(edited, id: auto.id, focus: .fixed(x: 0.25, y: 0.75), instant: true))
    let region = try #require(try ZoomFixture.applying(fixed, to: edited).zoom.regions.first)
    #expect(region.focus == .fixed(x: 0.25, y: 0.75))
    #expect(region.instant)
    #expect(region.depth == 1.6)
    // Depths from 1.25× to 4×.
    let deep = try #require(ZoomCommands.change(edited, id: auto.id, depth: 9))
    #expect(try ZoomFixture.applying(deep, to: edited).zoom.regions.first?.depth == 4)
    // An automatic block asked for what it has already is not touched.
    #expect(ZoomCommands.change(document, id: auto.id, depth: .some(nil), focus: .follow) == nil)
}

@Test func deletingAnAutoZoomSuppressesIt() throws {
    let events = ZoomFixture.click(5)
    let user = ZoomFixture.block("z-0000000b", from: 20, to: 22)
    let document = ZoomFixture.planned(events, regions: [user])
    let auto = try #require(document.zoom.regions.first)
    #expect(auto.origin == .auto)
    #expect(ZoomFixture.spans(document) == [4.5...6, 20...22])

    let step = try #require(ZoomCommands.delete(document, ids: [auto.id]))
    #expect(step.label == .zoomDelete)
    #expect(step.target == auto.id)
    let range = SourceRange(take: ZoomFixture.takeID, start: auto.start, end: auto.end)
    #expect(
        step.changes == [
            try #require(document.removeChange(.zoomRegions, at: 0)), document.insertChange(.zoomSuppressed, at: 0, range),
        ])
    let edited = try ZoomFixture.applying(step, to: document)
    #expect(edited.zoom.regions == [user])
    #expect(edited.zoom.suppressed == [range])

    // Planned again, it does not come back.
    let again = ZoomCommands.regenerate(edited, take: ZoomFixture.take, events: events, settings: edited.zoom.auto)
    #expect(again.label == .zoomRegenerate)
    #expect(again.changes.isEmpty)
    // A block of the user's just goes.
    let both = try #require(ZoomCommands.delete(document, ids: [user.id, auto.id, "z-ffffffff"]))
    #expect(both.target == "\(auto.id),\(user.id)")
    let empty = try ZoomFixture.applying(both, to: document)
    #expect(empty.zoom.regions.isEmpty)
    #expect(empty.zoom.suppressed == [range])
    #expect(ZoomCommands.delete(document, ids: ["z-ffffffff"]) == nil)
}

@Test func regenerateReplacesOnlyUntouchedAutos() throws {
    let events = ZoomFixture.click(5) + ZoomFixture.click(20) + ZoomFixture.click(40)
    var document = ZoomFixture.planned(events, regions: [ZoomFixture.block("z-0000000c", from: 30, to: 33)])
    #expect(ZoomFixture.spans(document) == [4.5...6, 19.5...21, 30...33, 39.5...41])
    // The block at 20 s is touched: it is the user's now.
    let touchedID = document.zoom.regions[1].id
    document = try document.applying(try #require(ZoomCommands.change(document, id: touchedID, depth: 1.6)).changes)
    let touched = document.zoom.regions[1]
    let user = document.zoom.regions[2]

    var settings = document.zoom.auto
    settings.leadIn = 1.0
    let step = ZoomCommands.regenerate(document, take: ZoomFixture.take, events: events, settings: settings)
    #expect(step.label == .zoomRegenerate)
    #expect(step.target == "/zoom/auto")
    #expect(step.changes.contains(try #require(document.setChange("/zoom/auto", settings))))
    let edited = try ZoomFixture.applying(step, to: document)
    #expect(edited.zoom.auto == settings)
    // The untouched ones start 1 s before their click; the touched one and the user's stay as they were.
    #expect(ZoomFixture.spans(edited) == [4...6, 19.5...21, 30...33, 39...41])
    #expect(edited.zoom.regions[1] == touched)
    #expect(edited.zoom.regions[2] == user)
    #expect(edited.zoom.regions.filter { $0.origin == .auto }.map(\.id) == [
        AutoZoomPlanner.regionID(take: ZoomFixture.takeID, start: ZoomFixture.at(4), end: ZoomFixture.at(6)),
        AutoZoomPlanner.regionID(take: ZoomFixture.takeID, start: ZoomFixture.at(39), end: ZoomFixture.at(41)),
    ])
    // Planned again with nothing changed, nothing changes.
    #expect(ZoomCommands.regenerate(edited, take: ZoomFixture.take, events: events, settings: settings).changes.isEmpty)
}

@Test func autoOffRemovesUntouchedAutos() throws {
    let events = ZoomFixture.click(5) + ZoomFixture.click(20) + ZoomFixture.click(40)
    var document = ZoomFixture.planned(events, regions: [ZoomFixture.block("z-0000000c", from: 30, to: 33)])
    let touchedID = document.zoom.regions[1].id
    document = try document.applying(try #require(ZoomCommands.change(document, id: touchedID, instant: true)).changes)

    var settings = document.zoom.auto
    settings.enabled = false
    let step = ZoomCommands.regenerate(document, take: ZoomFixture.take, events: events, settings: settings)
    #expect(step.label == .zoomRegenerate)
    #expect(
        step.changes == [
            try #require(document.setChange("/zoom/auto", settings)),
            try #require(document.removeChange(.zoomRegions, at: 3)),
            try #require(document.removeChange(.zoomRegions, at: 0)),
        ])
    let edited = try ZoomFixture.applying(step, to: document)
    #expect(ZoomFixture.spans(edited) == [19.5...21, 30...33])
    #expect(edited.zoom.regions.allSatisfy { $0.origin == .user })
}

@Test func aMovedAutoZoomKeepsItsIDAndIsNeverPlannedTwice() throws {
    let events = ZoomFixture.click(5)
    let document = ZoomFixture.planned(events)
    let auto = try #require(document.zoom.regions.first)
    // Moved away, it is the user's, with the id its planned place gave it.
    let moved = try document.applying(try #require(ZoomCommands.move(document, id: auto.id, toOutputStart: ZoomFixture.output(30))).changes)
    #expect(moved.zoom.regions.map(\.id) == [auto.id])
    // The planner puts a block at 4.5 s again, whose id would be the same: it is left out, so no two blocks share one.
    let step = ZoomCommands.regenerate(moved, take: ZoomFixture.take, events: events, settings: moved.zoom.auto)
    #expect(step.changes.isEmpty)
}

@Test func blocksAreMadeInWhatTheOutputShows() throws {
    // A cut from 10 s to 20 s of the source: output 10 s is source 20 s.
    let sequence = [
        Clip(id: "c-00000001", take: ZoomFixture.takeID, start: ZoomFixture.base, end: ZoomFixture.at(10), speed: 1),
        Clip(id: "c-00000002", take: ZoomFixture.takeID, start: ZoomFixture.at(20), end: ZoomFixture.at(60), speed: 2),
    ]
    let document = ZoomFixture.document(sequence: sequence)
    // Across the cut: [9 s, 10 s) of the first clip and [20 s, 22 s) of the second, at 2×, whose end is the source of 1 ns
    // before the output's end, and 1 ns (as the planner places its blocks: decision 16).
    let step = try #require(ZoomCommands.add(document, output: ZoomFixture.range(9, 11), makeID: ZoomFixture.IDs().make))
    let region = try #require(try ZoomFixture.applying(step, to: document).zoom.regions.first)
    #expect(region.start == ZoomFixture.at(9))
    #expect(region.end == HostTime(nanoseconds: ZoomFixture.at(22).nanoseconds - 1))
    let shown = TimeMap(sequence: sequence).outputRange(ofSource: region.start..<region.end, take: ZoomFixture.takeID)
    #expect(shown == ZoomFixture.range(9, 11))
    // A block in the cut takes no room.
    let hidden = ZoomFixture.document([ZoomFixture.block("z-0000000a", from: 12, to: 18)], sequence: sequence)
    #expect(ZoomCommands.add(hidden, output: ZoomFixture.range(9, 11), makeID: ZoomFixture.IDs().make) != nil)
    #expect(ZoomCommands.move(hidden, id: "z-0000000a", toOutputStart: 0) == nil)
}

@Test func zoomShowAndMotionBlurAreSteps() throws {
    let document = ZoomFixture.document()
    #expect(ZoomCommands.setShow(document, true) == nil)
    let hide = try #require(ZoomCommands.setShow(document, false))
    #expect(hide.changes == [try #require(document.setChange("/zoom/show", false))])
    #expect(hide.target == "/zoom/show")
    #expect(ZoomCommands.setMotionBlur(document, 0) == nil)
    let blur = try #require(ZoomCommands.setMotionBlur(document, 0.5))
    #expect(try document.applying(blur.changes).zoom.motionBlur == 0.5)
    #expect(try document.applying(try #require(ZoomCommands.setMotionBlur(document, 3)).changes).zoom.motionBlur == 1)
    #expect(ZoomCommands.setMotionBlur(document, .nan) == nil)
}
