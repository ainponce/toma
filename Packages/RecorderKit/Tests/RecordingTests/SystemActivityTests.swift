// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Recording

@Suite struct SystemActivityTests {
    @Test func takeKeepsTheMacAndItsDisplaysAwake() {
        let options = RecordingCoordinator.takeActivityOptions
        #expect(options.contains(.idleSystemSleepDisabled))
        #expect(options.contains(.idleDisplaySleepDisabled))
        #expect(options.contains(.userInitiated))
    }

    @Test func displayWakeOntoTheLockScreenDoesNotUnlock() {
        var screen = ScreenAvailability()
        #expect(screen.apply(locked: true) == .screenLocked)
        #expect(screen.apply(displaysAsleep: true) == nil)
        #expect(screen.apply(displaysAsleep: false) == nil)
        #expect(screen.apply(locked: false) == .screenUnlocked)
        #expect(screen.apply(locked: false) == nil)
        #expect(screen.isAvailable)
    }

    @Test func displaySleepAloneMakesTheScreenUnavailable() {
        var screen = ScreenAvailability()
        #expect(screen.apply(displaysAsleep: true) == .screenLocked)
        #expect(screen.apply(displaysAsleep: false) == .screenUnlocked)
    }

    @Test func unlockWithoutALockChangesNothing() {
        var screen = ScreenAvailability()
        #expect(screen.apply(locked: false) == nil)
        #expect(screen.apply(displaysAsleep: false) == nil)
        #expect(screen.isAvailable)
    }

    @Test func unlockWhileTheDisplaysSleepWaitsForThemToWake() {
        var screen = ScreenAvailability()
        #expect(screen.apply(displaysAsleep: true) == .screenLocked)
        #expect(screen.apply(locked: true) == nil)
        #expect(screen.apply(locked: false) == nil)
        #expect(screen.apply(displaysAsleep: false) == .screenUnlocked)
    }
}
