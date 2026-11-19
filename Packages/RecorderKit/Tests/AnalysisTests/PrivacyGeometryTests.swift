// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import ProjectFormat

@testable import Analysis

@Suite struct PrivacyGeometryTests {
    static let base = HostTime(nanoseconds: 5_000_000_000_000)
    static func at(_ s: Double) -> HostTime { base.adding(seconds: s) }

    static func block(keys: [RectKey] = []) -> PrivacyBlock {
        PrivacyBlock(
            id: "p-00000001", take: "take-001", start: at(0), end: at(10), effect: .blur,
            rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), keys: keys, origin: .email)
    }

    @Test func keysInterpolateAndHold() {
        let b = Self.block(keys: [
            RectKey(t: Self.at(3), rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)),
            RectKey(t: Self.at(1), rect: NormalizedRect(x: 0.1, y: 0.3, width: 0.2, height: 0.4)),
        ])
        let mid = PrivacyGeometry.rect(of: b, atSource: Self.at(2))
        #expect(abs(mid.x - 0.3) < 1e-12 && abs(mid.y - 0.4) < 1e-12 && abs(mid.width - 0.2) < 1e-12 && abs(mid.height - 0.3) < 1e-12)
        #expect(PrivacyGeometry.rect(of: b, atSource: Self.at(0.5)) == b.keys.sorted { $0.t < $1.t }[0].rect)
        #expect(PrivacyGeometry.rect(of: b, atSource: Self.at(9)).x == 0.5)
    }

    @Test func noKeysIsTheRect() {
        let b = Self.block()
        #expect(PrivacyGeometry.rect(of: b, atSource: Self.at(4)) == b.rect)
    }

    @Test func contentToLayerCropAndBack() {
        let content = Rect(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
        let layer = Rect(x: 0.15, y: 0.25, width: 0.3, height: 0.4)
        let r = NormalizedRect(x: 0.3, y: 0.2, width: 0.25, height: 0.4)
        let inLayer = PrivacyGeometry.inLayerCrop(r, contentCrop: content, layerCrop: layer)
        let back = PrivacyGeometry.inContent(inLayer, contentCrop: content, layerCrop: layer)
        #expect(abs(back.x - r.x) < 1e-12 && abs(back.y - r.y) < 1e-12 && abs(back.width - r.width) < 1e-12 && abs(back.height - r.height) < 1e-12)
        // x: frame 0.1 + 0.3 * 0.5 = 0.25 -> (0.25 - 0.15) / 0.3
        #expect(abs(inLayer.x - (0.1 / 0.3)) < 1e-12)
    }

    @Test func clampedKeepsInsideAndAMinimum() {
        let a = PrivacyGeometry.clamped(NormalizedRect(x: -0.1, y: 0.9, width: 0.5, height: 0.5))
        #expect(a.x == 0 && a.y == 0.5 && a.width == 0.5 && a.height == 0.5)
        let b = PrivacyGeometry.clamped(NormalizedRect(x: 0.5, y: 0.5, width: 0.001, height: 0.3))
        #expect(b.width == PrivacyGeometry.minimumSide)
    }
}
