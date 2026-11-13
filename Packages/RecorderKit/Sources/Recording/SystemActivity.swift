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

    private struct Screen {
        var locked = false
        var displaysAsleep = false
        var unavailable: Bool { locked || displaysAsleep }
    }

    private let tokens = Mutex<[Token]>([])
    private let screen = Mutex(Screen())

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
            self?.updateScreen { $0.displaysAsleep = true }
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.updateScreen { $0.displaysAsleep = false }
        }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            self?.updateScreen { $0.locked = true }
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in
            self?.updateScreen { $0.locked = false }
        }
        tokens.withLock { $0 = added }
    }

    func remove() {
        for token in tokens.withLock({ tokens in defer { tokens = [] }; return tokens }) {
            token.center.removeObserver(token.value)
        }
    }

    /// Applies `change` and sends `screenLocked` or `screenUnlocked` when availability flips.
    /// Yielding under the lock keeps the events in the order of the changes.
    private func updateScreen(_ change: (inout Screen) -> Void) {
        screen.withLock { screen in
            let wasUnavailable = screen.unavailable
            change(&screen)
            guard screen.unavailable != wasUnavailable else { return }
            continuation.yield(screen.unavailable ? .screenLocked : .screenUnlocked)
        }
    }
}
