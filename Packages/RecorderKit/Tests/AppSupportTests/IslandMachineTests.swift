// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import Testing

@Suite struct IslandMachineTests {
    /// A machine that has handled `events`, one second apart.
    private func machine(after events: [IslandEvent]) -> IslandMachine {
        var machine = IslandMachine()
        for (index, event) in events.enumerated() { machine.handle(event, at: .seconds(index)) }
        return machine
    }

    @Test func pointerOverTheNotchPeeksAndLeavingHidesAfterAGrace() {
        var island = IslandMachine()
        #expect(island.state == .rest && island.deadline == nil)
        island.handle(.pointerEntered, at: .zero)
        #expect(island.state == .peek && island.deadline == nil)

        island.handle(.pointerExited, at: .seconds(1))
        #expect(island.state == .peek && island.deadline == .milliseconds(1300))
        island.tick(at: .milliseconds(1299))
        #expect(island.state == .peek)
        island.tick(at: .milliseconds(1300))
        #expect(island.state == .rest && island.deadline == nil)

        // Back before the grace is over: it stays.
        island.handle(.pointerEntered, at: .seconds(2))
        island.handle(.pointerExited, at: .seconds(3))
        island.handle(.pointerEntered, at: .milliseconds(3200))
        #expect(island.state == .peek && island.deadline == nil)
        island.tick(at: .seconds(4))
        #expect(island.state == .peek)
    }

    @Test func clickOrShortcutOpensAndDismissCloses() {
        #expect(machine(after: [.clicked]).state == .open)
        #expect(machine(after: [.pointerEntered, .clicked]).state == .open)
        #expect(machine(after: [.toggle]).state == .open)
        #expect(machine(after: [.pointerEntered, .toggle]).state == .open)
        #expect(machine(after: [.toggle, .toggle]).state == .rest)
        #expect(machine(after: [.clicked, .dismiss]).state == .rest)

        // Opening while the peek is about to hide drops the deadline.
        var island = machine(after: [.pointerEntered, .pointerExited])
        #expect(island.deadline != nil)
        island.handle(.clicked, at: .seconds(2))
        #expect(island.state == .open && island.deadline == nil)

        // Open, the pointer and more clicks change nothing; dismissing at rest neither.
        #expect(machine(after: [.clicked, .pointerEntered, .pointerExited, .clicked]).state == .open)
        #expect(machine(after: [.dismiss]).state == .rest)
    }

    @Test func choosingReturnsToTheOpenPanel() {
        #expect(machine(after: [.clicked, .beganChoosing]).state == .choosing)
        #expect(machine(after: [.clicked, .beganChoosing, .endedChoosing]).state == .open)
        #expect(machine(after: [.clicked, .beganChoosing, .toggle]).state == .rest)
        // Choosing starts from the open panel only.
        #expect(machine(after: [.beganChoosing]).state == .rest)
        #expect(machine(after: [.pointerEntered, .beganChoosing]).state == .peek)
    }

    @Test func onlyOpenChoosingAndTheCountdownTakeTheKeyboard() {
        #expect(IslandState.open.needsKeyboard && IslandState.choosing.needsKeyboard)
        #expect(IslandState.countdown(remaining: 1).needsKeyboard)
        #expect(!IslandState.rest.needsKeyboard && !IslandState.peek.needsKeyboard)
        #expect(!IslandState.recording.needsKeyboard && !IslandState.recordingOpen.needsKeyboard)
        #expect(!IslandState.notice(.microphoneSilent).needsKeyboard)
        #expect(!IslandState.saving.needsKeyboard && !IslandState.saved(Self.savedTake(openedEditor: false)).needsKeyboard)
    }

    @Test func countdownAndRecordingDriveTheIsland() {
        var island = machine(after: [.clicked])
        island.handle(.phaseChanged(.countingDown(remaining: 3)), at: .seconds(1))
        #expect(island.state == .countdown(remaining: 3) && island.state.needsKeyboard)
        island.handle(.phaseChanged(.countingDown(remaining: 2)), at: .seconds(2))
        #expect(island.state == .countdown(remaining: 2))
        // The countdown is not closed by a click, the shortcut or Esc: only by stopping it.
        for event in [IslandEvent.toggle, .dismiss, .clicked, .pointerEntered, .beganChoosing] {
            var counting = island
            counting.handle(event, at: .seconds(3))
            #expect(counting.state == .countdown(remaining: 2))
        }
        island.handle(.phaseChanged(.starting), at: .seconds(4))
        #expect(island.state == .recording && !island.state.needsKeyboard)
        island.handle(.pointerEntered, at: .seconds(5))
        #expect(island.state == .recordingOpen && !island.state.needsKeyboard)
        // The take starts recording under the open island: it stays open.
        island.handle(.phaseChanged(.recording(since: Date(timeIntervalSinceReferenceDate: 0))), at: .seconds(6))
        #expect(island.state == .recordingOpen)
        for event in [IslandEvent.toggle, .dismiss, .clicked] {
            var open = island
            open.handle(event, at: .seconds(7))
            #expect(open.state == .recordingOpen)
        }

        // With no countdown, Record goes straight to the wings.
        var immediate = machine(after: [.clicked])
        immediate.handle(.phaseChanged(.starting), at: .seconds(2))
        #expect(immediate.state == .recording)
        for event in [IslandEvent.toggle, .dismiss, .clicked] {
            var wings = immediate
            wings.handle(event, at: .seconds(3))
            #expect(wings.state == .recording)
        }
        immediate.handle(.phaseChanged(.stopping), at: .seconds(4))
        #expect(immediate.state == .saving)
    }

    @Test func recordingOpenCollapses650msAfterThePointerLeaves() {
        #expect(IslandMachine.collapseDelay == .milliseconds(650))
        var island = recordingOpen()
        island.handle(.pointerExited, at: .seconds(10))
        #expect(island.deadline == .milliseconds(10_650))
        island.tick(at: .milliseconds(10_640))
        #expect(island.state == .recordingOpen)
        island.tick(at: .milliseconds(10_650))
        #expect(island.state == .recording && island.deadline == nil)

        // Back before the 650 ms: it stays open.
        var back = recordingOpen()
        back.handle(.pointerExited, at: .seconds(10))
        back.handle(.pointerEntered, at: .milliseconds(10_300))
        #expect(back.deadline == nil)
        back.tick(at: .seconds(11))
        #expect(back.state == .recordingOpen)
    }

    @Test func restartConfirmationKeepsTheIslandOpen() {
        var island = recordingOpen()
        island.handle(.confirmationShown(true), at: .seconds(10))
        island.handle(.pointerExited, at: .seconds(10))
        #expect(island.deadline == nil)
        island.tick(at: .seconds(11))
        #expect(island.state == .recordingOpen)
        island.handle(.confirmationShown(false), at: .seconds(12))
        #expect(island.deadline == .milliseconds(12_650))
        island.tick(at: .milliseconds(12_650))
        #expect(island.state == .recording)

        // Shown while the pointer is away: the collapse already asked for is called off.
        var leaving = recordingOpen()
        leaving.handle(.pointerExited, at: .seconds(10))
        leaving.handle(.confirmationShown(true), at: .milliseconds(10_100))
        #expect(leaving.deadline == nil)
        // Closed with the pointer over the island: nothing to collapse.
        leaving.handle(.pointerEntered, at: .seconds(11))
        leaving.handle(.confirmationShown(false), at: .seconds(12))
        #expect(leaving.deadline == nil && leaving.state == .recordingOpen)
    }

    @Test func cancelledCountdownReturnsToRest() {
        var island = machine(after: [.clicked, .phaseChanged(.countingDown(remaining: 3)), .phaseChanged(.countingDown(remaining: 2))])
        #expect(island.state == .countdown(remaining: 2))
        island.handle(.phaseChanged(.idle), at: .seconds(5))
        #expect(island.state == .rest)
        // A start that failed: from the wings, and from the open island over them.
        #expect(machine(after: [.clicked, .phaseChanged(.starting), .phaseChanged(.idle)]).state == .rest)
        #expect(machine(after: [.clicked, .phaseChanged(.starting), .pointerEntered, .phaseChanged(.idle)]).state == .rest)
        // At rest, open or choosing, a take that did not start changes nothing.
        #expect(machine(after: [.clicked, .phaseChanged(.idle)]).state == .open)
        #expect(machine(after: [.clicked, .beganChoosing, .phaseChanged(.idle)]).state == .choosing)
        #expect(machine(after: [.phaseChanged(.idle)]).state == .rest)
        // A restart counts down again, from wherever the island is.
        #expect(machine(after: [.clicked, .phaseChanged(.starting), .phaseChanged(.countingDown(remaining: 3))]).state
            == .countdown(remaining: 3))
    }

    /// Recording, with the pointer over the island, which opened at 5 s.
    private func recordingOpen() -> IslandMachine {
        var island = IslandMachine()
        island.handle(.clicked, at: .seconds(1))
        island.handle(.phaseChanged(.starting), at: .seconds(2))
        island.handle(.phaseChanged(.recording(since: Date(timeIntervalSinceReferenceDate: 0))), at: .seconds(3))
        island.handle(.pointerEntered, at: .seconds(5))
        return island
    }

    @Test func theIslandTakesTheKeyboardOnEnteringAKeyboardStateOnly() {
        // Entering a state that uses the keyboard.
        #expect(IslandState.becomesKey(from: .rest, to: .open))
        #expect(IslandState.becomesKey(from: .peek, to: .open))
        #expect(IslandState.becomesKey(from: .choosing, to: .open))  // back from the on-screen selection, which had it
        #expect(IslandState.becomesKey(from: .open, to: .choosing))
        #expect(IslandState.becomesKey(from: .open, to: .countdown(remaining: 3)))
        #expect(IslandState.becomesKey(from: .rest, to: .countdown(remaining: 3)))  // a restart's countdown
        // Never from one second of the countdown to the next: the user may have clicked into their app.
        #expect(!IslandState.becomesKey(from: .countdown(remaining: 3), to: .countdown(remaining: 2)))
        #expect(!IslandState.becomesKey(from: .countdown(remaining: 2), to: .countdown(remaining: 1)))
        // Nor in the states without the keyboard.
        #expect(!IslandState.becomesKey(from: .countdown(remaining: 1), to: .recording))
        #expect(!IslandState.becomesKey(from: .recording, to: .recordingOpen))
        #expect(!IslandState.becomesKey(from: .open, to: .rest))
        #expect(!IslandState.becomesKey(from: .rest, to: .peek))
        let saved = IslandState.saved(Self.savedTake(openedEditor: false))
        #expect(!IslandState.becomesKey(from: .recording, to: .notice(.diskSpaceUnknown)))
        #expect(!IslandState.becomesKey(from: .recording, to: .saving))
        #expect(!IslandState.becomesKey(from: .saving, to: saved))
        // Record Another, and a start that failed, open the panel: it takes the keyboard.
        #expect(IslandState.becomesKey(from: saved, to: .open))
        #expect(IslandState.becomesKey(from: .recording, to: .open))
    }

    // MARK: - Notices, saving and saved

    /// Recording in the wings since 3 s.
    private func recordingWings() -> IslandMachine {
        var island = IslandMachine()
        island.handle(.clicked, at: .seconds(1))
        island.handle(.phaseChanged(.starting), at: .seconds(2))
        island.handle(.phaseChanged(.recording(since: Date(timeIntervalSinceReferenceDate: 0))), at: .seconds(3))
        return island
    }

    private static func savedTake(openedEditor: Bool) -> SavedTake {
        SavedTake(
            projectURL: URL(fileURLWithPath: "/Users/someone/Movies/Toma/Recording.toma", isDirectory: true),
            duration: .seconds(42), markers: 2, trackKinds: [.display, .microphone], openedEditor: openedEditor)
    }

    private static let since = Date(timeIntervalSinceReferenceDate: 0)

    @Test func newAttentionNoticeOpensTheIslandForFourSeconds() {
        #expect(IslandMachine.noticeDuration == .seconds(4))
        let low = TakeNotice.diskLow(availableBytes: 500_000_000)
        var island = recordingWings()
        #expect(island.attention == nil)
        island.handle(.noticesChanged([low]), at: .seconds(5))
        #expect(island.state == .notice(low) && island.deadline == .seconds(9))
        #expect(island.attention == .attention)
        island.tick(at: .milliseconds(8_999))
        #expect(island.state == .notice(low))
        island.tick(at: .seconds(9))
        #expect(island.state == .recording && island.deadline == nil && island.attention == .attention)
        // The same list again: nothing new.
        island.handle(.noticesChanged([low]), at: .seconds(10))
        #expect(island.state == .recording && island.deadline == nil)
        // A confirmation does not open the island: it is a capsule.
        island.handle(.noticesChanged([low, .streamResumed(.display)]), at: .seconds(11))
        #expect(island.state == .recording && island.attention == .attention)

        // Open over the wings, the island stays open: its list shows the notice.
        var open = recordingWings()
        open.handle(.pointerEntered, at: .seconds(4))
        open.handle(.noticesChanged([low]), at: .seconds(5))
        #expect(open.state == .recordingOpen && open.attention == .attention)

        // The pointer over the notice opens the island.
        var hovered = recordingWings()
        hovered.handle(.noticesChanged([low]), at: .seconds(5))
        hovered.handle(.pointerEntered, at: .seconds(6))
        #expect(hovered.state == .recordingOpen && hovered.deadline == nil)

        // Resolved while it shows: back to the wings at once.
        var resolved = recordingWings()
        resolved.handle(.noticesChanged([.streamInterrupted(.microphone)]), at: .seconds(5))
        #expect(resolved.state == .notice(.streamInterrupted(.microphone)))
        resolved.handle(.noticesChanged([.streamResumed(.microphone)]), at: .seconds(6))
        #expect(resolved.state == .recording && resolved.deadline == nil && resolved.attention == nil)
    }

    @Test func stoppedNoticeTurnsTheWingRed() {
        let low = TakeNotice.diskLow(availableBytes: 500_000_000)
        var island = recordingWings()
        island.handle(.noticesChanged([low]), at: .seconds(5))
        #expect(island.attention == .attention)
        island.handle(.noticesChanged([low, .stoppedForDiskSpace]), at: .seconds(6))
        #expect(island.attention == .stopped)
        #expect(island.state == .notice(.stoppedForDiskSpace) && island.deadline == .seconds(10))
        island.handle(.noticesChanged([.closedWithError]), at: .seconds(7))
        #expect(island.attention == .stopped)
        island.handle(.noticesChanged([]), at: .seconds(8))
        #expect(island.attention == nil)
    }

    @Test func startNoticesShowOnceRecordingBegins() {
        var island = machine(after: [.clicked])
        island.handle(.phaseChanged(.countingDown(remaining: 3)), at: .seconds(3))
        island.handle(.noticesChanged([.microphoneAccessOff]), at: .seconds(4))
        #expect(island.state == .countdown(remaining: 3) && island.attention == .attention)
        island.handle(.phaseChanged(.starting), at: .milliseconds(4_500))
        #expect(island.state == .recording)
        island.handle(.phaseChanged(.recording(since: Self.since)), at: .seconds(5))
        #expect(island.state == .notice(.microphoneAccessOff) && island.deadline == .seconds(9))
        island.tick(at: .seconds(9))
        #expect(island.state == .recording)
        island.handle(.phaseChanged(.recording(since: Self.since)), at: .seconds(10))
        #expect(island.state == .recording && island.deadline == nil)

        // Said while the panel is open, before the countdown: the same.
        var open = machine(after: [.clicked, .noticesChanged([.noMicrophone]), .phaseChanged(.starting)])
        #expect(open.state == .recording)
        open.handle(.phaseChanged(.recording(since: Self.since)), at: .seconds(5))
        #expect(open.state == .notice(.noMicrophone))

        // Already showing while the take starts: starting and recording leave it there.
        var shown = machine(after: [.clicked, .phaseChanged(.starting), .noticesChanged([.noMicrophone])])
        #expect(shown.state == .notice(.noMicrophone) && shown.deadline == .seconds(6))
        shown.handle(.phaseChanged(.recording(since: Self.since)), at: .seconds(3))
        #expect(shown.state == .notice(.noMicrophone) && shown.deadline == .seconds(6))

        // Under the open island it stays open.
        var hovered = machine(after: [.clicked, .phaseChanged(.countingDown(remaining: 1)), .noticesChanged([.noMicrophone])])
        hovered.handle(.phaseChanged(.starting), at: .seconds(3))
        hovered.handle(.pointerEntered, at: .seconds(4))
        hovered.handle(.phaseChanged(.recording(since: Self.since)), at: .seconds(5))
        #expect(hovered.state == .recordingOpen)

        // A take that did not start: what was pending goes with it.
        var cancelled = machine(after: [.clicked, .phaseChanged(.countingDown(remaining: 3)), .noticesChanged([.noMicrophone])])
        cancelled.handle(.phaseChanged(.idle), at: .seconds(3))
        #expect(cancelled.state == .rest)
        cancelled.handle(.phaseChanged(.starting), at: .seconds(4))
        cancelled.handle(.phaseChanged(.recording(since: Self.since)), at: .seconds(5))
        #expect(cancelled.state == .recording)
    }

    @Test func savingWithoutASavedTakeReturnsToRest() {
        #expect(IslandMachine.savingGrace == .seconds(1))
        var island = recordingWings()
        island.handle(.phaseChanged(.stopping), at: .seconds(10))
        #expect(island.state == .saving && island.deadline == nil)
        // Nothing the user does closes it while the take closes.
        for event in [IslandEvent.toggle, .dismiss, .clicked, .pointerEntered] {
            var saving = island
            saving.handle(event, at: .seconds(11))
            #expect(saving.state == .saving)
        }
        island.handle(.phaseChanged(.idle), at: .seconds(20))
        #expect(island.state == .saving && island.deadline == .seconds(21))
        island.tick(at: .seconds(21))
        #expect(island.state == .rest && island.deadline == nil)

        // A saved take that comes too late changes nothing.
        island.handle(.saved(Self.savedTake(openedEditor: false)), at: .seconds(22))
        #expect(island.state == .rest)

        // A restart closes its take and counts down again.
        var restarting = recordingWings()
        restarting.handle(.phaseChanged(.stopping), at: .seconds(10))
        restarting.handle(.phaseChanged(.countingDown(remaining: 3)), at: .seconds(11))
        #expect(restarting.state == .countdown(remaining: 3))
        // Without a countdown, it goes back to the wings.
        var immediate = recordingWings()
        immediate.handle(.phaseChanged(.stopping), at: .seconds(10))
        immediate.handle(.phaseChanged(.starting), at: .seconds(11))
        #expect(immediate.state == .recording)
    }

    @Test func savedClosesAfterEightSecondsWhenStayingHere() {
        #expect(IslandMachine.savedStayDuration == .seconds(8))
        let take = Self.savedTake(openedEditor: false)
        var island = recordingWings()
        island.handle(.phaseChanged(.stopping), at: .seconds(19))
        #expect(island.state == .saving)
        island.handle(.phaseChanged(.idle), at: .seconds(20))
        #expect(island.state == .saving)
        island.handle(.saved(take), at: .seconds(20))
        #expect(island.state == .saved(take) && island.deadline == .seconds(28))

        var waiting = island
        waiting.handle(.phaseChanged(.idle), at: .seconds(21))
        #expect(waiting.state == .saved(take) && waiting.deadline == .seconds(28))
        waiting.tick(at: .milliseconds(27_999))
        #expect(waiting.state == .saved(take))
        waiting.tick(at: .seconds(28))
        #expect(waiting.state == .rest && waiting.deadline == nil)

        // Record Another: the shortcut, or "New Recording" in the menu.
        for event in [IslandEvent.toggle, .clicked] {
            var another = island
            another.handle(event, at: .seconds(22))
            #expect(another.state == .open && another.deadline == nil)
        }
        // Close, and Open in the Editor.
        var closed = island
        closed.handle(.dismiss, at: .seconds(22))
        #expect(closed.state == .rest && closed.deadline == nil)
        // A new take counts down from there.
        var next = island
        next.handle(.phaseChanged(.countingDown(remaining: 3)), at: .seconds(23))
        #expect(next.state == .countdown(remaining: 3))
    }

    @Test func savedGoesBackToRestWhileTheEditorOpens() {
        #expect(IslandMachine.savedWhileEditorOpens == .milliseconds(1500))
        let take = Self.savedTake(openedEditor: true)
        var island = recordingWings()
        island.handle(.phaseChanged(.stopping), at: .seconds(19))
        island.handle(.phaseChanged(.idle), at: .seconds(20))
        island.handle(.saved(take), at: .seconds(20))
        #expect(island.state == .saved(take) && island.deadline == .milliseconds(21_500))
        island.tick(at: .milliseconds(21_500))
        #expect(island.state == .rest)
    }

    @Test func startFailureShowsInsideTheOpenIsland() {
        var island = machine(after: [.clicked, .phaseChanged(.countingDown(remaining: 3)), .phaseChanged(.idle)])
        #expect(island.state == .rest && !island.hasStartFailure)
        island.handle(.startFailed, at: .seconds(3))
        #expect(island.state == .open && island.hasStartFailure)
        island.handle(.phaseChanged(.countingDown(remaining: 3)), at: .seconds(4))
        #expect(island.state == .countdown(remaining: 3) && !island.hasStartFailure)

        // From the wings (a start that failed once counted down), whichever comes first.
        let wings = machine(after: [.clicked, .phaseChanged(.starting), .phaseChanged(.idle), .startFailed])
        #expect(wings.state == .open && wings.hasStartFailure)
        let first = machine(after: [.clicked, .phaseChanged(.starting), .startFailed, .phaseChanged(.idle)])
        #expect(first.state == .open && first.hasStartFailure)
        // Recording again without a countdown clears it.
        var again = wings
        again.handle(.phaseChanged(.starting), at: .seconds(5))
        #expect(again.state == .recording && !again.hasStartFailure)
        // Closed with Esc, ✕ or a click outside, or with the shortcut.
        for event in [IslandEvent.dismiss, .toggle] {
            var closed = wings
            closed.handle(event, at: .seconds(5))
            #expect(closed.state == .rest && !closed.hasStartFailure)
        }
        // Choosing on the screen keeps it.
        var choosing = wings
        choosing.handle(.beganChoosing, at: .seconds(5))
        choosing.handle(.endedChoosing, at: .seconds(6))
        #expect(choosing.state == .open && choosing.hasStartFailure)
    }

    @Test func pointerInsideTheZoneOrTheIslandCountsAsInside() {
        var presence = PointerPresence()
        #expect(presence.entered(.zone(1)) == .pointerEntered)
        // From the zone onto the peeking island, which covers it: still inside.
        #expect(presence.entered(.island) == nil)
        #expect(presence.exited(.zone(1)) == nil)
        #expect(presence.inside == [.island])
        #expect(presence.exited(.island) == .pointerExited)
        #expect(presence.exited(.island) == nil)
        #expect(presence.inside.isEmpty)
        // Entering the same region twice counts once.
        #expect(presence.entered(.zone(2)) == .pointerEntered)
        #expect(presence.entered(.zone(2)) == nil)
        #expect(presence.exited(.zone(2)) == .pointerExited)
    }

    @Test func aZoneTheIslandCoversIsTheIsland() {
        // The island arrives at a notch whose zone has the pointer, and that zone's panel leaves the screen:
        // its exit never comes, and leaving the island is leaving.
        var presence = PointerPresence()
        #expect(presence.entered(.zone(7)) == .pointerEntered)
        presence.islandCovers(.zone(7))
        #expect(presence.inside == [.island])
        #expect(presence.exited(.island) == .pointerExited)
        #expect(presence.entered(.zone(1)) == .pointerEntered)

        // Covering a zone the pointer is not in changes nothing.
        var outside = PointerPresence()
        outside.islandCovers(.zone(7))
        #expect(outside.inside.isEmpty)
        #expect(outside.entered(.island) == .pointerEntered)
        outside.islandCovers(.zone(7))
        #expect(outside.inside == [.island])
    }
}
