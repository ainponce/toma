// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat
import Testing

@Suite struct ZoomPanelRulesTests {
    private static func event(_ kind: InputEvent.Kind, at ns: UInt64 = 1_000) -> InputEvent {
        InputEvent(t: HostTime(nanoseconds: ns), kind: kind)
    }

    @Test func holdWhileTypingNeedsKeyActivity() {
        let moving = [Self.event(.cursor(x: 1, y: 2)), Self.event(.mouseDown(.left, x: 1, y: 2))]
        #expect(!ZoomPanelRules.canHoldWhileTyping(events: []))
        #expect(!ZoomPanelRules.canHoldWhileTyping(events: moving))
        #expect(ZoomPanelRules.canHoldWhileTyping(events: moving + [Self.event(.keyActivity, at: 2_000)]))
    }

    @Test func clicksAreMouseDowns() {
        let onlyCursor = [Self.event(.cursor(x: 1, y: 2)), Self.event(.mouseUp(.left, x: 1, y: 2)), Self.event(.keyActivity)]
        #expect(!ZoomPanelRules.hasClicks(events: onlyCursor))
        #expect(ZoomPanelRules.hasClicks(events: onlyCursor + [Self.event(.mouseDown(.left, x: 1, y: 2))]))
    }

    @Test func zoomSpeedsAreTheDesignSprings() {
        #expect(ZoomSpeed.allCases == [.slow, .medium, .fast])
        #expect(ZoomSpeed.slow.spring == SpringSpec(damping: 1.0, response: 1.00))
        #expect(ZoomSpeed.medium.spring == SpringSpec(damping: 1.0, response: 0.70))
        #expect(ZoomSpeed.fast.spring == SpringSpec(damping: 1.0, response: 0.45))
        #expect(ZoomSpeed.medium.spring == DefaultStyle.toma.zoomSpring)
        #expect(ZoomSpeed(SpringSpec(damping: 1.0, response: 0.45)) == .fast)
        #expect(ZoomSpeed(SpringSpec(damping: 0.8, response: 0.7)) == nil)
    }

    @Test func rangesAreTheDesignOnes() {
        #expect(ZoomPanelRules.depthRange == 1.25...4 && ZoomPanelRules.depthStep == 0.05)
        #expect(ZoomPanelRules.groupGapRange == 0.5...5 && ZoomPanelRules.leadInRange == 0...2 && ZoomPanelRules.leadOutRange == 0...3)
    }

    @Test func loupeSizeIsTheDesignsRange() {
        #expect(ZoomPanelRules.loupeRadiusRange == 0.06...0.4)
        #expect(ZoomPanelRules.loupeRadiusRange == LoupeStyle.radiusRange)
        #expect(ZoomPanelRules.loupeRadiusStep == 0.01)
        #expect(LoupeStyle.default.radius >= ZoomPanelRules.loupeRadiusRange.lowerBound)
        #expect(LoupeStyle.default.radius <= ZoomPanelRules.loupeRadiusRange.upperBound)
    }

    /// Plan 3b decision 10: a calm block has its mode's symbol, automatic or not; a Classic one, ✦ if it is automatic and
    /// nothing if it is the user's (as in phase 2).
    @Test func eachModeHasItsSymbolOnTheTrack() {
        #expect(ZoomPanelRules.symbol(.highlight) == "highlighter")
        #expect(ZoomPanelRules.symbol(.dim) == "sun.min")
        #expect(ZoomPanelRules.symbol(.loupe) == "magnifyingglass.circle")
        #expect(Set(ZoomMode.allCases.map(ZoomPanelRules.symbol)).count == ZoomMode.allCases.count)
        for automatic in [false, true] {
            #expect(ZoomPanelRules.trackSymbol(mode: .highlight, automatic: automatic) == "highlighter")
            #expect(ZoomPanelRules.trackSymbol(mode: .dim, automatic: automatic) == "sun.min")
            #expect(ZoomPanelRules.trackSymbol(mode: .loupe, automatic: automatic) == "magnifyingglass.circle")
        }
        #expect(ZoomPanelRules.trackSymbol(mode: .classic, automatic: true) == "sparkles")
        #expect(ZoomPanelRules.trackSymbol(mode: .classic, automatic: false) == nil)
    }
}
