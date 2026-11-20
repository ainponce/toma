// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Testing

@Suite struct AnnotationKeysTests {
    @Test func arrowsNudgeOnePointAndShiftTen() {
        #expect(AnnotationKeys.nudge(for: .step(frames: 1)) == SIMD2(1, 0))
        #expect(AnnotationKeys.nudge(for: .step(frames: -1)) == SIMD2(-1, 0))
        #expect(AnnotationKeys.nudge(for: .stepSeconds(-1)) == SIMD2(-10, 0))
        #expect(AnnotationKeys.nudge(for: .stepSeconds(1)) == SIMD2(10, 0))
        #expect(AnnotationKeys.nudge(for: .previousEditPoint) == SIMD2(0, -1))
        #expect(AnnotationKeys.nudge(for: .nextEditPoint) == SIMD2(0, 1))
        #expect(AnnotationKeys.nudge(for: .nudgeVertically(points: -10)) == SIMD2(0, -10))
        #expect(AnnotationKeys.nudge(for: .nudgeVertically(points: 10)) == SIMD2(0, 10))
    }

    @Test func otherCommandsDoNotNudge() {
        for command: EditorCommand in [.playPause, .split, .delete, .nudge(frames: 1), .start, .end, .shuttle(1), .selectAll, .deselect] {
            #expect(AnnotationKeys.nudge(for: command) == nil, "\(command)")
        }
    }

    @Test func nudgeVerticallyIsAnEditThatRepeats() {
        #expect(EditorCommand.nudgeVertically(points: 10).edits)
        #expect(EditorCommand.nudgeVertically(points: -10).repeats)
    }
}
