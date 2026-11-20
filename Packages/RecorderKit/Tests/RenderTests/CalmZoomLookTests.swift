// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
// @testable for `CalmZoomLook`.
@testable import Render
import simd
import Testing

/// The calm zoom's look (phase 3 design §6, plan 3b decision 7, `calmZoom-1` and `loupe-1`), worked out on the CPU: the
/// output's point, the mipmap level Dim blurs at and where the loupe's lens samples what is under it.

/// The look's numbers, worked out on the CPU.
@Suite struct CalmZoomLookTests {
    @Test func pointsFollowTheShortSide() {
        #expect(CalmZoomLook.point(outputSize: SIMD2(1920, 1080)) == 1)
        #expect(CalmZoomLook.point(outputSize: SIMD2(3840, 2160)) == 2)
        #expect(CalmZoomLook.point(outputSize: SIMD2(1080, 1920)) == 1)
        #expect(abs(CalmZoomLook.point(outputSize: SIMD2(1280, 720)) - 2.0 / 3) < 1e-12)
        #expect(CalmZoomLook.id == "calmZoom-1" && CalmZoomLook.loupeID == "loupe-1")
    }

    @Test func dimBlursAtTheLevelOfFourTexels() {
        // σ 8 pt of each output, in its pixels: the first level at which it is at most 4 texels.
        #expect(CalmZoomLook.dimBlurLevel(sigma: 8, size: SIMD2(1920, 1080)) == 1)
        #expect(CalmZoomLook.dimBlurLevel(sigma: 16, size: SIMD2(3840, 2160)) == 2)
        #expect(CalmZoomLook.dimBlurLevel(sigma: 8 * 720 / 1080, size: SIMD2(1280, 720)) == 1)
        #expect(CalmZoomLook.dimBlurLevel(sigma: 4, size: SIMD2(1920, 1080)) == 0)
        #expect(CalmZoomLook.dimBlurLevel(sigma: 3, size: SIMD2(640, 360)) == 0)
        // Never past the last level of the size.
        #expect(CalmZoomLook.dimBlurLevel(sigma: 10_000, size: SIMD2(8, 4)) == 3)
        #expect(CalmZoomLook.dimBlurLevel(sigma: .nan, size: SIMD2(1920, 1080)) == 0)
    }

    @Test func lensSamplingInvertsTheMagnification() {
        let c = SIMD2(640.0, 360.0), r = 100.0
        // Inside 85 % of the circle: c + (p − c) / m.
        for d in [SIMD2(0.0, 0.0), SIMD2(30, -40), SIMD2(-84, 0), SIMD2(0, 84.9), SIMD2(50, 60)] {
            let sample = CalmZoomLook.lensSample(c + d, center: c, radius: r, shape: .circle, magnification: 2)
            #expect(simd_length(sample - (c + d / 2)) < 1e-9, "\(d): \(sample)")
        }
        // In the outer band, up to 8 % farther out, continuous at 0.85 r and growing out to the edge.
        let at85 = CalmZoomLook.lensSample(c + SIMD2(85, 0), center: c, radius: r, shape: .circle, magnification: 2)
        #expect(abs(at85.x - (c.x + 42.5)) < 1e-9)
        let justPast = CalmZoomLook.lensSample(c + SIMD2(85.001, 0), center: c, radius: r, shape: .circle, magnification: 2)
        #expect(abs(justPast.x - at85.x) < 1e-3)
        let edge = CalmZoomLook.lensSample(c + SIMD2(0, -100), center: c, radius: r, shape: .circle, magnification: 2)
        #expect(abs(edge.y - (c.y - 50 * 1.08)) < 1e-9 && abs(edge.x - c.x) < 1e-9, "\(edge)")
        let between = CalmZoomLook.lensSample(c + SIMD2(92.5, 0), center: c, radius: r, shape: .circle, magnification: 2)
        #expect(abs(between.x - (c.x + 46.25 * (1 + 0.08 * 0.25))) < 1e-9, "\(between)")
        var last = 0.0
        for x in stride(from: 80.0, through: 100, by: 0.5) {
            let sample = CalmZoomLook.lensSample(c + SIMD2(x, 0), center: c, radius: r, shape: .circle, magnification: 1.5)
            #expect(sample.x - c.x > last)
            last = sample.x - c.x
        }
        // Outside the lens, p itself.
        let outside = c + SIMD2(72, 72)
        #expect(CalmZoomLook.lensSample(outside, center: c, radius: r, shape: .circle, magnification: 2) == outside)

        // The rounded rectangle: half its size (1.5 r, r), corners of 0.25 r, its band 0.15 r inside its edge.
        #expect(CalmZoomLook.lensHalfSize(radius: r, shape: .roundedRect) == SIMD2(150, 100))
        #expect(CalmZoomLook.lensHalfSize(radius: r, shape: .circle) == SIMD2(100, 100))
        #expect(CalmZoomLook.lensCorner(radius: r, shape: .roundedRect) == 25)
        #expect(CalmZoomLook.lensCorner(radius: r, shape: .circle) == 100)
        let wide = c + SIMD2(130, 0)
        let inside = CalmZoomLook.lensSample(wide, center: c, radius: r, shape: .roundedRect, magnification: 2)
        #expect(simd_length(inside - (c + SIMD2(65, 0))) < 1e-9, "\(inside)")
        let rim = CalmZoomLook.lensSample(c + SIMD2(150, 0), center: c, radius: r, shape: .roundedRect, magnification: 2)
        #expect(abs(rim.x - (c.x + 75 * 1.08)) < 1e-9, "\(rim)")
        // Past the circle's radius, still in the rectangle; its corner cut.
        #expect(CalmZoomLook.lensSample(c + SIMD2(140, 0), center: c, radius: r, shape: .circle, magnification: 2) == c + SIMD2(140, 0))
        let corner = c + SIMD2(149, 99)
        #expect(CalmZoomLook.lensSample(corner, center: c, radius: r, shape: .roundedRect, magnification: 2) == corner)
    }

    @Test func theLensBoxKeepsItsSizeInsideTheTarget() {
        let target = SIMD2(1280, 720), half = SIMD2(288.0, 288.0), toTarget = SIMD2(1.0, 1.0)
        let reach = half * 1.08 + 1
        for x in stride(from: -300.0, through: 1580, by: 13.37) {
            for y in stride(from: -300.0, through: 1020, by: 11.71) {
                let c = SIMD2(x, y)
                guard let box = CalmZoomLook.lensBox(halfSize: half, center: c, toTarget: toTarget, targetSize: target) else {
                    // None of it in the target.
                    #expect(x + reach.x <= 0 || y + reach.y <= 0 || x - reach.x >= 1280 || y - reach.y >= 720, "\(c)")
                    continue
                }
                // One size wherever it is, inside the target, holding all of the lens's reach that is in the target.
                #expect(box.size.width == 626 && box.size.height == 626, "\(c): \(box)")
                #expect(box.origin.x >= 0 && box.origin.y >= 0 && box.origin.x + 626 <= 1280 && box.origin.y + 626 <= 720, "\(c)")
                #expect(Double(box.origin.x) <= max(x - reach.x, 0) && Double(box.origin.y) <= max(y - reach.y, 0), "\(c)")
                #expect(Double(box.origin.x + 626) >= min(x + reach.x, 1280) && Double(box.origin.y + 626) >= min(y + reach.y, 720), "\(c)")
            }
        }
        // Wider than the target: cut to it on that axis.
        let wide = CalmZoomLook.lensBox(halfSize: SIMD2(432, 288), center: SIMD2(360, 640), toTarget: toTarget, targetSize: SIMD2(720, 1280))
        #expect(wide?.origin.x == 0 && wide?.size.width == 720 && wide?.size.height == 626)
        // In the target's pixels, at another size.
        let half4K = CalmZoomLook.lensBox(halfSize: half, center: SIMD2(640, 360), toTarget: SIMD2(3, 3), targetSize: SIMD2(3840, 2160))
        let reach4K: Double = 288 * 1.08 * 3 + 1
        #expect(half4K?.size.width == Int((2 * reach4K).rounded(.up)) + 1)
    }

    @Test func theFocusIsDrawnWithItsCornersAndTheLooksNumbers() {
        let size = SIMD2(1920, 1080)
        let focus = Rect(x: 100, y: 200, width: 400, height: 300)
        let highlight = CalmZoomLook.focusUniforms(.highlight, amount: 0.5, focus: focus, outputSize: size)
        #expect(highlight.focusOrigin == SIMD2(100, 200) && highlight.focusSize == SIMD2(400, 300))
        #expect(highlight.cornerRadius == 12 && highlight.amount == 0.5 && abs(highlight.darken - 0.2) < 1e-7)
        #expect(highlight.ring == 3 && abs(highlight.ringOpacity - 0.9) < 1e-7)
        #expect(highlight.glowOpacity == 0.25 && highlight.glowSigma == 6)
        let dim = CalmZoomLook.focusUniforms(.dim, amount: 1, focus: focus, outputSize: SIMD2(3840, 2160))
        #expect(abs(dim.darken - 0.6) < 1e-7 && dim.transition == 48 && dim.cornerRadius == 24 && dim.ring == 0)
        // A focus thinner than its corners: at most half its shorter side.
        let thin = CalmZoomLook.focusUniforms(.highlight, amount: 1, focus: Rect(x: 0, y: 0, width: 300, height: 10), outputSize: size)
        #expect(thin.cornerRadius == 5)
    }
}
