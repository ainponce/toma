// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Dispatch
import Foundation
import Synchronization

/// Unblocks a test that a regression would leave waiting forever, so that it fails instead of hanging the run.
///
/// Where the code under test must never wait (for a disk sync the test holds, for the other end of a FIFO), a bound on
/// the wall-clock time tells nothing that the test's ending does not, and fails under load. A watchdog instead runs
/// `release` once `after` passed, unless it was disarmed before: whatever waited goes on, and `disarm()` returns `true`,
/// which the test expects to be `false`. Nothing is timed: a correct run disarms it long before it fires, however
/// loaded the machine is.
public final class Watchdog: Sendable {
    private enum State { case armed, fired, disarmed }
    private let state = Mutex(State.armed)

    /// Runs `release` on a queue of its own after `after`, unless `disarm()` was called before.
    public init(after: Duration = .seconds(30), release: @escaping @Sendable () -> Void) {
        let (seconds, attoseconds) = after.components
        let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) { [self] in
            let fire = state.withLock { state in
                guard state == .armed else { return false }
                state = .fired
                return true
            }
            if fire { release() }
        }
    }

    /// Stops it from firing; returns whether it had fired already: the guarded wait was not over in time.
    @discardableResult
    public func disarm() -> Bool {
        state.withLock { state in
            if state == .armed { state = .disarmed }
            return state == .fired
        }
    }

    /// Whether it fired.
    public var fired: Bool { state.withLock { $0 == .fired } }
}

/// A watchdog for opens of the FIFOs (named pipes) at `paths`, which the code under test must open without blocking:
/// an `open(2)` without `O_NONBLOCK` waits for the other end forever, and no time limit interrupts a blocked system call.
/// When it fires it opens each FIFO itself with `O_WRONLY | O_NONBLOCK` and with `O_RDONLY | O_NONBLOCK`, which on macOS
/// releases an opener blocked on either side, keeps them open for a moment and closes them.
public final class FIFOWatchdog: Sendable {
    private let watchdog: Watchdog

    public init(paths: [String], after: Duration = .seconds(30)) {
        watchdog = Watchdog(after: after) {
            var opened: [Int32] = []
            for path in paths {
                for flags in [O_WRONLY | O_NONBLOCK, O_RDONLY | O_NONBLOCK] {
                    let descriptor = open(path, flags | O_CLOEXEC)
                    if descriptor >= 0 { opened.append(descriptor) }
                }
            }
            Thread.sleep(forTimeInterval: 1)
            for descriptor in opened { close(descriptor) }
        }
    }

    /// Stops it from firing; returns whether it had fired already: an open waited for the other end.
    @discardableResult
    public func disarm() -> Bool { watchdog.disarm() }
}
