// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
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

    @Test func onlyOpenAndChoosingTakeTheKeyboard() {
        #expect(IslandState.open.needsKeyboard && IslandState.choosing.needsKeyboard)
        #expect(!IslandState.rest.needsKeyboard && !IslandState.peek.needsKeyboard)
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
