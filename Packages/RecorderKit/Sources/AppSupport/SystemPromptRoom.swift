// SPDX-License-Identifier: GPL-3.0-or-later

/// How the open island makes room for a system prompt it cannot follow: system audio's (plan decision 7), which
/// macOS shows while the request runs and never says when it is answered. From the request on, the island goes
/// under the prompt and losing the keyboard to it does not close the island. Once the request is over and the
/// island is back (the pointer over it, or it is key again), the prompt is taken as answered: the island's level,
/// its keyboard and its closing with a click elsewhere come back at once. Leaving the open island ends it too.
public struct SystemPromptRoom: Equatable, Sendable {
    /// The island stays under the prompt, and open while the prompt has the keyboard.
    public private(set) var isMakingRoom = false
    private var isAsking = false

    public init() {}

    /// The request started, with the island open.
    public mutating func requestStarted() {
        isAsking = true
        isMakingRoom = true
    }

    public mutating func requestEnded() {
        isAsking = false
    }

    /// The island is back: whether that ends the room (the request is over), so the island takes back its level
    /// and its keyboard now.
    public mutating func islandIsBack() -> Bool {
        guard isMakingRoom, !isAsking else { return false }
        isMakingRoom = false
        return true
    }

    /// The island is no longer open: nothing is kept for the next time it opens.
    public mutating func islandLeftOpen() {
        isMakingRoom = false
        isAsking = false
    }
}
