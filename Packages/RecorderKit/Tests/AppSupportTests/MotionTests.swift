// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Testing

@Suite struct MotionTests {
    @Test func motionFollowsTheDesignTable() {
        #expect(Motion.islandExpand == Spring(damping: 0.86, response: 0.56))
        #expect(Motion.islandPeek == Spring(damping: 0.90, response: 0.42))
        #expect(Motion.islandCollapse == Spring(damping: 1.0, response: 0.48))
        #expect(Motion.selector == Spring(damping: 1.0, response: 0.32))
        #expect(Motion.bubbleRelease == Spring(damping: 0.82, response: 0.50))
        #expect(Motion.bubbleShape == Spring(damping: 0.95, response: 0.50))
        #expect(Motion.contentDelay == .milliseconds(60) && Motion.contentExit == .milliseconds(170))
        #expect(Motion.contentEnterBlur == 10 && Motion.contentExitBlur == 8 && Motion.contentEnterScale == 0.94)
        #expect(Motion.reducedMotionFade == .milliseconds(200))
        // The prototype's, outside the table.
        #expect(Motion.countdownDigitExit == .milliseconds(280) && Motion.notchBlend == .milliseconds(320))
    }

    @Test func newMotionConstants() {
        #expect(Motion.panelSwap == Spring(damping: 1.0, response: 0.30))
        #expect(Motion.trackItem == Spring(damping: 0.90, response: 0.30))
        #expect(Motion.timelineZoom == Spring(damping: 1.0, response: 0.28))
        #expect(Motion.timelineScroll == Spring(damping: 1.0, response: 0.36))
        #expect(Motion.hover == Spring(damping: 1.0, response: 0.20))
        #expect(Motion.panelSwapRise == 6)
    }

    @Test func springValueSettlesOnItsTarget() {
        var width = SpringValue(value: 0, spring: Motion.islandExpand)
        #expect(width.isSettled && width.target == 0)
        width.retarget(700, spring: Motion.islandExpand)
        #expect(!width.isSettled)
        for _ in 0..<240 { width.step(by: 1.0 / 120) }
        #expect(width.isSettled)
        #expect(width.value == 700 && width.velocity == 0)
    }

    @Test func retargetMidwayKeepsTheVelocity() {
        var width = SpringValue(value: 0, spring: Motion.islandExpand)
        width.retarget(700, spring: Motion.islandExpand)
        for _ in 0..<12 { width.step(by: 1.0 / 120) }
        #expect(width.velocity > 0 && width.value > 0 && width.value < 700)
        let (value, velocity) = (width.value, width.velocity)

        width.retarget(0, spring: Motion.islandCollapse)
        #expect(width.value == value && width.velocity == velocity)
        #expect(width.target == 0 && width.spring == Motion.islandCollapse)
        // It keeps going out for a moment, then turns back.
        width.step(by: 1.0 / 120)
        #expect(width.value > value)
    }

    @Test func criticallyDampedSpringNeverOvershoots() {
        var height = SpringValue(value: 0, spring: Motion.islandCollapse)
        height.retarget(100, spring: Motion.islandCollapse)
        var highest = 0.0
        for _ in 0..<240 {
            height.step(by: 1.0 / 120)
            highest = max(highest, height.value)
        }
        #expect(highest <= 100)
        #expect(height.isSettled && height.value == 100)
    }

    @Test func aLongStepIsIntegratedInSmallSubsteps() {
        // One step of a whole second lands where 120 steps of 1/120 s do.
        var once = SpringValue(value: 0, spring: Motion.islandPeek)
        var often = once
        once.retarget(262, spring: Motion.islandPeek)
        often.retarget(262, spring: Motion.islandPeek)
        once.step(by: 0.25)
        for _ in 0..<30 { often.step(by: 1.0 / 120) }
        #expect(abs(once.value - often.value) < 0.01)
        // Nothing moves without time.
        let before = once
        once.step(by: 0)
        #expect(once == before)
    }
}
