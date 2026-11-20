// SPDX-License-Identifier: GPL-3.0-or-later

/// What the events of a take say is in force at a moment (fases 4 y 5 plan 5c, decision 7): where each display and
/// each window is, the cursor's image and position, the keyboard's focus and the camera's style. The Replay folds into
/// it the event files it prunes, so a saved take starts with the state its first second had, and a save re-emits it.
public struct ReplayEventState: Equatable, Sendable {
    /// The camera's style: the take's own, until a `cameraStyle` event changes it.
    public private(set) var cameraStyle: CameraStyle?

    /// The last event of each key, at the time it was logged.
    private var displays: [UInt32: InputEvent] = [:]
    private var windows: [String: InputEvent] = [:]
    private var cursorImage: InputEvent?
    /// A `cursor` at the position of the last `cursor`, `mouseDown`, `mouseUp` or `scroll`.
    private var position: InputEvent?
    private var focus: InputEvent?
    private var cameraStyleChange: InputEvent?

    /// The state before any event: the take's camera style (`TakeRecord.cameraStyle`).
    public init(cameraStyle: CameraStyle?) {
        self.cameraStyle = cameraStyle
    }

    /// Takes in `events`, by time: the last one of each key wins, also against what an earlier call folded (an event
    /// logged a little earlier can be in a later file), and of two at the same time the one after in `events`.
    public mutating func fold(_ events: [InputEvent]) {
        for event in events.sortedByTime() {
            switch event.kind {
            case let .displayGeometry(displayID, _, _):
                Self.keepLatest(event, in: &displays[displayID])
            case let .windowGeometry(track, _, _):
                Self.keepLatest(event, in: &windows[track])
            case .cursorImage:
                Self.keepLatest(event, in: &cursorImage)
            case let .cursor(x, y), let .mouseDown(_, x, y), let .mouseUp(_, x, y), let .scroll(_, _, x, y):
                // A button down is not state: a click is drawn only from its own `mouseDown`.
                Self.keepLatest(InputEvent(t: event.t, kind: .cursor(x: x, y: y)), in: &position)
            case .focus:
                Self.keepLatest(event, in: &focus)
            case let .cameraStyle(style):
                if Self.keepLatest(event, in: &cameraStyleChange) { cameraStyle = style }
            case .segmentStarted, .streamInterrupted, .paused, .resumed, .deviceChanged, .marker, .droppedSamples,
                 .audioClock, .keyActivity, .keyPress:
                continue
            }
        }
    }

    /// The state as events at the times they were logged, by time: what a later `fold` of them rebuilds (the
    /// `carried` of `ReplaySnapshot`), the camera's last `cameraStyle` change included.
    public var events: [InputEvent] {
        let all = Array(displays.keys.sorted().compactMap { displays[$0] })
            + windows.keys.sorted().compactMap { windows[$0] }
            + [cameraStyleChange, cursorImage, position, focus].compactMap { $0 }
        return all.sortedByTime()
    }

    /// The state as events at `t`, in this order: `displayGeometry` of each display (by `displayID`), `windowGeometry`
    /// of each window (by track), `cursorImage`, `cursor` and `focus`, each only if the events had one. The camera's
    /// style is not among them: a take says its first one in `TakeRecord.cameraStyle`.
    public func reEmitted(at t: HostTime) -> [InputEvent] {
        let state = displays.keys.sorted().compactMap { displays[$0] }
            + windows.keys.sorted().compactMap { windows[$0] }
            + [cursorImage, position, focus].compactMap { $0 }
        return state.map { InputEvent(t: t, kind: $0.kind) }
    }

    /// Puts `event` in `slot` unless what is there was logged later. Returns whether it did.
    @discardableResult
    private static func keepLatest(_ event: InputEvent, in slot: inout InputEvent?) -> Bool {
        if let current = slot, current.t > event.t { return false }
        slot = event
        return true
    }
}
