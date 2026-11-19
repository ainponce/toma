// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import Testing

// `deviceFrame-1`'s geometry (phase 2 design §6.7, plan 2b decision 10): where each part of a device goes around its
// screen, and the largest device of the content's aspect inside the padding.

private func isClose(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }

private func isClose(_ a: Rect, _ b: Rect, _ tolerance: Double = 1e-9) -> Bool {
    isClose(a.x, b.x, tolerance) && isClose(a.y, b.y, tolerance) && isClose(a.width, b.width, tolerance)
        && isClose(a.height, b.height, tolerance)
}

private func contains(_ outer: Rect, _ inner: Rect, _ tolerance: Double = 1e-9) -> Bool {
    inner.x >= outer.x - tolerance && inner.y >= outer.y - tolerance
        && inner.x + inner.width <= outer.x + outer.width + tolerance
        && inner.y + inner.height <= outer.y + outer.height + tolerance
}

@Test func iPhoneMeasures() throws {
    let screen = Rect(x: 100, y: 50, width: 300, height: 650)
    let rects = StageLayout.deviceRects(around: screen, model: .iPhone)
    #expect(rects.screen == screen)
    // The bezel (0.045 of the width) and the band (0.012) on every side.
    let edge = (0.045 + 0.012) * 300
    #expect(isClose(rects.body, Rect(x: 100 - edge, y: 50 - edge, width: 300 + 2 * edge, height: 650 + 2 * edge)))
    #expect(isClose(rects.bandWidth, 0.012 * 300))
    // The outer radius, 0.16 of the outer width; the screen's, concentric with it.
    #expect(isClose(rects.bodyCornerRadius, 0.16 * (300 + 2 * edge)))
    #expect(isClose(rects.screenCornerRadius, rects.bodyCornerRadius - edge))
    // The island: 0.30 of the width by 0.034 of the height, centred, 0.018 of the height under the screen's top.
    let island = try #require(rects.cutout)
    #expect(isClose(island, Rect(x: 100 + (300 - 90) / 2, y: 50 + 11.7, width: 90, height: 22.1)))
    // Four side buttons 2.4 wide, outside the body: action, volume up and down on the left, power on the right, at
    // their heights from the body's top.
    #expect(rects.buttons.count == 4)
    let top = rects.body.y, left = rects.body.x - 2.4, right = rects.body.x + rects.body.width
    let expected = [
        Rect(x: left, y: top + 0.13 * 650, width: 2.4, height: 0.04 * 650),
        Rect(x: left, y: top + 0.20 * 650, width: 2.4, height: 0.07 * 650),
        Rect(x: left, y: top + 0.29 * 650, width: 2.4, height: 0.07 * 650),
        Rect(x: right, y: top + 0.24 * 650, width: 2.4, height: 0.11 * 650),
    ]
    for (button, rect) in zip(rects.buttons, expected) {
        #expect(isClose(button, rect), "\(button) is not \(rect)")
    }
    #expect(rects.base == nil)
    // What it takes: the body and the buttons beside it.
    #expect(isClose(rects.bounds, Rect(x: left, y: top, width: rects.body.width + 4.8, height: rects.body.height)))
}

@Test func iPhoneTurnsWithAWideContent() throws {
    // A screen wider than tall: the phone on its side, its top to the left; its measures by its own width, the short side.
    let screen = Rect(x: 0, y: 0, width: 650, height: 300)
    let rects = StageLayout.deviceRects(around: screen, model: .iPhone)
    let portrait = StageLayout.deviceRects(around: Rect(x: 0, y: 0, width: 300, height: 650), model: .iPhone)
    #expect(isClose(rects.bodyCornerRadius, portrait.bodyCornerRadius) && isClose(rects.bandWidth, portrait.bandWidth))
    #expect(isClose(rects.body.width, portrait.body.height) && isClose(rects.body.height, portrait.body.width))
    // The island at the left, centred from top to bottom.
    let island = try #require(rects.cutout)
    #expect(isClose(island, Rect(x: 11.7, y: (300 - 90) / 2, width: 22.1, height: 90)))
    // The left side's buttons go under the body, the power button over it, from the body's left.
    let left = rects.body.x, below = rects.body.y + rects.body.height, above = rects.body.y - 2.4
    #expect(isClose(rects.buttons[0], Rect(x: left + 0.13 * 650, y: below, width: 0.04 * 650, height: 2.4)))
    #expect(isClose(rects.buttons[3], Rect(x: left + 0.24 * 650, y: above, width: 0.11 * 650, height: 2.4)))
    #expect(isClose(rects.bounds, Rect(x: rects.body.x, y: above, width: rects.body.width, height: rects.body.height + 4.8)))
}

@Test func iPadMeasures() {
    let screen = Rect(x: 20, y: 30, width: 600, height: 800)
    let rects = StageLayout.deviceRects(around: screen, model: .iPad)
    // The bezel (0.05 of the shorter side) and the iPhone's band (0.01 of it) on every side.
    let edge = (0.05 + 0.01) * 600
    #expect(isClose(rects.body, Rect(x: 20 - edge, y: 30 - edge, width: 600 + 2 * edge, height: 800 + 2 * edge)))
    #expect(isClose(rects.bandWidth, 6))
    // The outer radius, 0.06 of the body's shorter side; the screen's, concentric.
    #expect(isClose(rects.bodyCornerRadius, 0.06 * (600 + 2 * edge)))
    #expect(isClose(rects.screenCornerRadius, rects.bodyCornerRadius - edge))
    #expect(rects.cutout == nil && rects.buttons.isEmpty && rects.base == nil)
    #expect(rects.bounds == rects.body)
    // On its side, the same measures by the shorter side.
    let wide = StageLayout.deviceRects(around: Rect(x: 0, y: 0, width: 800, height: 600), model: .iPad)
    #expect(isClose(wide.bodyCornerRadius, rects.bodyCornerRadius) && isClose(wide.body.height, rects.body.width))
}

@Test func macBookMeasures() throws {
    let screen = Rect(x: 100, y: 100, width: 1000, height: 625)
    let rects = StageLayout.deviceRects(around: screen, model: .macBook)
    // The bezel, 0.02 of the width at the sides and the bottom and 0.035 at the top, inside a rim of 0.004.
    let side = 0.02 * 1000 + 4, top = 0.035 * 1000 + 4
    #expect(isClose(rects.body, Rect(x: 100 - side, y: 100 - top, width: 1000 + 2 * side, height: 625 + top + side)))
    #expect(isClose(rects.bandWidth, 4))
    // The lid's top corners; the screen's are square.
    #expect(isClose(rects.bodyCornerRadius, 20) && rects.screenCornerRadius == 0)
    // The notch, 0.11 by 0.025 of the width, centred at the screen's top.
    let notch = try #require(rects.cutout)
    #expect(isClose(notch, Rect(x: 100 + (1000 - 110) / 2, y: 100, width: 110, height: 25)))
    #expect(rects.buttons.isEmpty)
    // The base under the lid: 1.12 of its width and 0.035 of its height, centred, its front half its height round.
    let base = try #require(rects.base)
    let lid = rects.body
    #expect(isClose(base, Rect(
        x: lid.x + lid.width / 2 - 0.56 * lid.width, y: lid.y + lid.height, width: 1.12 * lid.width, height: 0.035 * lid.height)))
    #expect(isClose(rects.baseFrontRadius, base.height / 2))
    #expect(isClose(rects.bounds, Rect(x: base.x, y: lid.y, width: base.width, height: lid.height + base.height)))
}

@Test func deviceFitsInsideThePadding() throws {
    let padding = 0.06
    for model in DeviceModel.allCases {
        for aspect in [9.0 / 19.5, 3.0 / 4, 16.0 / 10] {
            for output in [SIMD2(1920.0, 1080), SIMD2(1080.0, 1920), SIMD2(1080.0, 1080)] {
                let label = "\(model) \(aspect) in \(output)"
                let rects = try #require(
                    StageLayout.deviceRects(contentAspect: aspect, padding: padding, outputSize: output, model: model), "\(label)")
                // The screen is of the content's aspect, and the device around it is the one of `deviceRects(around:)`.
                #expect(isClose(rects.screen.width / rects.screen.height, aspect), "\(label)")
                #expect(rects == StageLayout.deviceRects(around: rects.screen, model: model), "\(label)")
                // Its bounds are inside the margin, centred, and touch it along one axis.
                let margin = padding * output.x
                let room = Rect(x: margin, y: margin, width: output.x - 2 * margin, height: output.y - 2 * margin)
                let bounds = rects.bounds
                #expect(contains(room, bounds, 1e-6), "\(label): \(bounds)")
                #expect(isClose(bounds.x + bounds.width / 2, output.x / 2, 1e-6), "\(label)")
                #expect(isClose(bounds.y + bounds.height / 2, output.y / 2, 1e-6), "\(label)")
                #expect(isClose(bounds.width, room.width, 1e-6) || isClose(bounds.height, room.height, 1e-6), "\(label)")
            }
        }
    }
    // No room inside the padding: none.
    #expect(StageLayout.deviceRects(contentAspect: 1, padding: 0.5, outputSize: SIMD2(1280, 720), model: .iPhone) == nil)
    // Without an aspect, the room's.
    let room = try #require(StageLayout.deviceRects(contentAspect: nil, padding: 0.1, outputSize: SIMD2(1280, 720), model: .iPad))
    #expect(isClose(room.screen.width / room.screen.height, (1280 - 256) / (720 - 256.0)))
}
