// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Testing

@Suite struct SystemPromptRoomTests {
    @Test func theIslandMakesRoomFromTheRequestUntilItIsBack() {
        var room = SystemPromptRoom()
        #expect(!room.isMakingRoom)
        // Nothing asked: the island being back changes nothing.
        #expect(!back(&room))

        room.requestStarted()
        #expect(room.isMakingRoom)
        // While the request runs the prompt may be up: the island stays under it.
        #expect(!back(&room))
        #expect(room.isMakingRoom)

        room.requestEnded()
        #expect(room.isMakingRoom)
        // The request is over and the island is back (the pointer over it, or it is key again): the prompt is taken
        // as answered, and everything comes back at once.
        #expect(back(&room))
        #expect(!room.isMakingRoom)
        #expect(!back(&room))
    }

    @Test func leavingTheOpenIslandEndsTheRoom() {
        var room = SystemPromptRoom()
        room.requestStarted()
        room.islandLeftOpen()
        #expect(!room.isMakingRoom)
        // A request that ends afterwards does not bring it back.
        room.requestEnded()
        #expect(!room.isMakingRoom && !back(&room))
        // Nor does a request still running when the island opens again: it asks no more.
        room.requestStarted()
        room.islandLeftOpen()
        #expect(!back(&room))
    }

    /// `islandIsBack()`, out of `#expect`, which cannot call a mutating method.
    private func back(_ room: inout SystemPromptRoom) -> Bool {
        room.islandIsBack()
    }
}
