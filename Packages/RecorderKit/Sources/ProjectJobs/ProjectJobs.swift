// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The analysis queue of a project open in the editor (design of phase 2, §10; plan decision 16): one actor per
/// project, which runs its jobs one at a time, each on a detached task at utility priority, with progress, cancelling
/// and a state for each (waiting, running, done, failed or unavailable, with the reason).
///
/// - **In order.** Jobs wait first in, first out; `result(of:work:)`, which the export calls for what it lacks, puts its
///   job first instead. One kind is one job: asking for a kind that waits or runs adds nothing (the `work` given later is
///   not used) and waits for the same one. Asking for one that is over (done, failed or unavailable) runs it again: its
///   work finds its cache.
/// - **One at a time.** The next job starts only once the work before it has returned, even a work that was cancelled
///   and takes a moment to stop: never two works at once.
/// - **Cancelling.** `cancel(_:)` takes a waiting job out of the queue, or cancels the task of the running one; its state
///   is gone at once and its callers get `CancellationError`. A caller of `result(of:work:)` whose own task is cancelled
///   gets `CancellationError` and leaves the job as it was.
/// - **Recording.** While a take records (`setRecording(true)`) nothing starts, and the job running is cancelled and
///   waits first again, its callers still waiting: Speech, Vision and an Audio Unit cannot be paused, so it starts again
///   from the beginning once the take ends, and finds in its cache what it had finished (at most one segment is done
///   twice).
/// - **States.** `state(of:)` and `updates()`: a job that is over keeps its last state until it is asked for again.
///   Progress is published as `JobProgress` says.
public actor ProjectJobs {
    private struct Job {
        let id: Int
        let work: JobWork
        /// The run doing it now; `nil` while it waits.
        var run: Int?
        /// The callers of `result(of:work:)` waiting for it, by an id of each.
        var waiters: [Int: CheckedContinuation<JobOutput, any Error>] = [:]
    }

    /// The work that has the queue's one place: until it returns, even once its job was cancelled or sent back to wait.
    private struct Run {
        let id: Int
        let kind: AnalysisJobKind
        let task: Task<Void, Never>
    }

    /// The jobs waiting or running.
    private var jobs: [AnalysisJobKind: Job] = [:]
    /// The jobs waiting, first to start first.
    private var queue: [AnalysisJobKind] = []
    private var states: [AnalysisJobKind: JobState] = [:]
    private var active: Run?
    private var recording = false
    private var lastID = 0
    private var subscribers: [Int: AsyncStream<[AnalysisJobKind: JobState]>.Continuation] = [:]
    private var published: [AnalysisJobKind: JobState] = [:]

    public init() {}

    deinit {
        active?.task.cancel()
        for subscriber in subscribers.values { subscriber.finish() }
    }

    /// Adds a job of `kind` at the end of the queue, unless one waits or runs; its state now.
    @discardableResult
    public func enqueue(_ kind: AnalysisJobKind, work: @escaping JobWork) -> JobState {
        request(kind, work: work, first: false)
        return states[kind] ?? .waiting
    }

    /// What the job of `kind` makes, once it is done; first in the queue if it is not running. Throws its `JobError`
    /// if it failed or is unavailable, and `CancellationError` if it is cancelled or the caller's task is (which leaves
    /// the job in the queue).
    public func result(of kind: AnalysisJobKind, work: @escaping JobWork) async throws -> JobOutput {
        let job = request(kind, work: work, first: true)
        let waiter = makeID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Still on the actor since `request`, without a suspension: the job cannot have ended.
                guard jobs[kind]?.id == job else { return continuation.resume(throwing: CancellationError()) }
                jobs[kind]?.waiters[waiter] = continuation
            }
        } onCancel: {
            Task { await self.leave(kind, job: job, waiter: waiter) }
        }
    }

    /// The state of the job of `kind`; `nil` if it was never asked for or was cancelled.
    public func state(of kind: AnalysisJobKind) -> JobState? {
        states[kind]
    }

    /// Takes the job of `kind` out of the queue, or cancels its work if it runs: its state is gone, its callers get
    /// `CancellationError`. A job that is over keeps its state.
    public func cancel(_ kind: AnalysisJobKind) {
        guard let job = jobs.removeValue(forKey: kind) else { return }
        queue.removeAll { $0 == kind }
        states[kind] = nil
        if let run = job.run, let active, active.id == run { active.task.cancel() }
        for waiter in job.waiters.values { waiter.resume(throwing: CancellationError()) }
        publish()
    }

    /// `cancel(_:)` for every job waiting or running: what the editor does as it closes.
    public func cancelAll() {
        for kind in Array(jobs.keys) { cancel(kind) }
    }

    /// Whether a take is recording: while it does, nothing starts, and the job running is cancelled and waits first.
    public func setRecording(_ recording: Bool) {
        guard recording != self.recording else { return }
        self.recording = recording
        if recording {
            guard let active, var job = jobs[active.kind], job.run == active.id else { return }
            job.run = nil
            jobs[active.kind] = job
            queue.insert(active.kind, at: 0)
            states[active.kind] = .waiting
            active.task.cancel()
        } else {
            startNext()
        }
        publish()
    }

    /// The states of every job, now and after each change; a slow reader gets the latest (`bufferingNewest(1)`).
    public func updates() -> AsyncStream<[AnalysisJobKind: JobState]> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [AnalysisJobKind: JobState].self, bufferingPolicy: .bufferingNewest(1))
        let id = makeID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        continuation.yield(states)
        return stream
    }

    // MARK: - For tests

    /// The callers of `result(of:work:)` waiting for the job of `kind`.
    func waiters(of kind: AnalysisJobKind) -> Int {
        jobs[kind]?.waiters.count ?? 0
    }

    /// Whether a work has the queue's place, even one that was cancelled and has not returned yet.
    var isRunning: Bool { active != nil }

    // MARK: - Private

    /// The job of `kind`, made (waiting at the end of the queue, or first) unless one waits or runs, which `first`
    /// moves to the front if it waits; its id.
    @discardableResult
    private func request(_ kind: AnalysisJobKind, work: @escaping JobWork, first: Bool) -> Int {
        if let job = jobs[kind] {
            if first, job.run == nil, let index = queue.firstIndex(of: kind), index > 0 {
                queue.remove(at: index)
                queue.insert(kind, at: 0)
            }
            return job.id
        }
        let job = Job(id: makeID(), work: work)
        jobs[kind] = job
        states[kind] = .waiting
        if first { queue.insert(kind, at: 0) } else { queue.append(kind) }
        startNext()
        publish()
        return job.id
    }

    /// Starts the first job waiting, unless a work has the place or a take records.
    private func startNext() {
        guard active == nil, !recording, !queue.isEmpty else { return }
        let kind = queue.removeFirst()
        guard var job = jobs[kind] else { return startNext() }
        let run = makeID()
        let (progress, reports) = AsyncStream.makeStream(of: Double.self)
        let reporter = ProgressReporter(reports)
        let work = job.work
        job.run = run
        jobs[kind] = job
        states[kind] = .running(progress: 0)
        let task = Task.detached(priority: .utility) { [weak self] in
            let outcome: Result<JobOutput, any Error>
            do {
                outcome = .success(try await work(JobProgress(reporter: reporter)))
            } catch {
                outcome = .failure(error)
            }
            reporter.finish()
            await self?.ended(run, outcome)
        }
        active = Run(id: run, kind: kind, task: task)
        // One reader per run, so its progress arrives in the order it was published.
        Task.detached(priority: .utility) { [weak self] in
            for await fraction in progress { await self?.progressed(run, kind, fraction) }
        }
    }

    private func progressed(_ run: Int, _ kind: AnalysisJobKind, _ fraction: Double) {
        guard jobs[kind]?.run == run else { return }
        states[kind] = .running(progress: fraction)
        publish()
    }

    /// The work of `run` returned: its outcome is its job's if the job is still that run's (not cancelled or sent back
    /// to wait), and the next job starts.
    private func ended(_ run: Int, _ outcome: Result<JobOutput, any Error>) {
        guard let active, active.id == run else { return }
        self.active = nil
        let kind = active.kind
        if let job = jobs[kind], job.run == run {
            jobs[kind] = nil
            let result: Result<JobOutput, JobError>
            switch outcome {
            case .success(let output):
                result = .success(output)
                states[kind] = .done
            case .failure(let error as JobError):
                result = .failure(error)
                states[kind] = error.unavailable ? .unavailable(error.problem) : .failed(error.problem)
            case .failure(let error):
                let problem = JobProblem.failed(String(describing: error))
                result = .failure(JobError(problem))
                states[kind] = .failed(problem)
            }
            for waiter in job.waiters.values { waiter.resume(with: result) }
        }
        startNext()
        publish()
    }

    /// A caller of `result(of:work:)` was cancelled: it gets `CancellationError`, and the job goes on.
    private func leave(_ kind: AnalysisJobKind, job: Int, waiter: Int) {
        guard jobs[kind]?.id == job, let continuation = jobs[kind]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func unsubscribe(_ id: Int) {
        subscribers[id] = nil
    }

    /// Sends the states to every reader of `updates()`, if they changed.
    private func publish() {
        guard states != published else { return }
        published = states
        for subscriber in subscribers.values { subscriber.yield(states) }
    }

    private func makeID() -> Int {
        lastID += 1
        return lastID
    }
}
