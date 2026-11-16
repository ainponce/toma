// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// The fixture of the layout commands' tests, namespaced so that no other file of EditingTests meets its names: a take of
/// one display recorded for 20 s from `base`, and a document of one clip over all of it at 1×, so an output second is a
/// source second after `base`. The take's bubble starts at the bottom right and the take recorded a change to the top
/// left at 3 s.
private enum LayoutFixture {
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
                        index: 1, file: "takes/take-001/display-1/seg-0001.mov", startHostTime: base, endHostTime: at(20),
                        endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
                ])
        ])

    static let initial = CameraStyle(shape: .circle, size: CameraStyle.medium, anchor: .bottomTrailing)
    static let recorded = CameraStyle(shape: .circle, size: CameraStyle.medium, anchor: .topLeading)
    static let custom = CameraStyle(shape: .roundedSquare, size: CameraStyle.large, anchor: .top)

    static let fullClip = [Clip(id: "c-00000001", take: takeID, start: base, end: at(20), speed: 1)]

    /// The take in three clips, [0 s, 5 s), [5 s, 10 s) and [10 s, 20 s), the middle one `c-00000002`.
    static let threeClips = [
        Clip(id: "c-00000001", take: takeID, start: at(0), end: at(5), speed: 1),
        Clip(id: "c-00000002", take: takeID, start: at(5), end: at(10), speed: 1),
        Clip(id: "c-00000003", take: takeID, start: at(10), end: at(20), speed: 1),
    ]

    static func document(_ blocks: [LayoutBlock] = [], sequence: [Clip] = fullClip) -> EditDocument {
        var document = EditDocument.legacy(take: take, events: [])
        document.sequence = sequence
        document.camera = CameraPlan(
            show: true, initial: [takeID: initial],
            changes: [CameraChange(id: "k-00000001", take: takeID, t: at(3), style: recorded, origin: .recorded)],
            layouts: blocks)
        return document
    }

    static func block(
        _ id: String, from: Double, to: Double, kind: LayoutKind = .cameraFull, instant: Bool = false,
        bubble: CameraStyle? = nil, split: SplitLayout? = nil
    ) -> LayoutBlock {
        LayoutBlock(
            id: id, take: takeID, start: at(from), end: at(to), kind: kind, instant: instant, bubble: bubble.map(BubbleLayout.init),
            split: split)
    }

    static func timeMap(_ document: EditDocument) -> TimeMap { TimeMap(sequence: document.sequence) }

    /// `LayoutCommands.add` over the output from `from` to `to` seconds, with ids from `IDs`.
    static func add(_ document: EditDocument, _ kind: LayoutKind = .cameraFull, from: Double, to: Double) -> EditStep? {
        LayoutCommands.add(document, kind: kind, output: range(from, to), timeMap: timeMap(document), makeID: IDs().make)
    }

    /// `LayoutCommands.add` at `seconds` of output, with ids from `IDs`.
    static func add(_ document: EditDocument, _ kind: LayoutKind, at seconds: Double) -> EditStep? {
        LayoutCommands.add(document, kind: kind, at: output(seconds), timeMap: timeMap(document), makeID: IDs().make)
    }

    /// The source span of each block, in seconds after `base`.
    static func spans(_ document: EditDocument) -> [ClosedRange<Double>] {
        document.camera.layouts.map { block in
            Double(block.start.nanoseconds - base.nanoseconds) / 1e9...Double(block.end.nanoseconds - base.nanoseconds) / 1e9
        }
    }

    /// `document` with `step` applied, checking on the way that its inverse gives `document` back.
    static func applying(_ step: EditStep, to document: EditDocument) throws -> EditDocument {
        let edited = try document.applying(step.changes)
        #expect(try edited.applying(step.changes.reversed().map(\.inverse)) == document)
        return edited
    }

    /// The block `id` of `document`.
    static func block(_ id: String, in document: EditDocument) throws -> LayoutBlock {
        try #require(document.camera.layouts.first { $0.id == id })
    }

    /// The members of a block as the document writes it.
    static func members(_ block: LayoutBlock) throws -> [String: JSONValue] {
        guard case let .object(members) = try JSONValue(encoding: block) else {
            Issue.record("A block is a JSON object.")
            return [:]
        }
        return members
    }

    /// `l-00000010`, `l-00000011`… as it is asked.
    final class IDs {
        private var next = 0x10

        func make(_ prefix: String) -> String {
            defer { next += 1 }
            return prefix + String(format: "%08x", next)
        }
    }
}

@Test func newBlockFillsOnlyFreeSpace() throws {
    let a = LayoutFixture.block("l-0000000a", from: 2, to: 4), b = LayoutFixture.block("l-0000000b", from: 6, to: 8)
    let document = LayoutFixture.document([a, b])
    let step = try #require(LayoutFixture.add(document, from: 3, to: 7))
    #expect(step.label == .layoutAdd)
    #expect(step.target == "l-00000010")
    let added = LayoutBlock(
        id: "l-00000010", take: LayoutFixture.takeID, start: LayoutFixture.at(4), end: LayoutFixture.at(6), kind: .cameraFull,
        instant: false)
    #expect(step.changes == [document.insertChange(.cameraLayouts, at: 1, added)])
    #expect(try LayoutFixture.applying(step, to: document).camera.layouts == [a, added, b])

    // 0.4 s of free space is less than the 0.5 s a block lasts at least; 0.5 s is enough.
    #expect(LayoutFixture.add(document, from: 4, to: 4.4) == nil)
    #expect(LayoutFixture.add(document, from: 4, to: 4.5) != nil)
    // Nothing free inside a block; past the end of the output, up to it.
    #expect(LayoutFixture.add(document, from: 2.5, to: 3.5) == nil)
    let tail = try #require(LayoutFixture.add(document, from: 15, to: 30))
    #expect(LayoutFixture.spans(try LayoutFixture.applying(tail, to: document)) == [2...4, 6...8, 15...20])
    // Over several free parts, the longest, as on the Zoom track.
    let wide = try #require(LayoutFixture.add(document, from: 1, to: 11))
    #expect(LayoutFixture.spans(try LayoutFixture.applying(wide, to: document)) == [2...4, 6...8, 8...11])
    // An id in use is never given twice.
    let taken = LayoutFixture.document([LayoutFixture.block("l-00000010", from: 2, to: 4)])
    let again = try #require(LayoutFixture.add(taken, from: 5, to: 6))
    #expect(again.target == "l-00000011")
}

@Test func aNewBlockShowsWhereItWasPlacedAtAnySpeed() throws {
    // At 2×, the block's end goes back to the source as the source of its last nanosecond and 1 ns (plan 1c decision 9):
    // it still ends where it was placed, and the next one placed there touches it.
    let document = LayoutFixture.document(sequence: [
        Clip(id: "c-00000001", take: LayoutFixture.takeID, start: LayoutFixture.base, end: LayoutFixture.at(20), speed: 2)
    ])
    let map = LayoutFixture.timeMap(document)
    let step = try #require(LayoutFixture.add(document, .cameraOnly, from: 1, to: 2.5))
    let edited = try LayoutFixture.applying(step, to: document)
    let block = try LayoutFixture.block(step.target, in: edited)
    #expect(map.outputRange(ofSource: block.start..<block.end, take: block.take) == LayoutFixture.range(1, 2.5))
    #expect(LayoutCommands.block(atOutput: LayoutFixture.output(2.5) - 1, in: edited, timeMap: map) == block)
    #expect(LayoutCommands.block(atOutput: LayoutFixture.output(2.5), in: edited, timeMap: map) == nil)
    let next = try #require(LayoutFixture.add(edited, .split, at: 2.5))
    let after = try LayoutFixture.block(next.target, in: try LayoutFixture.applying(next, to: edited))
    #expect(map.outputRange(ofSource: after.start..<after.end, take: after.take) == LayoutFixture.range(2.5, 5.5))
}

@Test func newBlockAtThePlayheadLastsThreeSecondsClipped() throws {
    #expect(LayoutCommands.defaultDuration == 3_000_000_000)
    #expect(LayoutCommands.minimumDuration == 500_000_000)
    #expect(LayoutCommands.firstKind == .cameraFull)
    let document = LayoutFixture.document([LayoutFixture.block("l-0000000b", from: 6, to: 8)])
    func add(at seconds: Double) throws -> [ClosedRange<Double>]? {
        guard let step = LayoutFixture.add(document, .screenOnly, at: seconds) else { return nil }
        #expect(step.label == .layoutAdd)
        return LayoutFixture.spans(try LayoutFixture.applying(step, to: document))
    }
    // Up to the block after it; 3 s where it is free; up to the end of the output.
    #expect(try add(at: 5) == [5...6, 6...8])
    #expect(try add(at: 10) == [6...8, 10...13])
    #expect(try add(at: 18) == [6...8, 18...20])
    #expect(try add(at: 0) == [0...3, 6...8])
    // On a block, or with less than 0.5 s free from the playhead: nothing.
    #expect(try add(at: 7) == nil)
    #expect(try add(at: 5.6) == nil)
    #expect(try add(at: 19.7) == nil)
    #expect(try add(at: 20) == nil)
}

@Test func bubbleBlockCopiesTheStyleRulingAtItsStart() throws {
    let document = LayoutFixture.document()
    let map = LayoutFixture.timeMap(document)
    func added(_ kind: LayoutKind, at seconds: Double) throws -> LayoutBlock {
        let step = try #require(LayoutFixture.add(document, kind, at: seconds))
        return try LayoutFixture.block(step.target, in: try LayoutFixture.applying(step, to: document))
    }
    // At 3.2 s the bubble is still springing to the top left: the block copies where it goes, not where it is seen.
    #expect(try added(.bubble, at: 3.2).bubble == BubbleLayout(style: LayoutFixture.recorded))
    #expect(try added(.bubble, at: 3).bubble == BubbleLayout(style: LayoutFixture.recorded))
    // Before the change, the take's initial style, even if the block goes on past it.
    #expect(try added(.bubble, at: 2).bubble == BubbleLayout(style: LayoutFixture.initial))
    // A block made as another layout has no settings of the bubble; a split gets its own.
    let full = try added(.cameraFull, at: 2)
    #expect(full.bubble == nil && full.split == nil)
    let split = try added(.split, at: 2)
    #expect(split.bubble == nil && split.split == SplitLayout(side: .end))
    // A block that becomes a bubble later copies the style ruling at its start then.
    let later = LayoutFixture.document([LayoutFixture.block("l-0000000a", from: 3.2, to: 6)])
    let step = try #require(LayoutCommands.setKind(later, id: "l-0000000a", .bubble, timeMap: map))
    #expect(try LayoutFixture.block("l-0000000a", in: try LayoutFixture.applying(step, to: later)).bubble
        == BubbleLayout(style: LayoutFixture.recorded))
    // The style the user sets is kept in the document's sizes, on a bubble block only.
    let bubble = LayoutFixture.document([
        LayoutFixture.block("l-0000000a", from: 3.2, to: 6, kind: .bubble, bubble: LayoutFixture.recorded)
    ])
    var big = LayoutFixture.custom
    big.size = 0.9
    let set = try #require(LayoutCommands.setBubbleStyle(bubble, id: "l-0000000a", big))
    #expect(set.label == .layoutChange && set.target == "l-0000000a")
    #expect(try LayoutFixture.block("l-0000000a", in: try LayoutFixture.applying(set, to: bubble)).bubble?.style.size == 0.45)
    #expect(LayoutCommands.setBubbleStyle(bubble, id: "l-0000000a", LayoutFixture.recorded) == nil)
    big.size = .nan
    #expect(LayoutCommands.setBubbleStyle(bubble, id: "l-0000000a", big) == nil)
    #expect(LayoutCommands.setBubbleStyle(later, id: "l-0000000a", LayoutFixture.custom) == nil)
    #expect(LayoutCommands.setBubbleStyle(bubble, id: "l-ffffffff", LayoutFixture.custom) == nil)
}

@Test func kindChangeKeepsEachLayoutsSettings() throws {
    var document = LayoutFixture.document([
        LayoutFixture.block("l-0000000a", from: 2, to: 6, kind: .bubble, bubble: LayoutFixture.custom)
    ])
    let map = LayoutFixture.timeMap(document)
    func apply(_ step: EditStep?) throws {
        document = try LayoutFixture.applying(try #require(step), to: document)
    }
    try apply(LayoutCommands.setKind(document, id: "l-0000000a", .split, timeMap: map))
    try apply(LayoutCommands.setSplit(document, id: "l-0000000a", share: 0.34))
    try apply(LayoutCommands.setKind(document, id: "l-0000000a", .bubble, timeMap: map))
    var block = try LayoutFixture.block("l-0000000a", in: document)
    #expect(block.kind == .bubble)
    #expect(block.bubble == BubbleLayout(style: LayoutFixture.custom))
    #expect(block.split == SplitLayout(side: .end, share: 0.34))
    try apply(LayoutCommands.setKind(document, id: "l-0000000a", .split, timeMap: map))
    block = try LayoutFixture.block("l-0000000a", in: document)
    #expect(block.kind == .split)
    #expect(block.bubble == BubbleLayout(style: LayoutFixture.custom))
    #expect(block.split == SplitLayout(side: .end, share: 0.34))
    // The document writes both settings, whatever the kind.
    let members = try LayoutFixture.members(block)
    #expect(members["bubble"] != nil && members["split"] != nil)
    #expect(members["kind"] == .string("split"))
    // The same kind again changes nothing; nor does a block that isn't there.
    #expect(LayoutCommands.setKind(document, id: "l-0000000a", .split, timeMap: map) == nil)
    #expect(LayoutCommands.setKind(document, id: "l-ffffffff", .bubble, timeMap: map) == nil)
}

@Test func firstSplitWritesSideEnd() throws {
    let document = LayoutFixture.document([LayoutFixture.block("l-0000000a", from: 2, to: 6)])
    let map = LayoutFixture.timeMap(document)
    let step = try #require(LayoutCommands.setKind(document, id: "l-0000000a", .split, timeMap: map))
    #expect(step.label == .layoutChange && step.target == "l-0000000a")
    let split = try LayoutFixture.block("l-0000000a", in: try LayoutFixture.applying(step, to: document))
    #expect(split.split == SplitLayout(side: .end))
    #expect(split.bubble == nil)

    // The project's layout: one `set` of /camera/layout, with its split written the first time.
    var project = try #require(LayoutCommands.setProjectLayout(document, .split))
    #expect(project.label == .cameraLayout && project.target == "/camera/layout")
    let set = try #require(document.setChange("/camera/layout", CameraLayout(kind: .split, split: SplitLayout(side: .end))))
    #expect(project.changes == [set])
    var edited = try LayoutFixture.applying(project, to: document)
    #expect(LayoutCommands.setProjectLayout(edited, .split) == nil)
    edited = try LayoutFixture.applying(try #require(LayoutCommands.setSplit(edited, id: nil, side: .start)), to: edited)
    edited = try LayoutFixture.applying(try #require(LayoutCommands.setProjectLayout(edited, .bubble)), to: edited)
    // Back to the bubble, the split stays as it was; and comes back so, never written again.
    #expect(edited.camera.layout == CameraLayout(kind: .bubble, split: SplitLayout(side: .start)))
    project = try #require(LayoutCommands.setProjectLayout(edited, .split))
    #expect(try LayoutFixture.applying(project, to: edited).camera.layout == CameraLayout(kind: .split, split: SplitLayout(side: .start)))
    // Other layouts write no settings.
    let only = try LayoutFixture.applying(try #require(LayoutCommands.setProjectLayout(document, .cameraOnly)), to: document)
    #expect(only.camera.layout == CameraLayout(kind: .cameraOnly))
}

@Test func movingAndTrimmingStopAtTheNeighbour() throws {
    let document = LayoutFixture.document([
        LayoutFixture.block("l-0000000a", from: 2, to: 4), LayoutFixture.block("l-0000000b", from: 6, to: 8),
    ])
    let map = LayoutFixture.timeMap(document)
    func moved(_ id: String, to seconds: Double) throws -> [ClosedRange<Double>]? {
        guard let step = LayoutCommands.move(document, id: id, toOutputStart: LayoutFixture.output(seconds), timeMap: map)
        else { return nil }
        #expect(step.label == .layoutMove && step.target == id)
        return LayoutFixture.spans(try LayoutFixture.applying(step, to: document))
    }
    func trimmed(_ id: String, _ edge: ClipEdge, to seconds: Double) throws -> [ClosedRange<Double>]? {
        guard let step = LayoutCommands.trim(document, id: id, edge: edge, toOutput: LayoutFixture.output(seconds), timeMap: map)
        else { return nil }
        #expect(step.label == .layoutTrim && step.target == id)
        return LayoutFixture.spans(try LayoutFixture.applying(step, to: document))
    }
    // A move stops at the block next to it and at the ends of the output, and keeps the block's length.
    #expect(try moved("l-0000000a", to: 5.5) == [4...6, 6...8])
    #expect(try moved("l-0000000a", to: -3) == [0...2, 6...8])
    #expect(try moved("l-0000000a", to: 3) == [3...5, 6...8])
    #expect(try moved("l-0000000b", to: 1) == [2...4, 4...6])
    #expect(try moved("l-0000000b", to: 30) == [2...4, 18...20])
    #expect(try moved("l-0000000a", to: 2) == nil)
    #expect(try moved("l-ffffffff", to: 3) == nil)
    // A trim stops at the neighbour and at the ends, and never leaves less than half a second.
    #expect(try trimmed("l-0000000a", .end, to: 2.3) == [2...2.5, 6...8])
    #expect(try trimmed("l-0000000a", .end, to: 7) == [2...6, 6...8])
    #expect(try trimmed("l-0000000a", .start, to: 3.9) == [3.5...4, 6...8])
    #expect(try trimmed("l-0000000a", .start, to: 1) == [1...4, 6...8])
    #expect(try trimmed("l-0000000a", .start, to: -1) == [0...4, 6...8])
    #expect(try trimmed("l-0000000b", .start, to: 3) == [2...4, 4...8])
    #expect(try trimmed("l-0000000b", .end, to: 25) == [2...4, 6...20])
    #expect(try trimmed("l-0000000a", .end, to: 4) == nil)
}

@Test func shareIsClampedAndAutomaticClearsIt() throws {
    let document = LayoutFixture.document([
        LayoutFixture.block("l-0000000a", from: 2, to: 6, kind: .split, split: SplitLayout(side: .end, share: 0.4)),
        LayoutFixture.block("l-0000000b", from: 8, to: 10),
    ])
    func split(after step: EditStep?) throws -> SplitLayout? {
        let step = try #require(step)
        #expect(step.label == .cameraSplit && step.target == "l-0000000a")
        return try LayoutFixture.block("l-0000000a", in: try LayoutFixture.applying(step, to: document)).split
    }
    #expect(try split(after: LayoutCommands.setSplit(document, id: "l-0000000a", share: 0.9)) == SplitLayout(side: .end, share: 0.60))
    #expect(try split(after: LayoutCommands.setSplit(document, id: "l-0000000a", share: 0.1)) == SplitLayout(side: .end, share: 0.25))
    #expect(try split(after: LayoutCommands.setSplit(document, id: "l-0000000a", side: .start)) == SplitLayout(side: .start, share: 0.4))
    // Automatic: no `share` in the document.
    let automatic = LayoutCommands.setSplit(document, id: "l-0000000a", share: .some(nil))
    #expect(try split(after: automatic) == SplitLayout(side: .end))
    let block = try LayoutFixture.block("l-0000000a", in: try LayoutFixture.applying(try #require(automatic), to: document))
    #expect(try LayoutFixture.members(block)["split"] == .object(["side": .string("end")]))
    // Nothing to change, a share that is not a number, a block that is not a split, or none.
    #expect(LayoutCommands.setSplit(document, id: "l-0000000a", share: 0.4) == nil)
    #expect(LayoutCommands.setSplit(document, id: "l-0000000a") == nil)
    #expect(LayoutCommands.setSplit(document, id: "l-0000000a", share: Double.nan) == nil)
    #expect(LayoutCommands.setSplit(document, id: "l-0000000b", side: .start) == nil)
    #expect(LayoutCommands.setSplit(document, id: "l-ffffffff", side: .start) == nil)

    // The project's layout, `id: nil`, in its split only.
    #expect(LayoutCommands.setSplit(document, id: nil, share: 0.5) == nil)
    let project = try LayoutFixture.applying(try #require(LayoutCommands.setProjectLayout(document, .split)), to: document)
    let share = try #require(LayoutCommands.setSplit(project, id: nil, share: 0.9))
    #expect(share.label == .cameraSplit && share.target == "/camera/layout")
    #expect(try LayoutFixture.applying(share, to: project).camera.layout.split == SplitLayout(side: .end, share: 0.60))
}

@Test func everyBlockEditIsOneReplaceOfTheWholeBlock() throws {
    // A bubble block that was a split once: both settings go in every `before` and `after`.
    let original = LayoutFixture.block(
        "l-0000000a", from: 2, to: 6, kind: .bubble, bubble: LayoutFixture.custom, split: SplitLayout(side: .start, share: 0.3))
    let document = LayoutFixture.document([LayoutFixture.block("l-00000009", from: 0, to: 1), original])
    let map = LayoutFixture.timeMap(document)
    let whole = try JSONValue(encoding: original)
    func check(_ step: EditStep?, _ edit: (inout LayoutBlock) -> Void) throws {
        let step = try #require(step)
        var block = original
        edit(&block)
        let replace = try #require(document.replaceChange(.cameraLayouts, id: original.id, with: block))
        let edited = try JSONValue(encoding: block)
        #expect(step.target == original.id)
        #expect(step.changes == [replace])
        guard step.changes.count == 1, case let .replace(collection, id, before, after) = replace else {
            Issue.record("A block edit is one replace.")
            return
        }
        #expect(collection.string == "/camera/layouts" && id == original.id)
        #expect(before == whole)
        #expect(after == edited)
        for value in [before, after] {
            guard case let .object(members) = value else { continue }
            #expect(members["bubble"] != nil && members["split"] != nil)
        }
        #expect(try LayoutFixture.applying(step, to: document).camera.layouts.last == block)
    }
    try check(LayoutCommands.move(document, id: original.id, toOutputStart: LayoutFixture.output(3), timeMap: map)) {
        ($0.start, $0.end) = (LayoutFixture.at(3), LayoutFixture.at(7))
    }
    try check(LayoutCommands.trim(document, id: original.id, edge: .end, toOutput: LayoutFixture.output(5), timeMap: map)) {
        $0.end = LayoutFixture.at(5)
    }
    try check(LayoutCommands.setKind(document, id: original.id, .split, timeMap: map)) { $0.kind = .split }
    try check(LayoutCommands.setInstant(document, id: original.id, true)) { $0.instant = true }
    try check(LayoutCommands.setBubbleStyle(document, id: original.id, LayoutFixture.recorded)) {
        $0.bubble = BubbleLayout(style: LayoutFixture.recorded)
    }
    // Nothing to change, or no such block: nothing.
    #expect(LayoutCommands.setInstant(document, id: original.id, false) == nil)
    #expect(LayoutCommands.setInstant(document, id: "l-ffffffff", true) == nil)
}

@Test func deletingRemovesTheBlocks() throws {
    let a = LayoutFixture.block("l-0000000a", from: 2, to: 4), b = LayoutFixture.block("l-0000000b", from: 6, to: 8)
    let c = LayoutFixture.block("l-0000000c", from: 10, to: 12)
    let document = LayoutFixture.document([a, b, c])
    let step = try #require(LayoutCommands.delete(document, ids: ["l-0000000c", "l-0000000a", "l-ffffffff"]))
    #expect(step.label == .layoutDelete)
    #expect(step.target == "l-0000000a,l-0000000c")
    #expect(try LayoutFixture.applying(step, to: document).camera.layouts == [b])
    #expect(LayoutCommands.delete(document, ids: ["l-ffffffff"]) == nil)
    #expect(LayoutCommands.delete(document, ids: []) == nil)
}

@Test func aBlockOverACutIsKept() throws {
    let sequence = LayoutFixture.threeClips
    let inside = LayoutFixture.block("l-0000000a", from: 6, to: 8)
    let across = LayoutFixture.block("l-0000000b", from: 9, to: 12)
    let document = LayoutFixture.document([inside, across], sequence: sequence)
    #expect(LayoutCommands.block(atOutput: LayoutFixture.output(7), in: document, timeMap: LayoutFixture.timeMap(document)) == inside)

    let cut = try SequenceCommands.delete(document, clipIDs: ["c-00000002"]).get()
    let edited = try document.applying(cut.changes)
    // Both blocks stay in the document; the one in the cut shows nothing, the one across it shows its kept part as one.
    #expect(edited.camera.layouts == [inside, across])
    let map = LayoutFixture.timeMap(edited)
    for seconds in stride(from: 0.0, to: 15.0, by: 0.25) {
        let shown = LayoutCommands.block(atOutput: LayoutFixture.output(seconds), in: edited, timeMap: map)
        #expect(shown == (seconds >= 5 && seconds < 7 ? across : nil), "at \(seconds) s")
    }

    // Getting the clip back shows the block again.
    let undone = try edited.applying(cut.changes.reversed().map(\.inverse))
    #expect(undone == document)
    let back = LayoutFixture.timeMap(undone)
    #expect(LayoutCommands.block(atOutput: LayoutFixture.output(7), in: undone, timeMap: back) == inside)
    #expect(LayoutCommands.block(atOutput: LayoutFixture.output(11), in: undone, timeMap: back) == across)
    #expect(LayoutCommands.block(atOutput: LayoutFixture.output(8), in: undone, timeMap: back) == nil)
}

@Test func aBlockAcrossAClosedCutHoldsTheOneHiddenInIt() throws {
    // As on the Zoom track (1c design §5.5), a block hidden whole in a cut takes no room on the track.
    let hidden = LayoutFixture.block("l-0000000a", from: 6, to: 8, kind: .split, split: SplitLayout(side: .start))
    let document = LayoutFixture.document([hidden], sequence: LayoutFixture.threeClips)
    let cut = try SequenceCommands.delete(document, clipIDs: ["c-00000002"]).get()
    let edited = try document.applying(cut.changes)
    let step = try #require(LayoutFixture.add(edited, .bubble, from: 4, to: 6))
    let across = try LayoutFixture.applying(step, to: edited)
    let added = try LayoutFixture.block(step.target, in: across)
    // The new block goes across the closed cut, over the source of the hidden one, which stays in the document.
    #expect(LayoutFixture.spans(across) == [4...11, 6...8])
    #expect(across.camera.layouts.last == hidden)

    // With the stretch back, both cover [6 s, 8 s): the one that starts first, the new one, rules over all of its own,
    // in the commands as in the preview, and the hidden one shows nothing until the new one goes.
    let recovered = try across.applying(cut.changes.reversed().map(\.inverse))
    #expect(recovered.camera.layouts == [added, hidden])
    let map = LayoutFixture.timeMap(recovered)
    for seconds in [4.0, 5.5, 6.0, 7.0, 7.99, 10.99] {
        #expect(LayoutCommands.block(atOutput: LayoutFixture.output(seconds), in: recovered, timeMap: map) == added, "at \(seconds) s")
    }
    #expect(LayoutCommands.block(atOutput: LayoutFixture.output(11), in: recovered, timeMap: map) == nil)
    let timeline = LayoutTimeline(document: recovered, take: LayoutFixture.take, timeMap: map, cameraReadable: true)
    #expect(timeline.spans.compactMap(\.blockID) == [added.id])
    // The recorded change at 3 s, the clips' edges and the new block's: nothing of the hidden one.
    #expect(EditPoints(document: recovered, timeMap: map, markers: []).all == [0, 3, 4, 5, 10, 11, 20].map(LayoutFixture.output))
    let alone = try LayoutFixture.applying(try #require(LayoutCommands.delete(recovered, ids: [added.id])), to: recovered)
    #expect(LayoutCommands.block(atOutput: LayoutFixture.output(7), in: alone, timeMap: map) == hidden)
}

@Test func atThreeTimesBlocksTouchAndKeepTheirLength() throws {
    // At 3×, a block's end goes back to the source 1 ns short of where it was placed (plan 1c decision 9): next to
    // another block or at the end of the output it touches them, as the preview shows it, and a move keeps its length.
    var document = LayoutFixture.document(sequence: [
        Clip(id: "c-00000001", take: LayoutFixture.takeID, start: LayoutFixture.base, end: LayoutFixture.at(20), speed: 3)
    ])
    let map = LayoutFixture.timeMap(document)
    let end = map.duration
    func add(_ step: EditStep?) throws -> LayoutBlock {
        let step = try #require(step)
        document = try LayoutFixture.applying(step, to: document)
        return try LayoutFixture.block(step.target, in: document)
    }
    func shown(_ block: LayoutBlock) -> Range<Int64>? { map.outputRange(ofSource: block.start..<block.end, take: block.take) }
    let a = try add(LayoutFixture.add(document, .cameraFull, from: 1, to: 2))
    #expect(shown(a) == LayoutFixture.output(1)..<(LayoutFixture.output(2) - 1))
    let b = try add(LayoutFixture.add(document, .split, from: 2, to: 3))
    let c = try add(LayoutFixture.add(document, .bubble, at: 6))
    #expect(shown(c)?.upperBound == end - 1)

    // The last nanosecond of `a` is `a`'s, and that of `c` is `c`'s; `b` ends 1 ns short, where the preview ends it.
    let timeline = LayoutTimeline(document: document, take: LayoutFixture.take, timeMap: map, cameraReadable: true)
    let instants = [1, 2, 3].flatMap { [LayoutFixture.output(Double($0)) - 1, LayoutFixture.output(Double($0))] } + [end - 1]
    for τ in instants {
        #expect(LayoutCommands.block(atOutput: τ, in: document, timeMap: map)?.id == timeline.span(atOutput: τ).blockID, "at \(τ)")
    }
    #expect(LayoutCommands.block(atOutput: LayoutFixture.output(2) - 1, in: document, timeMap: map) == a)
    #expect(LayoutCommands.block(atOutput: end - 1, in: document, timeMap: map) == c)
    #expect(LayoutCommands.block(atOutput: LayoutFixture.output(3) - 1, in: document, timeMap: map) == nil)
    // ↑ and ↓ stop once where two blocks touch, and at the end; the recorded change at 3 s of source is at 1 s.
    let points = EditPoints(document: document, timeMap: map, markers: []).all
    #expect(points == [0, LayoutFixture.output(1), LayoutFixture.output(2), LayoutFixture.output(3) - 1, LayoutFixture.output(6), end])

    // Moved again and again, `b` keeps the second it was placed with: 3 s of source, less the 2 ns of decision 9.
    for seconds in [4.0, 3.5, 2.25] {
        let current = try LayoutFixture.block(b.id, in: document)
        let step = try #require(LayoutCommands.move(document, id: b.id, toOutputStart: LayoutFixture.output(seconds), timeMap: map))
        document = try LayoutFixture.applying(step, to: document)
        let moved = try LayoutFixture.block(b.id, in: document)
        #expect(moved.end.nanoseconds - moved.start.nanoseconds == current.end.nanoseconds - current.start.nanoseconds)
        #expect(moved.end.nanoseconds - moved.start.nanoseconds == 2_999_999_998)
        #expect(shown(moved) == LayoutFixture.output(seconds)..<(LayoutFixture.output(seconds + 1) - 1))
    }
}

@Test func aHiddenBlockBecomingABubbleCopiesTheStyleAtItsSourceStart() throws {
    // Hidden whole in a cut, a block has no output start: the style is the take's initial one with its changes up to the
    // block's source start, the design's definition, a change inside the cut too.
    var document = LayoutFixture.document(
        [LayoutFixture.block("l-0000000a", from: 6, to: 6.8), LayoutFixture.block("l-0000000b", from: 7.5, to: 9)],
        sequence: LayoutFixture.threeClips)
    document.camera.changes.append(
        CameraChange(id: "k-00000002", take: LayoutFixture.takeID, t: LayoutFixture.at(7), style: LayoutFixture.custom, origin: .user))
    document = try document.applying(try SequenceCommands.delete(document, clipIDs: ["c-00000002"]).get().changes)
    let map = LayoutFixture.timeMap(document)
    #expect(LayoutCommands.block(atOutput: LayoutFixture.output(5), in: document, timeMap: map) == nil)
    func bubble(_ id: String) throws -> BubbleLayout? {
        let step = try #require(LayoutCommands.setKind(document, id: id, .bubble, timeMap: map))
        return try LayoutFixture.block(id, in: try LayoutFixture.applying(step, to: document)).bubble
    }
    #expect(try bubble("l-0000000a") == BubbleLayout(style: LayoutFixture.recorded))
    #expect(try bubble("l-0000000b") == BubbleLayout(style: LayoutFixture.custom))
}

@Test func layoutLabelsAreTheDesignOnes() {
    // 1c design §13.1 and plan 1c decision 8: written in edit-log.jsonl, so they never change.
    let labels: [(EditLabel, String)] = [
        (.layoutAdd, "layout.add"), (.layoutChange, "layout.change"), (.layoutMove, "layout.move"), (.layoutTrim, "layout.trim"),
        (.layoutDelete, "layout.delete"), (.cameraLayout, "camera.layout"), (.cameraSplit, "camera.split"),
        (.cameraMirror, "camera.mirror"), (.cameraBorder, "camera.border"), (.cameraShadow, "camera.shadow"),
        (.cameraChangesDeleteAll, "camera.changes.deleteAll"), (.styleApply, "style.apply"),
    ]
    for (label, raw) in labels {
        #expect(label.rawValue == raw)
        #expect(EditLabel(rawValue: raw) == label)
    }
    #expect(Array(EditLabel.allCases.suffix(12)) == labels.map(\.0))
}
