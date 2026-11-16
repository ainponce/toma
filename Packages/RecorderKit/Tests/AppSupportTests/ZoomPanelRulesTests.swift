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
}
