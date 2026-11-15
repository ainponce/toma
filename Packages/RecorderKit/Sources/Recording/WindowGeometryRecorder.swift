// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Dispatch
import Foundation
import ProjectFormat
import Synchronization

/// Where a window is and whether it is on screen.
public struct WindowState: Equatable, Sendable {
    /// Global points, origin at the top left of the main display.
    public var frame: Rect
    /// `kCGWindowIsOnscreen`: `false` both when the window is minimized and when it is in another Space.
    public var onScreen: Bool

    public init(frame: Rect, onScreen: Bool) {
        self.frame = frame
        self.onScreen = onScreen
    }
}

/// Whether a recorded window can be seen in the recording. `kCGWindowIsOnscreen` says `false` both for a minimized
/// window and for one in another Space, and a window in another Space is still recorded (spec §6): the frames tell
/// them apart.
public enum WindowVisibility: String, Codable, Sendable {
    /// On screen.
    case visible
    /// Not on screen, but its frames keep coming: it is in another Space.
    case otherSpace
    /// Not on screen and no frame for `hiddenAfterSeconds` (or none yet): minimized or hidden, or still in another Space.
    case hidden

    public static let hiddenAfterSeconds = 1.0

    /// `secondsSinceCompleteFrame` is `nil` before the first complete frame.
    public static func verdict(onScreen: Bool, secondsSinceCompleteFrame: Double?) -> WindowVisibility {
        if onScreen { return .visible }
        guard let seconds = secondsSinceCompleteFrame, seconds < hiddenAfterSeconds else { return .hidden }
        return .otherSpace
    }
}

/// Samples a recorded window at `sampleRate` Hz while a take runs and writes a `windowGeometry` event whenever its
/// frame or `onScreen` changes, `onScreen` as it is (the render hides the cursor in both cases). Each change of
/// `WindowVisibility.verdict` goes to `onVisibilityChange`; the window starts out visible, as the take's first
/// `windowGeometry` says. A window that does not exist (closed) writes nothing. Nothing is written while paused.
///
/// The first sample repeats the take's first `windowGeometry`, which the coordinator writes: harmless, the render
/// takes the last one at or before each time.
public final class WindowGeometryRecorder: InputRecorder, Sendable {
    public static let sampleRate = 10.0

    private struct State {
        var log: EventLogWriter?
        var timer: DispatchSourceTimer?
        var paused = false
        var last: WindowState?
        var visibility = WindowVisibility.visible
    }

    private let trackID: String
    private let windowID: CGWindowID
    private let clock: @Sendable () -> HostTime
    private let query: @Sendable (CGWindowID) -> WindowState?
    private let lastCompleteFrame: @Sendable () -> HostTime?
    private let onVisibilityChange: @Sendable (WindowVisibility) -> Void
    private let queue = DispatchSerialQueue(label: "dev.toma.window-geometry")
    private let state = Mutex(State())

    /// `lastCompleteFrame` is when the window's track last got a complete frame (`WindowCaptureSource`).
    public init(
        trackID: String,
        windowID: CGWindowID,
        clock: @escaping @Sendable () -> HostTime = HostTime.now,
        query: @escaping @Sendable (CGWindowID) -> WindowState? = WindowGeometryRecorder.liveQuery,
        lastCompleteFrame: @escaping @Sendable () -> HostTime? = { nil },
        onVisibilityChange: @escaping @Sendable (WindowVisibility) -> Void = { _ in }
    ) {
        self.trackID = trackID
        self.windowID = windowID
        self.clock = clock
        self.query = query
        self.lastCompleteFrame = lastCompleteFrame
        self.onVisibilityChange = onVisibilityChange
    }

    /// The window's `kCGWindowBounds` and `kCGWindowIsOnscreen`, or `nil` if it does not exist.
    public static func liveQuery(_ windowID: CGWindowID) -> WindowState? {
        WindowListEntry(windowID: windowID).map { WindowState(frame: Rect($0.bounds), onScreen: $0.onScreen) }
    }

    public func start(log: EventLogWriter) async {
        state.withLock { s in
            guard s.log == nil else { return }
            s.log = log
            s.paused = false
            s.last = nil
            s.visibility = .visible
            s.timer = makeSamplingTimer()
        }
    }

    /// Stops sampling until `resume()`; a sample in flight has finished when it returns.
    public func pause() async {
        let timer = state.withLock { s -> DispatchSourceTimer? in
            guard s.log != nil, !s.paused else { return nil }
            s.paused = true
            defer { s.timer = nil }
            return s.timer
        }
        guard let timer else { return }
        timer.cancel()
        await queue.drain()
    }

    /// Samples again, at once: a change during the pause is written now.
    public func resume() async {
        state.withLock { s in
            guard s.log != nil, s.paused else { return }
            s.paused = false
            s.timer = makeSamplingTimer()
        }
    }

    public func stop() async {
        let timer = state.withLock { s -> DispatchSourceTimer? in
            defer {
                s.log = nil
                s.timer = nil
                s.paused = false
            }
            return s.timer
        }
        timer?.cancel()
        await queue.drain()
    }

    private func makeSamplingTimer() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / Self.sampleRate)), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        return timer
    }

    /// On `queue`. Holding the lock across the append guarantees nothing is appended once `stop()` or `pause()` has
    /// returned; the visibility is told outside it, in the order of the samples.
    private func sample() {
        let window = query(windowID)
        let time = clock()
        let secondsSinceFrame = lastCompleteFrame().map { time.seconds(since: $0) }
        let change = state.withLock { s -> WindowVisibility? in
            guard let log = s.log, !s.paused, let window else { return nil }
            if s.last != window {
                s.last = window
                log.append(InputEvent(t: time, kind: .windowGeometry(track: trackID, frame: window.frame, onScreen: window.onScreen)))
            }
            let visibility = WindowVisibility.verdict(onScreen: window.onScreen, secondsSinceCompleteFrame: secondsSinceFrame)
            guard visibility != s.visibility else { return nil }
            s.visibility = visibility
            return visibility
        }
        if let change { onVisibilityChange(change) }
    }
}
