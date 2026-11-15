// SPDX-License-Identifier: GPL-3.0-or-later
import Synchronization

/// `withTimeLimit` gave up: the operation had not returned after `limit`.
public struct TimeLimitExceeded: Error, Equatable, Sendable {
    public var limit: Duration

    public init(limit: Duration) {
        self.limit = limit
    }
}

/// What `operation` returns or throws, if it does within `limit`; otherwise `TimeLimitExceeded`, at `limit`.
///
/// The operation runs in a task of its own, not a child task (a task group would wait for it): one that never returns,
/// a system call that hangs, is cancelled and left behind, and never keeps the caller waiting. A cancelled caller gets
/// `CancellationError` at once, and the operation is cancelled too.
public func withTimeLimit<T: Sendable>(_ limit: Duration, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = TimeLimitRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard race.wait(on: continuation) else { return }
            race.add(
                Task {
                    do {
                        race.finish(.success(try await operation()))
                    } catch {
                        race.finish(.failure(error))
                    }
                })
            race.add(
                Task {
                    // Cancelled once the operation has returned.
                    guard (try? await Task.sleep(for: limit)) != nil else { return }
                    race.finish(.failure(TimeLimitExceeded(limit: limit)))
                })
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// The first of the operation, the time limit and the caller's cancellation resumes the caller, once; the tasks still
/// running are cancelled then.
private final class TimeLimitRace<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        /// Decided before the caller waited: a cancellation that came first.
        var early: Result<T, any Error>?
        var decided = false
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// The caller waits on `continuation`; `false` when it was resumed already (the race was decided), and nothing
    /// is to start.
    func wait(on continuation: CheckedContinuation<T, any Error>) -> Bool {
        let early = state.withLock { state in
            if state.early == nil { state.continuation = continuation }
            return state.early
        }
        guard let early else { return true }
        continuation.resume(with: early)
        return false
    }

    /// `task` is cancelled once the race is decided, at once if it is.
    func add(_ task: Task<Void, Never>) {
        let decided = state.withLock { state in
            if !state.decided { state.tasks.append(task) }
            return state.decided
        }
        if decided { task.cancel() }
    }

    /// Resumes the caller with `result`, unless the race was decided.
    func finish(_ result: Result<T, any Error>) {
        let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<T, any Error>?, [Task<Void, Never>]) in
            guard !state.decided else { return (nil, []) }
            state.decided = true
            if state.continuation == nil { state.early = result }
            defer {
                state.continuation = nil
                state.tasks = []
            }
            return (state.continuation, state.tasks)
        }
        for task in tasks { task.cancel() }
        continuation?.resume(with: result)
    }
}
