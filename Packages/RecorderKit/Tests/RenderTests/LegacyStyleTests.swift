// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Render
import Testing

// The legacy edit document stores phase 0's look (`StyleV0`) as `Double`s: converted to what the render draws with,
// they are the same values, bit for bit.

@Test func legacyGradientConvertsToStyleV0Floats() throws {
    guard case let .gradient(start, end, angle) = Background.tomaClassic else {
        Issue.record("tomaClassic is not a gradient")
        return
    }
    let style = StyleV0()
    for (rgba, simd) in [(start, style.gradientStart), (end, style.gradientEnd)] {
        let floats = [Float(rgba.r), Float(rgba.g), Float(rgba.b), Float(rgba.a)]
        #expect(floats.map(\.bitPattern) == [simd.x, simd.y, simd.z, simd.w].map(\.bitPattern))
    }
    #expect(Float(angle).bitPattern == style.gradientAngleDegrees.bitPattern)
    #expect(start == RGBA(127.0 / 255, 90.0 / 255, 240.0 / 255, 1))
    #expect(end == RGBA(44.0 / 255, 177.0 / 255, 188.0 / 255, 1))
}

@Test func legacyPaddingAndCornersAreStyleV0() {
    let take = TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 0), tracks: [])
    let legacy = EditDocument.legacy(take: take, events: []).style
    #expect(legacy.background == .tomaClassic)
    #expect(legacy.padding.bitPattern == StyleV0().paddingFraction.bitPattern)
    #expect(legacy.cornerRadius.bitPattern == StyleV0().cornerRadiusFraction.bitPattern)
}
