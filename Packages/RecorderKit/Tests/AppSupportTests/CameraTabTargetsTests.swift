// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Analysis
import Foundation
import ProjectFormat
import Testing
// Not @testable: the app uses only the public API.
import Editing

@Suite struct CameraTabTargetsTests {
    private static let takeID = "take-001"
    private static let base = HostTime(nanoseconds: 5_000_000_000_000)
    private static func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }
    private static func output(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }
    private static let circle = CameraStyle(shape: .circle, size: CameraStyle.medium, anchor: .topLeading)

    private static func take() -> TakeRecord {
        TakeRecord(id: takeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: [])
    }

    /// 20 s of one take; a Bubble block at [2, 4) s, a Split block at [8, 10) s; changes at 5 s and 9 s (inside the Split).
    private static func document() -> EditDocument {
        var document = EditDocument.legacy(take: take(), events: [])
        document.sequence = [Clip(id: "c-00000001", take: takeID, start: base, end: at(20), speed: 1)]
        document.camera = CameraPlan(
            show: true, initial: [takeID: .default],
            changes: [
                CameraChange(id: "k-00000001", take: takeID, t: at(5), style: circle, origin: .recorded),
                CameraChange(id: "k-00000002", take: takeID, t: at(9), style: circle, origin: .user),
            ],
            layouts: [
                LayoutBlock(id: "l-00000001", take: takeID, start: at(2), end: at(4), kind: .bubble, instant: false, bubble: BubbleLayout(style: circle)),
                LayoutBlock(id: "l-00000002", take: takeID, start: at(8), end: at(10), kind: .split, instant: false, split: SplitLayout(side: .end)),
            ])
        return document
    }

    @Test func editTargetsFollowSelectionAndPlayhead() {
        let document = Self.document()
        let map = TimeMap(sequence: document.sequence)
        // A selected block, or none.
        #expect(CameraTabTargets.layout(document, selectedBlock: "l-00000002", timeMap: map) == .block(id: "l-00000002", output: Self.output(8)))
        #expect(CameraTabTargets.layout(document, selectedBlock: nil, timeMap: map) == .project)
        #expect(CameraTabTargets.layout(document, selectedBlock: "l-ffffffff", timeMap: map) == .project)
        // The bubble: the selected Bubble block; a selected Split gives what 1b edits.
        #expect(CameraTabTargets.bubble(document, selectedBlock: "l-00000001", atOutput: Self.output(15), timeMap: map) == .block(id: "l-00000001", output: Self.output(2)))
        #expect(CameraTabTargets.bubble(document, selectedBlock: "l-00000002", atOutput: Self.output(1), timeMap: map) == .initial)
        // No selection: the playhead in a Bubble block, before the first change, after it, and in a Split block.
        #expect(CameraTabTargets.bubble(document, selectedBlock: nil, atOutput: Self.output(3), timeMap: map) == .block(id: "l-00000001", output: Self.output(2)))
        #expect(CameraTabTargets.bubble(document, selectedBlock: nil, atOutput: Self.output(1), timeMap: map) == .initial)
        #expect(CameraTabTargets.bubble(document, selectedBlock: nil, atOutput: Self.output(6), timeMap: map) == .change(id: "k-00000001", output: Self.output(5)))
        #expect(CameraTabTargets.bubble(document, selectedBlock: nil, atOutput: Self.output(9.5), timeMap: map) == .change(id: "k-00000002", output: Self.output(9)))
    }

    @Test func rowsInsideABlockAreMarkedHidden() {
        let document = Self.document()
        let map = TimeMap(sequence: document.sequence)
        let timeline = LayoutTimeline(document: document, take: Self.take(), timeMap: map, cameraReadable: true)
        let rows = CameraChangeList.rows(document, timeMap: map, layouts: timeline)
        #expect(rows.map(\.id) == ["k-00000001", "k-00000002"])
        #expect(rows[0].hiddenBy == nil)
        #expect(rows[1].hiddenBy == CameraChangeRow.HiddenBy(blockID: "l-00000002", output: Self.output(8), kind: .split))
        // Without the timeline, as 1b calls it, nothing is hidden.
        #expect(CameraChangeList.rows(document, timeMap: map).allSatisfy { $0.hiddenBy == nil })
    }
}
