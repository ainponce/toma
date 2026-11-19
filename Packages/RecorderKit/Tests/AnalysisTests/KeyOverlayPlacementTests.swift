// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import Testing

@testable import Analysis

@Suite struct KeyOverlayPlacementTests {
    let box = SIMD2(300.0, 80.0)
    func plan(_ position: KeyOverlayPosition = .bottomCenter) -> KeyOverlayPlan {
        KeyOverlayPlan(mode: .all, position: position, size: .medium)
    }
    func captions(show: Bool = true, size: OverlaySize = .medium, at position: CaptionPosition = .bottom) -> CaptionPlan {
        var style = CaptionStyle.default
        style.size = size
        style.position = position
        return CaptionPlan(show: show, style: style)
    }

    @Test func keysSitAboveBottomCaptions() {
        let size = SIMD2(1080, 1920)
        let rect = KeyOverlayPlacement.rect(boxSize: box, keys: plan(), captions: captions(size: .large), outputSize: size)
        let reserved = CaptionMetrics.reservedHeight(captions(size: .large).style, outputSize: size)
        #expect(abs((rect.y + rect.height) - (1920 - reserved - 0.02 * 1080)) < 1e-9)
    }

    @Test func keysGoBelowTopCaptions() {
        let size = SIMD2(1920, 1080)
        let c = captions(size: .large, at: .top)
        let rect = KeyOverlayPlacement.rect(boxSize: box, keys: plan(.top), captions: c, outputSize: size)
        #expect(abs(rect.y - (CaptionMetrics.reservedHeight(c.style, outputSize: size) + 0.02 * 1080)) < 1e-9)
        // Captions at the other edge change nothing.
        let other = KeyOverlayPlacement.rect(boxSize: box, keys: plan(.top), captions: captions(at: .bottom), outputSize: size)
        #expect(other.y == 108)
    }

    @Test func theTenPercentIsTheFloor() {
        // Even small captions reserve more than 10 % at 16:9 (the margin and two lines), so the keys go above them;
        // captions at the other edge, or off, leave the keys at the 10 %.
        let size = SIMD2(1920, 1080)
        let small = captions(size: .small)
        let reserved = CaptionMetrics.reservedHeight(small.style, outputSize: size) + 0.02 * 1080
        #expect(reserved > 108)
        let above = KeyOverlayPlacement.rect(boxSize: box, keys: plan(), captions: small, outputSize: size)
        #expect(abs((above.y + above.height) - (1080 - reserved)) < 1e-9)
        let other = KeyOverlayPlacement.rect(boxSize: box, keys: plan(), captions: captions(size: .small, at: .top), outputSize: size)
        #expect(other.y + other.height == 972)
    }

    @Test func captionsOffLeaveTheKeysWhereTheyAre() {
        let size = SIMD2(1080, 1920)
        let rect = KeyOverlayPlacement.rect(boxSize: box, keys: plan(), captions: captions(show: false, size: .large), outputSize: size)
        #expect(rect.y + rect.height == 1920 - 192)
    }

    @Test func sizesAndMarginsAreTheDesigns() {
        let size = SIMD2(1920, 1080)
        #expect(KeyOverlayPlacement.capHeight(.small, outputSize: size) == 0.045 * 1080)
        #expect(KeyOverlayPlacement.capHeight(.medium, outputSize: size) == 0.06 * 1080)
        #expect(KeyOverlayPlacement.capHeight(.large, outputSize: size) == 0.075 * 1080)
        let off = captions(show: false)
        let center = KeyOverlayPlacement.rect(boxSize: box, keys: plan(), captions: off, outputSize: size)
        #expect(center.x == (1920 - 300) / 2 && center.y + center.height == 972)
        let left = KeyOverlayPlacement.rect(boxSize: box, keys: plan(.bottomLeading), captions: off, outputSize: size)
        #expect(left.x == 108)
        let right = KeyOverlayPlacement.rect(boxSize: box, keys: plan(.bottomTrailing), captions: off, outputSize: size)
        #expect(right.x + right.width == 1920 - 108)
        let top = KeyOverlayPlacement.rect(boxSize: box, keys: plan(.top), captions: off, outputSize: size)
        #expect(top.y == 108 && top.x == center.x)
    }
}
