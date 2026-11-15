// SPDX-License-Identifier: GPL-3.0-or-later

/// What the island shows (notch design §5.1). Tasks 16a and 16b add the take's states.
public enum IslandState: Equatable, Sendable {
    /// Nothing: on a screen with a notch it is the notch; elsewhere it is not drawn.
    case rest
    /// The pointer is over the notch (or the top center of a screen without one): "New Recording".
    case peek
    /// The panel: what to record, the camera, audio and Record.
    case open
    /// Choosing what to record on the screen itself.
    case choosing

    /// Whether the island is the key window: only in the states that use the keyboard (Esc, and a click
    /// elsewhere closing it), so it never keeps what the user types in their own app.
    public var needsKeyboard: Bool {
        switch self {
        case .rest, .peek: false
        case .open, .choosing: true
        }
    }
}

/// What happens to the island.
public enum IslandEvent: Equatable, Sendable {
    /// The pointer is over the island or one of the hover zones (`PointerPresence`).
    case pointerEntered
    /// It is over none of them any more.
    case pointerExited
    /// A click on the notch, the peeking island, or "New Recording" in the menu.
    case clicked
    /// The island's shortcut.
    case toggle
    /// Esc, ✕ or a click outside the open island.
    case dismiss
    /// "Choose on Screen".
    case beganChoosing
    /// Done, Return, Esc or the choice itself.
    case endedChoosing
}

/// Which state the island is in, from what happens to it. `now` is a monotonic time the app passes
/// (`ContinuousClock.now` minus an origin); when `deadline` is set, the app calls `tick` once it is reached.
public struct IslandMachine: Equatable, Sendable {
    /// How long a peek waits after the pointer leaves before going back to rest: enough to reach the pill
    /// 38 pt below the zone of a screen without a notch.
    public static let peekGrace: Duration = .milliseconds(300)

    public private(set) var state = IslandState.rest
    /// When the machine wants a `tick`.
    public private(set) var deadline: Duration?

    public init() {}

    public mutating func handle(_ event: IslandEvent, at now: Duration) {
        switch (state, event) {
        case (.rest, .pointerEntered):
            go(to: .peek)
        case (.peek, .pointerEntered):
            deadline = nil
        case (.peek, .pointerExited):
            deadline = now + Self.peekGrace
        case (.rest, .clicked), (.rest, .toggle), (.peek, .clicked), (.peek, .toggle):
            go(to: .open)
        case (.open, .toggle), (.open, .dismiss), (.choosing, .toggle):
            go(to: .rest)
        case (.open, .beganChoosing):
            go(to: .choosing)
        case (.choosing, .endedChoosing):
            go(to: .open)
        default:
            break
        }
    }

    public mutating func tick(at now: Duration) {
        guard let deadline, now >= deadline else { return }
        switch state {
        case .peek: go(to: .rest)
        case .rest, .open, .choosing: self.deadline = nil
        }
    }

    private mutating func go(to state: IslandState) {
        self.state = state
        deadline = nil
    }
}

/// Whether the pointer is over the island: it is inside while it is over any hover zone or the island
/// itself, so moving from a zone onto the island that covers it is not leaving.
public struct PointerPresence: Equatable, Sendable {
    public enum Region: Hashable, Sendable {
        /// The hover zone of the display with this ID (`IslandHoverZones`).
        case zone(UInt32)
        case island
    }

    public private(set) var inside: Set<Region> = []

    public init() {}

    /// `pointerEntered` when the pointer was over none of the regions; otherwise `nil`.
    public mutating func entered(_ region: Region) -> IslandEvent? {
        let wasOutside = inside.isEmpty
        inside.insert(region)
        return wasOutside ? .pointerEntered : nil
    }

    /// `pointerExited` when the pointer is now over none of the regions; otherwise `nil`.
    public mutating func exited(_ region: Region) -> IslandEvent? {
        guard inside.remove(region) != nil else { return nil }
        return inside.isEmpty ? .pointerExited : nil
    }

    /// The island now covers `region` (the zone of the notch it arrived at, whose panel leaves the screen and
    /// so never says the pointer left): a pointer over it is over the island. Never an event: the pointer
    /// is as inside as it was.
    public mutating func islandCovers(_ region: Region) {
        guard inside.remove(region) != nil else { return }
        inside.insert(.island)
    }
}
