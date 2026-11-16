// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppSupport
import ProjectFormat
import Testing

@Suite struct SplitHandleGeometryTests {
    private static let wide = SIMD2<Double>(1920, 1080)
    private static let tall = SIMD2<Double>(1080, 1920)
    private static let padding = 0.05

    private func split(_ output: SIMD2<Double>, side: CameraSide = .end, share: Double? = nil) -> (LayoutGeometry, SplitOrientation) {
        let geometry = CameraLayoutGeometry.geometry(
            kind: .split, split: SplitLayout(side: side, share: share), bubble: nil, output: output, padding: Self.padding,
            cornerRadius: 0.02, screenAspect: 16.0 / 9)
        return (geometry, CameraLayoutGeometry.orientation(output: output))
    }

    @Test func handleSitsInTheGap() {
        for side in [CameraSide.start, .end] {
            let (geometry, orientation) = split(Self.wide, side: side, share: 0.4)
            #expect(orientation == .beside)
            let handle = SplitHandleGeometry.handle(geometry: geometry, orientation: orientation)
            let (screen, camera) = (geometry.screen.rect, geometry.camera.rect)
            let gap = CameraLayoutGeometry.gapFraction * 1080
            // As wide as the gap, which starts where the card on the left ends, and as tall as the cards together.
            #expect(abs(handle.width - gap) < 1e-9)
            let leftEnd = side == .end ? screen.x + screen.width : camera.x + camera.width
            let rightStart = side == .end ? camera.x : screen.x
            #expect(abs(handle.x - leftEnd) < 1e-9 && abs(handle.x + handle.width - rightStart) < 1e-9)
            #expect(abs(handle.y - min(screen.y, camera.y)) < 1e-9)
            #expect(abs(handle.height - (max(screen.y + screen.height, camera.y + camera.height) - min(screen.y, camera.y))) < 1e-9)
        }
    }

    @Test func stackedHandleSitsBetweenTheCards() {
        for side in [CameraSide.start, .end] {
            let (geometry, orientation) = split(Self.tall, side: side, share: 0.4)
            #expect(orientation == .stacked)
            let handle = SplitHandleGeometry.handle(geometry: geometry, orientation: orientation)
            let (screen, camera) = (geometry.screen.rect, geometry.camera.rect)
            let upperEnd = side == .end ? screen.y + screen.height : camera.y + camera.height
            let lowerStart = side == .end ? camera.y : screen.y
            #expect(abs(handle.y - upperEnd) < 1e-9 && abs(handle.y + handle.height - lowerStart) < 1e-9)
            #expect(abs(handle.width - (max(screen.x + screen.width, camera.x + camera.width) - min(screen.x, camera.x))) < 1e-9)
        }
    }

    @Test func theHandleIsAtLeastTwelvePointsToPoint() {
        let handle = Rect(x: 100, y: 10, width: 27, height: 500)
        // 0.5 point per pixel: 27 px are 13.5 points, enough.
        #expect(SplitHandleGeometry.hitRect(of: handle, orientation: .beside, pointsPerUnit: 0.5) == handle)
        // 0.25: 6.75 points, widened around the middle to 12 (48 px).
        let wider = SplitHandleGeometry.hitRect(of: handle, orientation: .beside, pointsPerUnit: 0.25)
        #expect(abs(wider.width - 48) < 1e-9 && abs(wider.x + wider.width / 2 - 113.5) < 1e-9)
        #expect(wider.y == 10 && wider.height == 500)
        let stacked = SplitHandleGeometry.hitRect(of: Rect(x: 0, y: 200, width: 500, height: 27), orientation: .stacked, pointsPerUnit: 0.25)
        #expect(abs(stacked.height - 48) < 1e-9 && abs(stacked.y + stacked.height / 2 - 213.5) < 1e-9 && stacked.width == 500)
        #expect(SplitHandleGeometry.hitWidth == 12)
    }

    @Test func draggingTheHandleGivesTheShare() {
        let area = StageLayout.screenRect(contentAspect: nil, padding: Self.padding, outputSize: Self.wide)
        let gap = CameraLayoutGeometry.gapFraction * 1080
        let length = area.width - gap
        func share(_ x: Double, _ side: CameraSide = .end) -> Double {
            SplitHandleGeometry.share(pointer: SIMD2(x, 500), output: Self.wide, padding: Self.padding, orientation: .beside, side: side)
        }
        // The pointer at the gap's middle when the camera, on the right, has 34 % of the length.
        #expect(abs(share(area.x + area.width - gap / 2 - 0.34 * length) - 0.34) < 1e-12)
        // On the left, the camera has what is left of the pointer.
        #expect(abs(share(area.x + gap / 2 + 0.34 * length, .start) - 0.34) < 1e-12)
        // Out of the limits, 0.25 and 0.60.
        #expect(share(area.x) == 0.60)
        #expect(share(area.x + area.width) == 0.25)
        #expect(share(area.x + 10) == 0.60)
        #expect(share(area.x + area.width - 10, .start) == 0.60)
        #expect(share(area.x + 10, .start) == 0.25)
        // 1:1: the layout with that share has the handle's gap where the pointer was.
        let pointer = area.x + area.width - gap / 2 - 0.4 * length
        let (geometry, orientation) = split(Self.wide, share: share(pointer))
        let handle = SplitHandleGeometry.handle(geometry: geometry, orientation: orientation)
        #expect(abs(handle.x + handle.width / 2 - pointer) < 1e-9)
    }

    @Test func stackedShareFollowsTheVerticalPointer() {
        let area = StageLayout.screenRect(contentAspect: nil, padding: Self.padding, outputSize: Self.tall)
        let gap = CameraLayoutGeometry.gapFraction * 1080
        let length = area.height - gap
        let pointer = area.y + area.height - gap / 2 - 0.45 * length
        let value = SplitHandleGeometry.share(
            pointer: SIMD2(300, pointer), output: Self.tall, padding: Self.padding, orientation: .stacked, side: .end)
        #expect(abs(value - 0.45) < 1e-12)
        // The horizontal position does not count.
        #expect(SplitHandleGeometry.share(
            pointer: SIMD2(5, pointer), output: Self.tall, padding: Self.padding, orientation: .stacked, side: .end) == value)
    }

    @Test func theLabelIsTheWholePercent() {
        #expect(SplitHandleGeometry.percent(0.34) == 34)
        #expect(SplitHandleGeometry.percent(0.3449) == 34)
        #expect(SplitHandleGeometry.percent(0.345) == 35)
        #expect(SplitHandleGeometry.percent(0.25) == 25)
        #expect(SplitHandleGeometry.percent(0.6) == 60)
    }

    @Test func stageUnitsAreOverTheOutputsHeight() {
        let rect = SplitHandleGeometry.stageUnits(Rect(x: 192, y: 54, width: 960, height: 540), output: Self.wide)
        #expect(rect == Rect(x: 192.0 / 1080, y: 0.05, width: 960.0 / 1080, height: 0.5))
    }
}
