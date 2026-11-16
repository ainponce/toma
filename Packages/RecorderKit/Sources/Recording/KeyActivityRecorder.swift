// SPDX-License-Identifier: GPL-3.0-or-later
import Carbon
import CoreGraphics
import Foundation
import os
import ProjectFormat
import Synchronization

/// Notes when keys are typed while a take runs, never which: every `interval` it reads how long ago the last key went
/// down (`secondsSinceLastKey`, which carries no key, code or character) and, if one went down since the reading before,
/// logs a `keyActivity` event at the start of the `window` it fell in, one per window. The fixed window hides the rhythm
/// between keys. It listens to no keyboard event and asks for no permission (plan decision 13).
///
/// Nothing is logged:
/// - while paused, nor for a key from before the start or the resume, nor in a window that began before them (part of
///   it was not recorded);
/// - unless secure input (a password field, Terminal's Secure Keyboard Entry) was off both at the reading before and at
///   this one, so the Enter that closes a password field leaves no line either;
/// - for a reading that `isUsable` refuses (not finite, or negative);
/// - for the rest of the take once the reading follows the mouse: `mouseEchoPolls` readings in a row, each with the
///   mouse moving (`.mouseMoved` less than 1/30 s ago), within `mouseEchoTolerance` of the mouse's. Then it is not the
///   keyboard's. A reading with the mouse still, or one that cannot be used, says nothing about that: it neither counts
///   nor breaks the run.
///
/// At the start of each take it notes in the app's log what `listenAccess` says (whether Input Monitoring is granted;
/// asking never shows a prompt), with no data about the keys.
public final class KeyActivityRecorder: InputRecorder, Sendable {
    /// The length of a window, in nanoseconds of host time: windows start at its multiples.
    public static let window: UInt64 = 250_000_000
    public static let mouseEchoPolls = 10
    /// Seconds.
    public static let mouseEchoTolerance = 0.002
    /// How often it reads.
    public static let interval: Duration = .nanoseconds(33_333_333)
    /// The mouse moved less than this many seconds ago: it is moving.
    static let mouseMoving = 1.0 / 30

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "KeyActivityRecorder")

    private struct State {
        var log: EventLogWriter?
        var paused = false
        var timer: (any RecordingTimer)?
        /// When the reading before was taken (or the take started or resumed), and whether secure input was on then.
        var previous: (time: HostTime, secure: Bool)?
        /// Windows that start before this were not recorded whole: the start or the last resume.
        var acceptsFrom = HostTime(nanoseconds: 0)
        /// The start of the last window logged.
        var lastWindow: HostTime?
        /// Readings in a row, with the mouse moving, that matched the mouse's.
        var echoes = 0
        /// The reading follows the mouse: nothing more this take.
        var off = false
        /// The app's log already says a reading could not be used this take.
        var toldUnusable = false
    }

    /// What a reading leaves to do outside the lock.
    private enum Outcome {
        case none
        case unusable
        case off(timer: (any RecordingTimer)?)
    }

    private let secondsSinceLastKey: @Sendable () -> Double
    private let secondsSinceLastMouseMove: @Sendable () -> Double
    private let secureInput: @Sendable () -> Bool
    private let listenAccess: @Sendable () -> Bool
    private let clock: @Sendable () -> HostTime
    private let ticks: RecordingTicks
    private let queue = DispatchSerialQueue(label: "dev.toma.key-activity", qos: .utility)
    private let state = Mutex(State())

    public convenience init(
        secondsSinceLastKey: @escaping @Sendable () -> Double = {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        },
        secondsSinceLastMouseMove: @escaping @Sendable () -> Double = {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
        },
        secureInput: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() },
        listenAccess: @escaping @Sendable () -> Bool = { CGPreflightListenEventAccess() },
        clock: @escaping @Sendable () -> HostTime = HostTime.now
    ) {
        self.init(
            secondsSinceLastKey: secondsSinceLastKey, secondsSinceLastMouseMove: secondsSinceLastMouseMove,
            secureInput: secureInput, listenAccess: listenAccess, clock: clock, ticks: .live)
    }

    /// Tests pass their own ticks.
    init(
        secondsSinceLastKey: @escaping @Sendable () -> Double, secondsSinceLastMouseMove: @escaping @Sendable () -> Double,
        secureInput: @escaping @Sendable () -> Bool, listenAccess: @escaping @Sendable () -> Bool,
        clock: @escaping @Sendable () -> HostTime, ticks: RecordingTicks
    ) {
        self.secondsSinceLastKey = secondsSinceLastKey
        self.secondsSinceLastMouseMove = secondsSinceLastMouseMove
        self.secureInput = secureInput
        self.listenAccess = listenAccess
        self.clock = clock
        self.ticks = ticks
    }

    /// The start of the window `key` falls in: the multiple of `window` at or before it.
    public static func windowStart(of key: HostTime) -> HostTime {
        HostTime(nanoseconds: key.nanoseconds - key.nanoseconds % window)
    }

    /// Whether a reading of seconds since an event can be used: finite and not negative.
    public static func isUsable(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds >= 0
    }

    public func start(log: EventLogWriter) async {
        let (time, secure) = (clock(), secureInput())
        let started = state.withLock { s in
            guard s.log == nil else { return false }
            s = State()
            s.log = log
            s.previous = (time, secure)
            s.acceptsFrom = time
            s.timer = makeTimer()
            return true
        }
        guard started else { return }
        let access = listenAccess() ? "granted" : "not granted"
        Self.logger.notice(
            "A take starts noting when keys are typed. Input Monitoring is \(access, privacy: .public) (CGPreflightListenEventAccess).")
    }

    public func pause() async {
        let timer = state.withLock { s -> (any RecordingTimer)? in
            guard s.log != nil, !s.paused else { return nil }
            s.paused = true
            defer { s.timer = nil }
            return s.timer
        }
        timer?.cancel()
    }

    /// Reads again from now on: a key from the pause is not noted.
    public func resume() async {
        let (time, secure) = (clock(), secureInput())
        state.withLock { s in
            guard s.log != nil, s.paused else { return }
            s.paused = false
            s.previous = (time, secure)
            s.acceptsFrom = time
            s.echoes = 0
            if !s.off { s.timer = makeTimer() }
        }
    }

    public func stop() async {
        let timer = state.withLock { s -> (any RecordingTimer)? in
            defer { s = State() }
            return s.timer
        }
        timer?.cancel()
    }

    private func makeTimer() -> any RecordingTimer {
        ticks.every(Self.interval, queue) { [weak self] in self?.poll() }
    }

    /// One reading. Appends under the lock, so nothing is appended once `stop()` has cleared the log or `pause()` has
    /// returned.
    private func poll() {
        let time = clock()
        let key = secondsSinceLastKey()
        let mouse = secondsSinceLastMouseMove()
        let secure = secureInput()
        let outcome = state.withLock { s -> Outcome in
            guard let log = s.log, !s.paused, !s.off, let previous = s.previous else { return .none }
            s.previous = (time, secure)
            guard Self.isUsable(key) else {
                if s.toldUnusable { return .none }
                s.toldUnusable = true
                return .unusable
            }
            if Self.isUsable(mouse), mouse < Self.mouseMoving {
                s.echoes = abs(key - mouse) <= Self.mouseEchoTolerance ? s.echoes + 1 : 0
                if s.echoes >= Self.mouseEchoPolls {
                    s.off = true
                    defer { s.timer = nil }
                    return .off(timer: s.timer)
                }
            }
            guard !previous.secure, !secure else { return .none }
            let pressed = time.adding(seconds: -key)
            guard pressed > previous.time else { return .none }
            let window = Self.windowStart(of: pressed)
            guard window >= s.acceptsFrom, s.lastWindow.map({ window > $0 }) ?? true else { return .none }
            s.lastWindow = window
            log.append(InputEvent(t: window, kind: .keyActivity))
            return .none
        }
        switch outcome {
        case .none:
            break
        case .unusable:
            Self.logger.notice("The time since the last key could not be used; nothing is noted while it cannot.")
        case .off(let timer):
            timer?.cancel()
            Self.logger.notice(
                "The time since the last key follows the mouse, not the keyboard: nothing more is noted this take.")
        }
    }
}
