// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import Synchronization

/// What one run of a capture source holds until the run ends: a capture session, a camera lease, a process tap.
protocol CaptureRunResource: Sendable {
    /// Lets go of it. May finish later, on a queue of the source's own that the source drains in `stop`.
    func end()
}

/// The run life cycle the live capture sources share, as `CaptureSource` describes it.
///
/// Every `start` and `stop` begins a new generation, so a `start` overtaken by a later call gives up: it cannot
/// install its run, or finds it gone when it finishes. One run at a time is active. A failure before the run has
/// started is kept for `start` to throw; after that the run ends, its resource first (so a restart from inside the
/// sink cannot overlap it), and the error is the run's last delivery, once. The queue of the last run installed is
/// kept when the run ends, so `start` and `stop` can wait for a delivery still running there.
///
/// The source keeps its own queues: it drains them, then the queue this returns, so that when `stop` returns
/// nothing more is delivered.
final class CaptureRunLifecycle<Resource: CaptureRunResource>: Sendable {
    enum StartOutcome {
        case started
        case failed(any Error)
        /// A later `start` or `stop` took the run, and ends its resource.
        case overtaken
    }

    /// The active run, as deliveries see it.
    struct ActiveRun: Sendable {
        let id: Int
        let resource: Resource
        let queue: DispatchSerialQueue
        let sink: any CaptureSink
    }

    private struct Run: Sendable {
        let id: Int
        let resource: Resource
        let queue: DispatchSerialQueue
        let sink: any CaptureSink
        /// Set once `start` is about to return successfully.
        var started = false
        /// An error before `started`, which `start` throws instead of delivering.
        var failure: (any Error)?

        var active: ActiveRun { ActiveRun(id: id, resource: resource, queue: queue, sink: sink) }
    }

    private struct State {
        var generation = 0
        var run: Run?
        var lastQueue: DispatchSerialQueue?
        /// Set by a successful start, kept after an error, cleared by `stop` (`CaptureSource.activeDeviceUniqueID`).
        var activeDeviceUniqueID: String?
    }

    private let trackID: String
    private let state = Mutex(State())

    init(trackID: String) {
        self.trackID = trackID
    }

    var activeDeviceUniqueID: String? { state.withLock { $0.activeDeviceUniqueID } }

    // MARK: - Start and stop

    /// The first step of `start`: a new generation, and the current run, if any, ends. Returns the new run's id
    /// and the queue of the last run installed, which `start` drains before building the new run.
    func beginStart() -> (id: Int, lastQueue: DispatchSerialQueue?) {
        let (id, previous, lastQueue) = state.withLock { state in
            state.generation += 1
            defer { state.run = nil }
            return (state.generation, state.run, state.lastQueue)
        }
        previous?.resource.end()
        return (id, lastQueue)
    }

    /// The first step of `stop`: a new generation, the device is forgotten, and the current run, if any, ends.
    /// Returns the queue of the last run installed, which `stop` drains after the source's own queues.
    func stop() -> DispatchSerialQueue? {
        let (run, lastQueue) = state.withLock { state in
            state.generation += 1
            state.activeDeviceUniqueID = nil
            defer { state.run = nil }
            return (state.run, state.lastQueue)
        }
        run?.resource.end()
        return lastQueue
    }

    /// Whether `id` is still the latest `start`: no `start` or `stop` came after it.
    func isLatest(_ id: Int) -> Bool {
        state.withLock { $0.generation == id }
    }

    /// Makes run `id` the active one, delivering to `sink` on `queue`. `false` if a later `start` or `stop` came:
    /// the caller then ends `resource` itself and throws `CancellationError`.
    func install(id: Int, resource: Resource, queue: DispatchSerialQueue, sink: any CaptureSink) -> Bool {
        state.withLock { state in
            guard state.generation == id else { return false }
            state.run = Run(id: id, resource: resource, queue: queue, sink: sink)
            state.lastQueue = queue
            return true
        }
    }

    /// The last step of `start`. A failure the run got meanwhile comes first, then `failure`, the start's own (the
    /// capture did not start): either makes the run inactive, and the caller ends its resource and throws it.
    /// Otherwise the run has started and `deviceUniqueID` is the active device.
    func finishStart(id: Int, deviceUniqueID: String?, failure: (any Error)?) -> StartOutcome {
        state.withLock { state in
            guard var run = state.run, run.id == id else { return .overtaken }
            if let failure = run.failure ?? failure {
                state.run = nil
                return .failed(failure)
            }
            run.started = true
            state.run = run
            state.activeDeviceUniqueID = deviceUniqueID
            return .started
        }
    }

    // MARK: - The active run

    /// Whether run `id` is the active one, failed or not.
    func isActive(_ id: Int) -> Bool {
        state.withLock { $0.run?.id == id }
    }

    /// The active run, unless it failed or `matching` rejects its resource: where a delivery goes.
    func activeRun(matching: (Resource) -> Bool = { _ in true }) -> ActiveRun? {
        state.withLock { state in
            state.run.flatMap { $0.failure == nil && matching($0.resource) ? $0.active : nil }
        }
    }

    /// Where run `id` delivers, while it is the active run and has not failed. Unlike `activeRun`, it hands out no
    /// reference to the resource, so the caller never ends up holding its last one.
    func delivery(forRun id: Int) -> (queue: DispatchSerialQueue, sink: any CaptureSink)? {
        state.withLock { state in
            state.run.flatMap { $0.id == id && $0.failure == nil ? ($0.queue, $0.sink) : nil }
        }
    }

    // MARK: - Failures

    /// From any thread: handled on run `runID`'s queue, after the deliveries already queued there.
    func fail(runID: Int, error: any Error) {
        let queue = state.withLock { $0.run?.id == runID ? $0.run?.queue : nil }
        queue?.async { [self] in failOnQueue(runID: runID, error: error) }
    }

    /// On run `runID`'s queue. Before `start` has succeeded the error is kept for `start` to throw; afterwards the
    /// run ends: its resource first, then the error is its last delivery. Only the first failure counts.
    func failOnQueue(runID: Int, error: any Error) {
        let ended = state.withLock { state -> Run? in
            guard var run = state.run, run.id == runID, run.failure == nil else { return nil }
            guard run.started else {
                run.failure = error
                state.run = run
                return nil
            }
            state.run = nil
            return run
        }
        guard let ended else { return }
        ended.resource.end()
        ended.sink.source(trackID, didStopWithError: error)
    }
}
