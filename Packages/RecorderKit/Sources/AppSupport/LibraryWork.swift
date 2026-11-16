// SPDX-License-Identifier: GPL-3.0-or-later

/// The library's work that a quit waits for, in the whole app (design §6.8, `QuitSequencer`): its copies, counted from the
/// command to their end ("Duplicar como" until its first edit is written, a copy paused by a take included), and the gate
/// a quit closes, after which no new action of the library starts.
@MainActor
public final class LibraryWork {
    /// The app's.
    public static let shared = LibraryWork()

    /// A quit is going ahead: no new action of the library starts.
    public private(set) var isStopped = false
    /// How many commands are copying now.
    public private(set) var copies = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// A copy is being made: a quit waits for it (`TerminationDecision.decide(…isCopying:)`).
    public var isCopying: Bool { copies > 0 }

    public func stopNewOperations() {
        isStopped = true
    }

    public func beginCopy() {
        copies += 1
    }

    /// One `beginCopy` ended; those waiting go on once none is left.
    public func endCopy() {
        guard copies > 0 else { return }
        copies -= 1
        guard copies == 0 else { return }
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// Returns once no copy is being made.
    public func waitForCopies() async {
        guard copies > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
