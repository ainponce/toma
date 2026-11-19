// SPDX-License-Identifier: GPL-3.0-or-later
import Carbon
import CoreGraphics
import Dispatch
import Foundation
import os
import ProjectFormat
import Synchronization

/// Records which keys go down while a take runs, for the editor to show them (`keys.mode`): one `keyPress` line a key,
/// written on its own queue, with the key's code, what it types with only ⇧ (`chars`), its modifiers (only the bits of
/// `modifierMask`) and whether it is a repeat, at the time the key went down. Only in the takes the user chose to record
/// keys for (the app gives it to those alone). Lives alongside `KeyActivityRecorder`, which stays as it is.
///
/// Nothing is written:
/// - while secure input is on (`IsSecureEventInputEnabled()`, read for each key: a password field, Terminal's Secure
///   Keyboard Entry), so neither the password nor the ↩ that closes its field leaves a line;
/// - while paused (the keyboard is not listened to then), nor for a key from before the start or the resume, nor after
///   `stop()`;
/// - if the keyboard cannot be listened to (`isListening` is `false`, and the app's log says so);
/// - unless the package went to version 4 first: before the first line of a take it calls, once, the raise
///   `setFormatRaiser(_:)` gave (`RecordingCoordinator` gives `ManifestStore.raiseFormatVersion(to: 4)`). If that throws,
///   or no raise was given, no key is written for the rest of the take (the app's log says so, with no key in it). A take
///   with no key written leaves the package as it was.
///
/// The app's log never has a key, a code or a character.
public final class KeyPressRecorder: InputRecorder, FormatRaising, Sendable {
    /// The modifiers kept in `mods`: ⇧, ⌃, ⌥, ⌘ and fn (`CGEventFlags.maskShift`, `.maskControl`, `.maskAlternate`,
    /// `.maskCommand`, `.maskSecondaryFn`). Caps Lock, the numeric pad's bit and the device's own bits go.
    public static let modifierMask: UInt32 = [
        CGEventFlags.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn,
    ].reduce(0) { $0 | UInt32(truncatingIfNeeded: $1.rawValue) }

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "KeyPressRecorder")

    private struct State {
        var log: EventLogWriter?
        var paused = false
        var listening = false
        /// Keys from before this were not recorded: the start or the last resume.
        var acceptsFrom = HostTime(nanoseconds: 0)
        var raise: (@Sendable () throws -> Void)?
        /// The package is at 4 for this take.
        var raised = false
        /// The raise failed, or there was none: nothing more this take.
        var off = false
    }

    /// What a key leaves to say outside the lock.
    private enum Outcome {
        case none, noRaiser, raiseFailed(any Error)
    }

    private let source: any KeyEventSource
    private let secureInput: @Sendable () -> Bool
    private let clock: @Sendable () -> HostTime
    private let queue = DispatchSerialQueue(label: "dev.toma.key-press", qos: .userInteractive)
    private let state = Mutex(State())

    public convenience init(
        source: any KeyEventSource = KeyEventTap(),
        secureInput: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }
    ) {
        self.init(source: source, secureInput: secureInput, clock: HostTime.now)
    }

    /// Tests pass their own clock.
    init(source: any KeyEventSource, secureInput: @escaping @Sendable () -> Bool, clock: @escaping @Sendable () -> HostTime) {
        self.source = source
        self.secureInput = secureInput
        self.clock = clock
    }

    /// Whether the keyboard is being listened to: from a start or a resume that could, until the pause or the stop.
    public var isListening: Bool {
        state.withLock { $0.listening }
    }

    public func setFormatRaiser(_ raise: @escaping @Sendable () throws -> Void) {
        state.withLock { $0.raise = raise }
    }

    /// Keeps the raise given before it.
    public func start(log: EventLogWriter) async {
        let now = clock()
        let started = state.withLock { s in
            guard s.log == nil else { return false }
            let raise = s.raise
            s = State()
            (s.log, s.acceptsFrom, s.raise) = (log, now, raise)
            return true
        }
        guard started else { return }
        listen()
    }

    public func pause() async {
        let paused = state.withLock { s in
            guard s.log != nil, !s.paused else { return false }
            (s.paused, s.listening) = (true, false)
            return true
        }
        if paused { source.stop() }
    }

    /// Listens again from now on: a key from the pause is not written. Not once the take has no keys any more.
    public func resume() async {
        let now = clock()
        let resumed = state.withLock { s in
            guard s.log != nil, s.paused else { return false }
            (s.paused, s.acceptsFrom) = (false, now)
            return !s.off
        }
        if resumed { listen() }
    }

    /// Forgets the raise too.
    public func stop() async {
        state.withLock { $0 = State() }
        source.stop()
    }

    private func listen() {
        let listening = source.start(on: queue) { [weak self] key, time in self?.record(key, at: time) }
        state.withLock { s in s.listening = listening && s.log != nil && !s.paused }
        if !listening {
            Self.logger.notice("The keyboard cannot be listened to: this take records no keys.")
        }
    }

    /// One key, on the queue. Raises and appends under the lock, so nothing is appended once `pause()` or `stop()` has
    /// returned.
    private func record(_ key: KeyEvent, at time: HostTime) {
        let secure = secureInput()
        let outcome = state.withLock { s -> Outcome in
            guard let log = s.log, !s.paused, !s.off, !secure, time >= s.acceptsFrom else { return .none }
            if !s.raised {
                guard let raise = s.raise else {
                    s.off = true
                    return .noRaiser
                }
                do {
                    try raise()
                } catch {
                    s.off = true
                    return .raiseFailed(error)
                }
                s.raised = true
            }
            log.append(InputEvent(
                t: time,
                kind: .keyPress(code: key.code, chars: key.chars, mods: key.mods & Self.modifierMask, isRepeat: key.isRepeat)))
            return .none
        }
        switch outcome {
        case .none:
            break
        case .noRaiser:
            Self.logger.error("Nothing raised the package to version 4: this take records no keys.")
        case .raiseFailed(let error):
            let error = error as NSError
            Self.logger.error(
                "The package could not be raised to version 4 (\(error.domain, privacy: .public) \(error.code, privacy: .public)): this take records no more keys.")
        }
    }
}
