// SPDX-License-Identifier: GPL-3.0-or-later

/// What the island shows (notch design §5.1). Task 16b adds the states of a take being saved.
public enum IslandState: Equatable, Sendable {
    /// Nothing: on a screen with a notch it is the notch; elsewhere it is not drawn.
    case rest
    /// The pointer is over the notch (or the top center of a screen without one): "New Recording".
    case peek
    /// The panel: what to record, the camera, audio and Record.
    case open
    /// Choosing what to record on the screen itself.
    case choosing
    /// The countdown before a take: the number of seconds left.
    case countdown(remaining: Int)
    /// A take is being recorded: the wings at each side of the notch, with the time and the microphone.
    case recording
    /// The pointer is over the recording island: the time, the take's controls and its notices.
    case recordingOpen

    /// Whether the island is the key window: only in the states that use the keyboard (Esc, and a click
    /// elsewhere closing it), so it never keeps what the user types in their own app. While recording
    /// it never is: Esc closes the island, not the take (notch design §5.1).
    public var needsKeyboard: Bool {
        switch self {
        case .rest, .peek, .recording, .recordingOpen: false
        case .open, .choosing, .countdown: true
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
    /// The recording controller is in a new phase: a take counts down, starts, records, closes or ends.
    case phaseChanged(RecordingController.Phase)
    /// The open recording island shows a confirmation (restarting the take), or no longer does: while it
    /// does, the island stays open.
    case confirmationShown(Bool)
}

/// Which state the island is in, from what happens to it. `now` is a monotonic time the app passes
/// (`ContinuousClock.now` minus an origin); when `deadline` is set, the app calls `tick` once it is reached.
public struct IslandMachine: Equatable, Sendable {
    /// How long a peek waits after the pointer leaves before going back to rest: enough to reach the pill
    /// 38 pt below the zone of a screen without a notch.
    public static let peekGrace: Duration = .milliseconds(300)
    /// How long the open recording island waits after the pointer leaves before collapsing to the wings.
    public static let collapseDelay: Duration = .milliseconds(650)

    public private(set) var state = IslandState.rest
    /// When the machine wants a `tick`.
    public private(set) var deadline: Duration?
    /// The pointer is over the island (the last of `pointerEntered` and `pointerExited`).
    private var isPointerInside = false
    /// The open recording island shows a confirmation.
    private var isConfirming = false

    public init() {}

    public mutating func handle(_ event: IslandEvent, at now: Duration) {
        switch event {
        case .pointerEntered: isPointerInside = true
        case .pointerExited: isPointerInside = false
        case .confirmationShown(let shown): isConfirming = shown
        default: break
        }
        if case .phaseChanged(let phase) = event {
            follow(phase)
            return
        }
        switch (state, event) {
        case (.recording, .pointerEntered):
            go(to: .recordingOpen)
        case (.recordingOpen, .pointerEntered), (.recordingOpen, .confirmationShown(true)):
            deadline = nil
        case (.recordingOpen, .pointerExited), (.recordingOpen, .confirmationShown(false)):
            if !isPointerInside, !isConfirming { deadline = now + Self.collapseDelay }
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
        case .recordingOpen: go(to: .recording)
        case .rest, .open, .choosing, .countdown, .recording: self.deadline = nil
        }
    }

    /// The take's phase moves the island: the countdown from wherever it is; the wings once the take starts
    /// (the open recording island stays open); rest once the take has closed, or did not start. A phase
    /// that is not a take's changes nothing at rest, open or choosing. Task 16b shows a take being saved
    /// instead of going to rest while it closes.
    private mutating func follow(_ phase: RecordingController.Phase) {
        switch phase {
        case .countingDown(let remaining):
            go(to: .countdown(remaining: remaining))
        case .starting, .recording:
            if state != .recordingOpen, state != .recording { go(to: .recording) }
        case .stopping:
            go(to: .rest)
        case .idle:
            switch state {
            case .countdown, .recording, .recordingOpen: go(to: .rest)
            case .rest, .peek, .open, .choosing: break
            }
        }
    }

    private mutating func go(to state: IslandState) {
        self.state = state
        deadline = nil
        if state != .recordingOpen { isConfirming = false }
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
