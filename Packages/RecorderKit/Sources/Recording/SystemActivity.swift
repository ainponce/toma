// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import Synchronization

/// What the system does that stops capture for a while.
public enum SystemActivity: Sendable, Equatable {
    /// The Mac is about to sleep.
    case willSleep
    /// The Mac woke from sleep.
    case didWake
    /// The screen can no longer be captured: it was locked or the displays went to sleep.
    case screenLocked
    /// The screen is unlocked and the displays are awake again.
    case screenUnlocked
}

/// The system's sleep, wake, lock and display-sleep notifications as one stream.
public enum SystemActivityMonitor {
    /// Observes `NSWorkspace` sleep, wake and display-sleep notifications and the distributed
    /// `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` notifications. The observers are
    /// registered when the stream is created (events from then on are buffered until it is iterated)
    /// and removed when it terminates.
    ///
    /// Locking and display sleep are folded into one state: `screenLocked` is sent when the screen
    /// stops being capturable for either reason, and `screenUnlocked` only once it is unlocked and
    /// awake, so waking the displays onto the lock screen does not resume capture.
    public static func live() -> AsyncStream<SystemActivity> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let observers = SystemActivityObservers(continuation: continuation)
            continuation.onTermination = { _ in observers.remove() }
        }
    }
}

/// The notification observers behind `SystemActivityMonitor.live()`.
private final class SystemActivityObservers: Sendable {
    /// An observer token; `NotificationCenter` accepts its removal from any thread.
    private struct Token: @unchecked Sendable {
        let center: NotificationCenter
        let value: any NSObjectProtocol
    }

    private let tokens = Mutex<[Token]>([])
    private let screen = Mutex(ScreenAvailability())

    private let continuation: AsyncStream<SystemActivity>.Continuation

    init(continuation: AsyncStream<SystemActivity>.Continuation) {
        self.continuation = continuation
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        var added: [Token] = []
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @Sendable () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in handler() }
            added.append(Token(center: center, value: token))
        }
        observe(workspace, NSWorkspace.willSleepNotification) { continuation.yield(.willSleep) }
        observe(workspace, NSWorkspace.didWakeNotification) { continuation.yield(.didWake) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.updateScreen(displaysAsleep: true)
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.updateScreen(displaysAsleep: false)
        }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            self?.updateScreen(locked: true)
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in
            self?.updateScreen(locked: false)
        }
        tokens.withLock { $0 = added }
    }

    func remove() {
        for token in tokens.withLock({ tokens in defer { tokens = [] }; return tokens }) {
            token.center.removeObserver(token.value)
        }
    }

    /// Applies the change and sends what `ScreenAvailability` says. Yielding under the lock keeps the
    /// events in the order of the changes.
    private func updateScreen(locked: Bool? = nil, displaysAsleep: Bool? = nil) {
        screen.withLock { screen in
            if let activity = screen.apply(locked: locked, displaysAsleep: displaysAsleep) {
                continuation.yield(activity)
            }
        }
    }
}

/// Whether the screen can be captured, folding the lock and display sleep into one state: it stops
/// being capturable when either starts, and is capturable again only once both have ended, so waking
/// the displays onto the lock screen does not resume capture.
struct ScreenAvailability: Equatable {
    private(set) var locked = false
    private(set) var displaysAsleep = false

    var isAvailable: Bool { !locked && !displaysAsleep }

    /// Sets what is given and returns `screenLocked` or `screenUnlocked` when availability flips,
    /// otherwise `nil`.
    mutating func apply(locked: Bool? = nil, displaysAsleep: Bool? = nil) -> SystemActivity? {
        let wasAvailable = isAvailable
        if let locked { self.locked = locked }
        if let displaysAsleep { self.displaysAsleep = displaysAsleep }
        guard isAvailable != wasAvailable else { return nil }
        return isAvailable ? .screenUnlocked : .screenLocked
    }
}
