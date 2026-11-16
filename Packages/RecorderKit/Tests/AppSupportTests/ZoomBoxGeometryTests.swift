// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat
import Testing

@Suite struct ZoomBoxGeometryTests {
    /// A 16:9 stage, 16/9 wide and 1 tall (stage units).
    private let stage = SIMD2(16.0 / 9, 1.0)
    private var whole: Rect { Rect(x: 0, y: 0, width: stage.x, height: stage.y) }

    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    @Test func boxIsTheVisibleCropOverTheScreen() {
        let box = ZoomBoxGeometry.box(focus: SIMD2(0.5, 0.5), depth: 2, screen: whole, stage: stage)
        #expect(close(box.width, stage.x / 2) && close(box.height, stage.y / 2))
        #expect(close(box.x + box.width / 2, stage.x / 2) && close(box.y + box.height / 2, stage.y / 2))
    }

    @Test func boxOverAPaddedScreenStaysInsideIt() {
        let screen = Rect(x: 0.2, y: 0.1, width: 1.2, height: 0.8)
        let box = ZoomBoxGeometry.box(focus: SIMD2(0, 0), depth: 2, screen: screen, stage: stage)
        #expect(close(box.x, 0.2) && close(box.y, 0.1))
    }

    @Test func draggingTheBoxStaysOnTheScreen() {
        let box = ZoomBoxGeometry.box(focus: SIMD2(0.5, 0.5), depth: 2, screen: whole, stage: stage)
        let focus = ZoomBoxGeometry.focus(afterDragging: box, by: SIMD2(10, 10), screen: whole, stage: stage)
        // The box touches the right and bottom edges: its centre is a quarter of the stage from them.
        #expect(close(focus.x, 0.75) && close(focus.y, 0.75))
        let back = ZoomBoxGeometry.focus(afterDragging: box, by: SIMD2(-10, -10), screen: whole, stage: stage)
        #expect(close(back.x, 0.25) && close(back.y, 0.25))
        let little = ZoomBoxGeometry.focus(afterDragging: box, by: SIMD2(0.1, 0), screen: whole, stage: stage)
        #expect(close(little.x, 0.5 + 0.1 / stage.x) && close(little.y, 0.5))
    }

    @Test func cornerDragKeepsTheAspectAndTheDepthRange() {
        let box = ZoomBoxGeometry.box(focus: SIMD2(0.5, 0.5), depth: 2, screen: whole, stage: stage)
        let center = SIMD2(box.x + box.width / 2, box.y + box.height / 2)
        // A quarter of the stage's width: 4×.
        let small = ZoomBoxGeometry.depth(
            afterDraggingCorner: box, to: center + SIMD2(stage.x / 8, stage.y / 8), screen: whole, stage: stage)
        #expect(close(small, 4))
        // Smaller than that stays at 4×.
        #expect(ZoomBoxGeometry.depth(afterDraggingCorner: box, to: center, screen: whole, stage: stage) == 4)
        // As big as the stage: 1.25×.
        let big = ZoomBoxGeometry.depth(afterDraggingCorner: box, to: center + SIMD2(stage.x, stage.y), screen: whole, stage: stage)
        #expect(big == 1.25)
        // A corner pulled far along one axis only still keeps the aspect: the wider of the two rules.
        let wide = ZoomBoxGeometry.depth(afterDraggingCorner: box, to: center + SIMD2(stage.x / 4, 0), screen: whole, stage: stage)
        #expect(close(wide, 2))
    }
}
