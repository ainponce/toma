// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import CoreGraphics
import Testing

@Suite struct EditorLayoutTests {
    @Test func editorWindowSizeRule() {
        #expect(EditorLayout.minimumSize == CGSize(width: 1024, height: 680))
        // The smaller of 1440 × 900 and 85 % of the visible area.
        #expect(EditorLayout.initialSize(visible: CGSize(width: 2560, height: 1440)) == CGSize(width: 1440, height: 900))
        #expect(EditorLayout.initialSize(visible: CGSize(width: 1440, height: 900)) == CGSize(width: 1224, height: 765))
        #expect(EditorLayout.initialSize(visible: CGSize(width: 1512, height: 944)) == CGSize(width: 1285, height: 802))
        // Never smaller than the minimum.
        #expect(EditorLayout.initialSize(visible: CGSize(width: 1280, height: 720)) == CGSize(width: 1088, height: 680))
        #expect(EditorLayout.initialSize(visible: CGSize(width: 800, height: 600)) == CGSize(width: 1024, height: 680))
        #expect(EditorLayout.initialSize(visible: .zero) == EditorLayout.minimumSize)
    }

    @Test func panelAndTimelineMeasures() {
        #expect(EditorLayout.panelWidth == 300)
        #expect(EditorLayout.panelWidthRange == 260.0...380.0)
        #expect(EditorLayout.timelineHeight == 236)
    }

    @Test func timelineHeightRange() {
        #expect(EditorLayout.timelineHeightRange(windowHeight: 900) == 180.0...450.0)
        #expect(EditorLayout.timelineHeightRange(windowHeight: 680) == 180.0...340.0)
        // A window too short for half of it to reach 180 pt still lets the timeline be 180.
        #expect(EditorLayout.timelineHeightRange(windowHeight: 300) == 180.0...180.0)
    }
}
