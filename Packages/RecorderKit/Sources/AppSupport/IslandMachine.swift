// SPDX-License-Identifier: GPL-3.0-or-later

/// What the island shows (notch design §5.1).
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
    /// A notice that asks for attention, for `IslandMachine.noticeDuration`: compact, just under the notch.
    case notice(TakeNotice)
    /// The take is being closed.
    case saving
    /// The take was saved: how long it is, its markers and its tracks; with "Stay Where I Am", what to do next.
    case saved(SavedTake)

    /// Whether the island is the key window: only in the states that use the keyboard (Esc, and a click
    /// elsewhere closing it), so it never keeps what the user types in their own app. While recording
    /// it never is: Esc closes the island, not the take (notch design §5.1). Nor while it shows a notice
    /// or a take being saved, which come by themselves.
    public var needsKeyboard: Bool {
        switch self {
        case .rest, .peek, .recording, .recordingOpen, .notice, .saving, .saved: false
        case .open, .choosing, .countdown: true
        }
    }

    /// Whether the island takes the keyboard on going from `before` to `after`: on entering a state that
    /// uses it, but never from one second of the countdown to the next, so a user who clicked into their
    /// own app meanwhile keeps the keyboard.
    public static func becomesKey(from before: IslandState, to after: IslandState) -> Bool {
        guard after.needsKeyboard else { return false }
        if case .countdown = before, case .countdown = after { return false }
        return true
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
    /// The take's notices, as they are now (`RecordingController.notices`).
    case noticesChanged([TakeNotice])
    /// A stop closed and kept a take (`RecordingController.lastSaved`).
    case saved(SavedTake)
    /// A take could not start: the open island says why.
    case startFailed
}

/// Which state the island is in, from what happens to it. `now` is a monotonic time the app passes
/// (`ContinuousClock.now` minus an origin); when `deadline` is set, the app calls `tick` once it is reached.
public struct IslandMachine: Equatable, Sendable {
    /// How long a peek waits after the pointer leaves before going back to rest: enough to reach the pill
    /// 38 pt below the zone of a screen without a notch.
    public static let peekGrace: Duration = .milliseconds(300)
    /// How long the open recording island waits after the pointer leaves before collapsing to the wings.
    public static let collapseDelay: Duration = .milliseconds(650)
    /// How long a new notice that asks for attention shows by itself (notch design §5.1).
    public static let noticeDuration: Duration = .seconds(4)
    /// How long a saved take stays with "Stay Where I Am", unless something is chosen (plan decision 30).
    public static let savedStayDuration: Duration = .seconds(8)
    /// How long a saved take shows while its editor opens, unless the take stopped by itself or closed with
    /// an error: then it stays `savedStayDuration`, so its reason can be read.
    public static let savedWhileEditorOpens: Duration = .milliseconds(1500)
    /// How long the island waits, once the take is closed, for it to be saved: a take that recorded nothing
    /// (a start that failed with a stop waiting for it) or that a quit closed is never saved.
    public static let savingGrace: Duration = .seconds(1)

    public private(set) var state = IslandState.rest
    /// When the machine wants a `tick`.
    public private(set) var deadline: Duration?
    /// The right wing's icon: `.stopped` if any notice of the take is, otherwise `.attention` if any is, and
    /// `nil` when none asks for attention.
    public private(set) var attention: NoticePresentation?
    /// The open island says why the last take could not start, until the next one counts down or starts, or
    /// the island closes.
    public private(set) var hasStartFailure = false
    /// The pointer is over the island (the last of `pointerEntered` and `pointerExited`).
    private var isPointerInside = false
    /// The open recording island shows a confirmation.
    private var isConfirming = false
    /// The take's notices, as they were last told.
    private var notices: [TakeNotice] = []
    /// The new notices that ask for attention and wait for their turn, in the order they came: the start's,
    /// which came during the countdown or with the panel open, until the take records; the ones that came
    /// while another showed, until it is over. A notice resolved meanwhile no longer waits.
    private var pending: [TakeNotice] = []

    public init() {}

    public mutating func handle(_ event: IslandEvent, at now: Duration) {
        switch event {
        case .pointerEntered: isPointerInside = true
        case .pointerExited: isPointerInside = false
        case .confirmationShown(let shown): isConfirming = shown
        case .phaseChanged(let phase):
            follow(phase, at: now)
            return
        case .noticesChanged(let notices):
            noticesChanged(notices, at: now)
            return
        case .saved(let take):
            saved(take, at: now)
            return
        case .startFailed:
            hasStartFailure = true
            go(to: .open)
            return
        case .clicked, .toggle, .dismiss, .beganChoosing, .endedChoosing:
            break
        }
        switch (state, event) {
        case (.recording, .pointerEntered), (.notice, .pointerEntered):
            // Its list shows them all.
            pending = []
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
            hasStartFailure = false
            go(to: .rest)
        case (.saved, .toggle), (.saved, .clicked):
            // Record Another.
            go(to: .open)
        case (.saved, .dismiss):
            // Close, or Open in the Editor.
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
        case .peek, .saving, .saved: go(to: .rest)
        case .recordingOpen: go(to: .recording)
        case .notice: showNextOrWings(at: now)
        case .rest, .open, .choosing, .countdown, .recording: self.deadline = nil
        }
    }

    /// The take's phase moves the island: the countdown from wherever it is; the wings once the take starts
    /// (the open recording island and a notice stay), and then the first notice that waited, if none shows;
    /// a take being saved while it closes; rest once the take has closed without being saved, or did not
    /// start. A phase that is not a take's changes nothing at rest, open, choosing or saved.
    private mutating func follow(_ phase: RecordingController.Phase, at now: Duration) {
        switch phase {
        case .countingDown(let remaining):
            hasStartFailure = false
            go(to: .countdown(remaining: remaining))
        case .starting:
            hasStartFailure = false
            if !showsTheTake { go(to: .recording) }
        case .recording:
            if !showsTheTake { go(to: .recording) }
            switch state {
            case .recording:
                if !pending.isEmpty { show(pending.removeFirst(), at: now) }
            case .recordingOpen:
                // Its list shows them all.
                pending = []
            default:
                // A notice shows: the ones that waited follow it.
                break
            }
        case .stopping:
            // What waited was about the take that closes.
            pending = []
            go(to: .saving)
        case .idle:
            pending = []
            switch state {
            case .saving: deadline = now + Self.savingGrace
            case .countdown, .recording, .recordingOpen, .notice: go(to: .rest)
            case .rest, .peek, .open, .choosing, .saved: break
            }
        }
    }

    /// The wings, the open recording island or a notice.
    private var showsTheTake: Bool {
        switch state {
        case .recording, .recordingOpen, .notice: true
        case .rest, .peek, .open, .choosing, .countdown, .saving, .saved: false
        }
    }

    /// A notice that asks for attention and was not in the last list shows by itself over the wings, or
    /// waits for its turn: until the take records if it came before, and until the ones before it have
    /// shown (confirmations are capsules: they never take a turn). The open recording island lists it
    /// instead. A notice that is no longer in the list (it was resolved) stops showing, or waiting.
    private mutating func noticesChanged(_ notices: [TakeNotice], at now: Duration) {
        let new = notices.filter { $0.presentation != .confirmation && !self.notices.contains($0) }
        self.notices = notices
        pending.removeAll { !notices.contains($0) }
        attention =
            if notices.contains(where: { $0.presentation == .stopped }) {
                .stopped
            } else if notices.contains(where: { $0.presentation == .attention }) {
                .attention
            } else {
                nil
            }
        switch state {
        case .recording:
            // With nothing waiting, the first shows now; otherwise (the take starts) they wait behind.
            let waited = !pending.isEmpty
            wait(new)
            if !waited, !pending.isEmpty { show(pending.removeFirst(), at: now) }
        case .notice(let shown):
            wait(new)
            if !notices.contains(shown) { showNextOrWings(at: now) }
        case .open, .countdown:
            wait(new)
        case .rest, .peek, .choosing, .recordingOpen, .saving, .saved:
            break
        }
    }

    private mutating func wait(_ notices: [TakeNotice]) {
        pending += notices.filter { !pending.contains($0) }
    }

    private mutating func show(_ notice: TakeNotice, at now: Duration) {
        go(to: .notice(notice))
        deadline = now + Self.noticeDuration
    }

    /// The notice showing is over: the next one that waited, or the wings.
    private mutating func showNextOrWings(at now: Duration) {
        if pending.isEmpty {
            go(to: .recording)
        } else {
            show(pending.removeFirst(), at: now)
        }
    }

    /// The take being saved was: it shows while its editor opens, or until something is chosen. A take that
    /// stopped by itself or closed with an error stays as long with its editor opening, so its reason is read.
    private mutating func saved(_ take: SavedTake, at now: Duration) {
        guard state == .saving else { return }
        go(to: .saved(take))
        let stopped = notices.contains { $0.presentation == .stopped }
        deadline = now + (take.openedEditor && !stopped ? Self.savedWhileEditorOpens : Self.savedStayDuration)
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
