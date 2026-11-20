// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Testing

/// How the island carries a "Re-record from Here" (3d plan decisions 9 and 10), over the island's own machine.
@Suite struct IslandRerecordRulesTests {
    /// A machine that has handled `events`, one second apart.
    private func machine(after events: [IslandEvent]) -> IslandMachine {
        var machine = IslandMachine()
        for (index, event) in events.enumerated() { machine.handle(event, at: .seconds(index)) }
        return machine
    }

    /// The island opened for a source the take lacks, Record clicked, and the start failed: the island opens again and
    /// says why. The re-record is held there (the editor stays hidden), Record tries it again, and closing the island then
    /// cancels it: the editor hears `.nothing` once, then.
    @Test func aFailedStartIsHeldUntilTheIslandCloses() {
        var island = machine(after: [.clicked, .phaseChanged(.countingDown(remaining: 3)), .phaseChanged(.starting)])
        #expect(!IslandRerecordRules.showsStartFailure(island))
        // The controller goes back to idle, then says why (`startFailed`), then tells the end.
        island.handle(.phaseChanged(.idle), at: .seconds(4))
        island.handle(.startFailed, at: .seconds(4))
        #expect(island.state == .open && IslandRerecordRules.showsStartFailure(island))
        #expect(IslandRerecordRules.end(.nothing, islandShowsStartFailure: true) == .holdForRetry)

        // Record again: the open island counts down, which closes nothing.
        var retried = island
        retried.handle(.phaseChanged(.countingDown(remaining: 3)), at: .seconds(5))
        #expect(!IslandRerecordRules.closesWithoutRecording(from: island.state, to: retried.state))
        #expect(!IslandRerecordRules.showsStartFailure(retried))

        // Closed instead (Esc, ✕, a click outside): the re-record is cancelled, and that end reaches the editor.
        var closed = island
        closed.handle(.dismiss, at: .seconds(5))
        #expect(IslandRerecordRules.closesWithoutRecording(from: island.state, to: closed.state))
        #expect(!IslandRerecordRules.showsStartFailure(closed))
        #expect(IslandRerecordRules.end(.nothing, islandShowsStartFailure: IslandRerecordRules.showsStartFailure(closed)) == .tellEditor)
    }

    /// Any other end reaches the editor at once: a take recorded or closed to quit, also while the island says why another
    /// start failed, and nothing recorded with nothing to retry (the countdown cancelled, the permissions opened).
    @Test func otherEndsReachTheEditor() {
        for failure in [false, true] {
            #expect(IslandRerecordRules.end(.recorded(takeID: "take-002"), islandShowsStartFailure: failure) == .tellEditor)
            #expect(IslandRerecordRules.end(.quit, islandShowsStartFailure: failure) == .tellEditor)
        }
        #expect(IslandRerecordRules.end(.nothing, islandShowsStartFailure: false) == .tellEditor)
    }

    /// Only the open island (or its choosing on the screen) going to rest or a peek closes it without recording: the
    /// shortcut and the system's own UI too; Record's countdown, or choosing on the screen, do not.
    @Test func whatClosesTheOpenIsland() {
        let open = machine(after: [.clicked])
        for event in [IslandEvent.dismiss, .toggle, .systemUIOpened] {
            var closed = open
            closed.handle(event, at: .seconds(2))
            #expect(IslandRerecordRules.closesWithoutRecording(from: open.state, to: closed.state))
        }
        let choosing = machine(after: [.clicked, .beganChoosing])
        var closedWhileChoosing = choosing
        closedWhileChoosing.handle(.toggle, at: .seconds(3))
        #expect(IslandRerecordRules.closesWithoutRecording(from: choosing.state, to: closedWhileChoosing.state))
        #expect(!IslandRerecordRules.closesWithoutRecording(from: open.state, to: choosing.state))
        #expect(!IslandRerecordRules.closesWithoutRecording(from: choosing.state, to: open.state))
        var counting = open
        counting.handle(.phaseChanged(.countingDown(remaining: 3)), at: .seconds(2))
        #expect(!IslandRerecordRules.closesWithoutRecording(from: open.state, to: counting.state))
        // A countdown cancelled is the recorder's to tell, not the island's.
        var cancelled = counting
        cancelled.handle(.phaseChanged(.idle), at: .seconds(3))
        #expect(!IslandRerecordRules.closesWithoutRecording(from: counting.state, to: cancelled.state))
        #expect(!IslandRerecordRules.closesWithoutRecording(from: .rest, to: .open))
    }
}
