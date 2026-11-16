// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import Recording
import Synchronization

/// `RecordingTicks` that only move when the test says: a `sleep` waits until `releaseSleep(of:)` lets it go
/// (or its task is cancelled), and a timer fires only on `fire(every:)`.
///
/// The pending sleeps are a multiset without order between durations: while a take records, the
/// coordinator's maintenance (`syncInterval`) and disk watchdog (`DiskSpaceMonitor.interval`) always wait.
public final class ManualTicks: Sendable {
    private struct Sleeper {
        let id: Int
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Timer {
        let id: Int
        let interval: Duration
        let queue: DispatchSerialQueue
        let handler: @Sendable () -> Void
    }

    private struct State {
        var nextID = 0
        /// Oldest first.
        var sleepers: [Sleeper] = []
        /// What `releaseSleep(of:)` waits on, by the ID of the sleep it let go.
        var released: [Int: CheckedContinuation<Void, Never>] = [:]
        var timers: [Timer] = []

        mutating func makeID() -> Int {
            defer { nextID += 1 }
            return nextID
        }
    }

    private let state = Mutex(State())

    public init() {}

    public var ticks: RecordingTicks {
        RecordingTicks(
            sleep: { [self] duration in try await sleep(duration) },
            every: { [self] interval, queue, handler in schedule(every: interval, on: queue, handler) }
        )
    }

    /// Sleeps of `duration` waiting now.
    public func pendingSleeps(of duration: Duration) -> Int {
        state.withLock { $0.sleepers.count { $0.duration == duration } }
    }

    /// Timers of `interval` scheduled and not cancelled.
    public func timers(every interval: Duration) -> Int {
        state.withLock { $0.timers.count { $0.interval == interval } }
    }

    /// Runs, on its queue, each timer of `interval` not cancelled, one after the other, and returns once
    /// the last has run.
    public func fire(every interval: Duration) async {
        let timers = state.withLock { $0.timers.filter { $0.interval == interval } }
        for timer in timers {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                timer.queue.async { [self] in
                    if state.withLock({ $0.timers.contains { $0.id == timer.id } }) { timer.handler() }
                    done.resume()
                }
            }
        }
    }

    /// Lets the oldest sleep of `duration` go, and returns once its task has gone on from it. Does nothing
    /// if no sleep of `duration` is waiting.
    public func releaseSleep(of duration: Duration) async {
        await withCheckedContinuation { (wentOn: CheckedContinuation<Void, Never>) in
            let sleeper = state.withLock { state -> Sleeper? in
                guard let i = state.sleepers.firstIndex(where: { $0.duration == duration }) else { return nil }
                let sleeper = state.sleepers.remove(at: i)
                state.released[sleeper.id] = wentOn
                return sleeper
            }
            guard let sleeper else { return wentOn.resume() }
            sleeper.continuation.resume()
        }
    }

    // MARK: - Private

    /// Waits until `releaseSleep(of:)` lets it go; throws `CancellationError`, and stops waiting, once its
    /// task is cancelled.
    private func sleep(_ duration: Duration) async throws {
        let id = state.withLock { $0.makeID() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                state.withLock { $0.sleepers.append(Sleeper(id: id, duration: duration, continuation: continuation)) }
                // Cancelled before it was waiting: the handler found nothing to end.
                if Task.isCancelled { endSleep(id) }
            }
        } onCancel: {
            endSleep(id)
        }
        let wentOn = state.withLock { $0.released.removeValue(forKey: id) }
        wentOn?.resume()
    }

    /// Ends sleep `id` with `CancellationError`, unless it was let go or ended already.
    private func endSleep(_ id: Int) {
        let sleeper = state.withLock { state -> Sleeper? in
            guard let i = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
            return state.sleepers.remove(at: i)
        }
        sleeper?.continuation.resume(throwing: CancellationError())
    }

    private func schedule(every interval: Duration, on queue: DispatchSerialQueue, _ handler: @escaping @Sendable () -> Void)
        -> any RecordingTimer
    {
        let id = state.withLock { state in
            let id = state.makeID()
            state.timers.append(Timer(id: id, interval: interval, queue: queue, handler: handler))
            return id
        }
        return ManualTimer(id: id, owner: self)
    }

    fileprivate func cancelTimer(_ id: Int) {
        state.withLock { $0.timers.removeAll { $0.id == id } }
    }
}

private struct ManualTimer: RecordingTimer {
    let id: Int
    let owner: ManualTicks

    func cancel() {
        owner.cancelTimer(id)
    }
}
