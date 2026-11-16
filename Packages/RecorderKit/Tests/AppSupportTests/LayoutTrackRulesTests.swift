// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

@Suite struct LayoutTrackRulesTests {
    @Test func newBlockUsesTheMarksAndTheLastKind() {
        let plain = LayoutTrackRules.newBlock(playhead: 4_000_000_000, click: nil, marks: nil, lastKind: nil)
        #expect(plain.start == 4_000_000_000 && plain.range == nil && plain.kind == .cameraFull)
        let clicked = LayoutTrackRules.newBlock(playhead: 4_000_000_000, click: 9_000_000_000, marks: nil, lastKind: .split)
        #expect(clicked.start == 9_000_000_000 && clicked.range == nil && clicked.kind == .split)
        let marked = LayoutTrackRules.newBlock(playhead: 0, click: nil, marks: 2_000_000_000..<5_000_000_000, lastKind: .bubble)
        #expect(marked.start == 2_000_000_000)
        #expect(marked.range == Optional<Range<Int64>>(Range<Int64>(uncheckedBounds: (2_000_000_000, 5_000_000_000))))
        #expect(marked.kind == .bubble)
        // A click is where the user pointed: the marks do not move it.
        #expect(LayoutTrackRules.newBlock(playhead: 0, click: 7_000_000_000, marks: 2_000_000_000..<5_000_000_000, lastKind: nil).range == nil)
        // An empty range is no range.
        #expect(LayoutTrackRules.newBlock(playhead: 1, click: nil, marks: 3..<3, lastKind: nil).range == nil)
    }
}

@Suite struct LayoutTrackDrawingRulesTests {
    @Test func aDragMakesABlockFromHalfASecond() {
        let second: Int64 = 1_000_000_000
        // Either direction.
        #expect(LayoutTrackRules.creationRange(from: 4 * second, to: 6 * second, duration: 60 * second) == Range<Int64>(uncheckedBounds: (4 * second, 6 * second)))
        #expect(LayoutTrackRules.creationRange(from: 6 * second, to: 4 * second, duration: 60 * second) == Range<Int64>(uncheckedBounds: (4 * second, 6 * second)))
        // 0.5 s is enough, a nanosecond less is not.
        #expect(LayoutTrackRules.creationRange(from: 0, to: 500_000_000, duration: 60 * second) != nil)
        #expect(LayoutTrackRules.creationRange(from: 0, to: 499_999_999, duration: 60 * second) == nil)
        // Cut to the output.
        #expect(LayoutTrackRules.creationRange(from: 58 * second, to: 70 * second, duration: 60 * second) == Range<Int64>(uncheckedBounds: (58 * second, 60 * second)))
        #expect(LayoutTrackRules.creationRange(from: 59_800_000_000, to: 70 * second, duration: 60 * second) == nil)
    }

    @Test func theSplitLabelSaysWhereTheCameraIs() {
        #expect(LayoutTrackRules.labelSide(.start, orientation: .beside) == .left)
        #expect(LayoutTrackRules.labelSide(.end, orientation: .beside) == .right)
        #expect(LayoutTrackRules.labelSide(.start, orientation: .stacked) == .top)
        #expect(LayoutTrackRules.labelSide(.end, orientation: .stacked) == .bottom)
    }

    @Test func eachLayoutHasItsSymbol() {
        #expect(LayoutTrackRules.symbol(.bubble, orientation: .beside) == "pip")
        #expect(LayoutTrackRules.symbol(.screenOnly, orientation: .stacked) == "rectangle")
        #expect(LayoutTrackRules.symbol(.split, orientation: .beside) == "rectangle.split.2x1")
        #expect(LayoutTrackRules.symbol(.split, orientation: .stacked) == "rectangle.split.1x2")
        #expect(LayoutTrackRules.symbol(.cameraOnly, orientation: .beside) == "person.crop.rectangle")
        #expect(LayoutTrackRules.symbol(.cameraFull, orientation: .stacked) == "person.crop.rectangle.fill")
        #expect(LayoutTrackRules.dimmedDiamondOpacity == 0.4)
    }

    @Test func theCameraIsReadableWithOneUsableSegment() {
        func segment(_ index: Int) -> SegmentRecord {
            SegmentRecord(index: index, file: "camera/seg-\(index).mov", startHostTime: HostTime(nanoseconds: 0), droppedFrames: 0, heartbeatFrames: 0)
        }
        func take(_ kinds: [TrackKind]) -> TakeRecord {
            TakeRecord(
                id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 0),
                tracks: kinds.enumerated().map { k, kind in
                    TrackRecord(id: "t\(k)", kind: kind, source: TrackSource(name: "x"), segments: [segment(0), segment(1)])
                })
        }
        #expect(LayoutTrackRules.cameraReadable(take: take([.display, .camera]), availability: { $0.index == 1 ? .present : .empty }))
        #expect(!LayoutTrackRules.cameraReadable(take: take([.display, .camera]), availability: { _ in .unreadable(bytes: 10) }))
        #expect(!LayoutTrackRules.cameraReadable(take: take([.display, .camera]), availability: { _ in .missing }))
        // The screen's segments do not count, and without a camera there is nothing to read.
        #expect(!LayoutTrackRules.cameraReadable(take: take([.display]), availability: { _ in .present }))
    }
}

@Suite struct LayoutPreviewRulesTests {
    private static let base = HostTime(nanoseconds: 5_000_000_000_000)
    private static func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

    private func document(project: LayoutKind = .bubble, blocks: [LayoutBlock] = []) -> EditDocument {
        let take = TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: [])
        var doc = EditDocument.legacy(take: take, events: [])
        doc.sequence = [Clip(id: "c-00000001", take: "take-001", start: Self.base, end: Self.at(20), speed: 1)]
        doc.camera.layout = CameraLayout(kind: project)
        doc.camera.layouts = blocks
        return doc
    }

    private func block(_ id: String, _ kind: LayoutKind, from: Double, to: Double) -> LayoutBlock {
        LayoutBlock(
            id: id, take: "take-001", start: Self.at(from), end: Self.at(to), kind: kind, instant: false,
            bubble: kind == .bubble ? BubbleLayout(style: .default) : nil)
    }

    @Test func aShortcutChangesTheSelectedBlockOrMakesOne() {
        let doc = document(blocks: [block("l-00000001", .split, from: 2, to: 6)])
        #expect(LayoutTrackRules.shortcutAction(selectedBlock: "l-00000001", in: doc) == .change(id: "l-00000001"))
        #expect(LayoutTrackRules.shortcutAction(selectedBlock: nil, in: doc) == .create)
        // A selection the document no longer has is none.
        #expect(LayoutTrackRules.shortcutAction(selectedBlock: "l-gone", in: doc) == .create)
    }

    @Test func theBubbleOverlayEditsWhatRulesAtThePlayhead() {
        let second: Int64 = 1_000_000_000
        let doc = document(blocks: [block("l-0000000b", .bubble, from: 2, to: 6), block("l-0000000c", .split, from: 8, to: 12)])
        let map = TimeMap(sequence: doc.sequence)
        #expect(LayoutTrackRules.bubbleTarget(doc, atOutput: 3 * second, timeMap: map) == .block(id: "l-0000000b"))
        #expect(LayoutTrackRules.bubbleTarget(doc, atOutput: 9 * second, timeMap: map) == LayoutTrackRules.BubbleTarget.none)
        #expect(LayoutTrackRules.bubbleTarget(doc, atOutput: 7 * second, timeMap: map) == .take)
        // With another layout for the project, outside the blocks there is no bubble either.
        let other = document(project: .screenOnly, blocks: [block("l-0000000b", .bubble, from: 2, to: 6)])
        #expect(LayoutTrackRules.bubbleTarget(other, atOutput: 7 * second, timeMap: map) == LayoutTrackRules.BubbleTarget.none)
        #expect(LayoutTrackRules.bubbleTarget(other, atOutput: 3 * second, timeMap: map) == .block(id: "l-0000000b"))
    }
}
