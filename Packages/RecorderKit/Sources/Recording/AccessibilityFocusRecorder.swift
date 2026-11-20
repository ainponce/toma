// SPDX-License-Identifier: GPL-3.0-or-later
import Carbon
import Foundation
import os
import ProjectFormat
import Synchronization

/// Records where the keyboard's focus is while a take runs, for the automatic zoom to follow it (fases 4 y 5 design
/// §5.1): `focus` lines with only a rectangle, in global points as the cursor, from the readings of its `FocusSource`
/// (`AXFocusSource`, which needs Accessibility and never asks for it). Only in the takes the user chose to follow the
/// focus for (the app gives it to those alone). The `focus` event raises no version of the package.
///
/// Each reading gives up to two lines with its time, the element's first and then the text cursor's, so a reader knows
/// they go together. A kind is written only when its rectangle is not the last one written of that kind (its four
/// numbers); the start and each resume forget the last ones, so their first reading writes the state. The source reads
/// at most every 50 ms (`FocusReadSchedule`), so it is at most 20 lines a second of each kind.
///
/// Never written:
/// - anything but the rectangle and its kind: not what the element holds, its value, role, title nor app;
/// - the text cursor of a secure field: one whose role or subrole is `AXSecureTextField` (`FocusReading.isSecure`), or
///   any while secure input is on (`IsSecureEventInputEnabled()`, read for each reading). The element still is;
/// - a rectangle that is not valid (`isValid(_:as:)`): a number that is not finite, a coordinate beyond
///   `largestCoordinate`, a negative size, an element with no width or height, a text cursor with no height;
/// - anything while paused (the source is stopped then), nor a reading from before the start or the resume, nor after
///   `stop()`. `pause()` and `stop()` never wait for a reading under way: the lock makes sure nothing is appended once
///   they have returned;
/// - anything if the focus cannot be read (`isListening` is `false`; the app's log says so once a take).
///
/// The app's log never has a rectangle, a role nor the name of an app.
public final class AccessibilityFocusRecorder: InputRecorder, Sendable {
    /// The largest coordinate, in absolute value, of a rectangle that is written: 100 000 pt.
    static let largestCoordinate = 100_000.0

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "AccessibilityFocusRecorder")

    private struct State {
        var log: EventLogWriter?
        var paused = false
        var listening = false
        /// Readings from before this are not written: the start or the last resume.
        var acceptsFrom = HostTime(nanoseconds: 0)
        /// The last rectangle written of each kind since the start or the last resume.
        var lastElement: Rect?
        var lastCaret: Rect?
        /// The log said this take records no focus.
        var saidNoAccess = false
    }

    private let source: any FocusSource
    private let secureInput: @Sendable () -> Bool
    private let clock: @Sendable () -> HostTime
    private let noAccessibility: @Sendable () -> Void
    private let state = Mutex(State())

    public convenience init(
        source: any FocusSource = AXFocusSource(),
        secureInput: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }
    ) {
        self.init(source: source, secureInput: secureInput, clock: HostTime.now)
    }

    /// Tests pass their own clock, and see when the log would say the focus cannot be read.
    init(
        source: any FocusSource, secureInput: @escaping @Sendable () -> Bool, clock: @escaping @Sendable () -> HostTime,
        noAccessibility: (@Sendable () -> Void)? = nil
    ) {
        self.source = source
        self.secureInput = secureInput
        self.clock = clock
        self.noAccessibility = noAccessibility ?? {
            AccessibilityFocusRecorder.logger.notice("Accessibility is not allowed: this take records no focus")
        }
    }

    /// Whether the focus is being read: from a start or a resume that could, until the pause or the stop.
    public var isListening: Bool {
        state.withLock { $0.listening }
    }

    public func start(log: EventLogWriter) async {
        let now = clock()
        let started = state.withLock { s in
            guard s.log == nil else { return false }
            s = State()
            (s.log, s.acceptsFrom) = (log, now)
            return true
        }
        guard started else { return }
        listen()
    }

    /// Stops the source and returns: a reading under way is not waited for, and is not written.
    public func pause() async {
        let paused = state.withLock { s in
            guard s.log != nil, !s.paused else { return false }
            (s.paused, s.listening) = (true, false)
            return true
        }
        if paused { source.stop() }
    }

    /// Reads again from now on, and writes the focus as it is then even if it did not change in the pause.
    public func resume() async {
        let now = clock()
        let resumed = state.withLock { s in
            guard s.log != nil, s.paused else { return false }
            (s.paused, s.acceptsFrom, s.lastElement, s.lastCaret) = (false, now, nil, nil)
            return true
        }
        if resumed { listen() }
    }

    public func stop() async {
        state.withLock { $0 = State() }
        source.stop()
    }

    private func listen() {
        let listening = source.start { [weak self] reading, time in self?.record(reading, at: time) }
        let (wanted, say) = state.withLock { s -> (Bool, Bool) in
            let wanted = s.log != nil && !s.paused
            s.listening = listening && wanted
            guard !listening, wanted, !s.saidNoAccess else { return (wanted, false) }
            s.saidNoAccess = true
            return (wanted, true)
        }
        // A pause or a stop that came while the source started.
        if listening, !wanted { source.stop() }
        if say { noAccessibility() }
    }

    /// One reading, on the source's thread. Appends under the lock, so nothing is appended once `pause()` or `stop()`
    /// has returned. Secure input is read right before, for a reading with a text cursor.
    private func record(_ reading: FocusReading, at time: HostTime) {
        let secure = reading.caret != nil && secureInput()
        state.withLock { s in
            guard let log = s.log, !s.paused, time >= s.acceptsFrom else { return }
            for kind in Self.kinds(of: reading, secure: secure, last: (s.lastElement, s.lastCaret)) {
                log.append(InputEvent(t: time, kind: kind))
                guard case let .focus(x, y, width, height, focusKind) = kind else { continue }
                let written = Rect(x: x, y: y, width: width, height: height)
                switch focusKind {
                case .element: s.lastElement = written
                case .caret: s.lastCaret = written
                }
            }
        }
    }

    /// The `focus` kinds `reading` writes after `last`, the last rectangle written of each kind: the element's, if it
    /// is valid and changed, then the text cursor's, if it is valid, changed and neither `secure` (secure input is on)
    /// nor `reading.isSecure`.
    static func kinds(of reading: FocusReading, secure: Bool, last: (element: Rect?, caret: Rect?)) -> [InputEvent.Kind] {
        var kinds: [InputEvent.Kind] = []
        if let element = reading.element, isValid(element, as: .element), element != last.element {
            kinds.append(.focus(x: element.x, y: element.y, width: element.width, height: element.height, kind: .element))
        }
        if !secure, !reading.isSecure, let caret = reading.caret, isValid(caret, as: .caret), caret != last.caret {
            kinds.append(.focus(x: caret.x, y: caret.y, width: caret.width, height: caret.height, kind: .caret))
        }
        return kinds
    }

    /// Whether `rect` may be written as a `kind`: its numbers finite, its corners within `largestCoordinate` of the
    /// origin in absolute value, its size not negative and its height above 0; an element's width above 0 too (a text
    /// cursor's may be 0).
    static func isValid(_ rect: Rect, as kind: FocusKind) -> Bool {
        let numbers = [rect.x, rect.y, rect.width, rect.height]
        guard numbers.allSatisfy(\.isFinite), rect.width >= 0, rect.height > 0 else { return false }
        let coordinates = [rect.x, rect.y, rect.x + rect.width, rect.y + rect.height]
        guard coordinates.allSatisfy({ abs($0) <= largestCoordinate }) else { return false }
        switch kind {
        case .element: return rect.width > 0
        case .caret: return true
        }
    }
}
