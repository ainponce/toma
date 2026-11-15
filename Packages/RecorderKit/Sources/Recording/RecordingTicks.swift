// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import ProjectFormat

/// A repeating timer started by `RecordingTicks.every`. It fires until it is cancelled.
public protocol RecordingTimer: Sendable {
    func cancel()
}

/// How a take waits and repeats work: the restart backoff, the coordinator's maintenance and disk watchdog
/// (`sleep`), and each track's heartbeat and sync timers (`every`). `live` runs on the real clock; tests
/// drive them by hand (`ManualTicks`).
public struct RecordingTicks: Sendable {
    /// Waits `duration`. Throws `CancellationError` once its task is cancelled.
    public var sleep: @Sendable (Duration) async throws -> Void
    /// Runs the handler on the queue every interval, the first time one interval from now, until the timer
    /// it returns is cancelled.
    public var every: @Sendable (Duration, DispatchSerialQueue, @escaping @Sendable () -> Void) -> any RecordingTimer

    public init(
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        every: @escaping @Sendable (Duration, DispatchSerialQueue, @escaping @Sendable () -> Void) -> any RecordingTimer
    ) {
        self.sleep = sleep
        self.every = every
    }

    /// `Task.sleep(for:)`, and a `DispatchSourceTimer` on the given queue.
    public static let live = RecordingTicks(
        sleep: { try await Task.sleep(for: $0) },
        every: { interval, queue, handler in DispatchRecordingTimer(interval: interval, queue: queue, handler: handler) }
    )
}

/// A `DispatchSourceTimer` that may fire up to a fiftieth of its interval late (10 ms for the 500 ms heartbeat).
private final class DispatchRecordingTimer: RecordingTimer {
    private let source: any DispatchSourceTimer

    init(interval: Duration, queue: DispatchSerialQueue, handler: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeTimerSource(queue: queue)
        source.setEventHandler(handler: handler)
        let repeating = interval.dispatchInterval
        source.schedule(deadline: .now() + repeating, repeating: repeating, leeway: (interval / 50).dispatchInterval)
        source.activate()
    }

    func cancel() {
        source.cancel()
    }
}
