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
        #expect(immediate.state == .rest)
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
