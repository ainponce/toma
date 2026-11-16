// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
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
