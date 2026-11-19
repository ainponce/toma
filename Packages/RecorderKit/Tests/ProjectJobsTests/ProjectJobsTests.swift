// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing
// @testable only for `ProjectJobs.waiters(of:)` and `isRunning`, which let a test wait until a caller is waiting or a
// run has returned: the rest is the public API the editor and the export use.
@testable import ProjectJobs

// Every test here runs in `make tsan`.

/// Where a job's work waits until the test opens it; a wait whose task is cancelled ends at once with
/// `CancellationError`, as Speech, Vision and an Audio Unit stop when their task is.
private final class Gate: Sendable {
    private struct State {
        var open = false
        var next = 0
        var arrivals = 0
        var waiting: [Int: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex(State())

    func wait() async throws {
        let id = state.withLock { state in
            state.next += 1
            state.arrivals += 1
            return state.next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let open = state.withLock { state in
                    if !state.open { state.waiting[id] = continuation }
                    return state.open
                }
                if open { return continuation.resume() }
                // Cancelled before it was waiting: the handler found nothing to end.
                if Task.isCancelled { end(id) }
            }
        } onCancel: {
            end(id)
        }
    }

    /// The waits so far, ended or not.
    var arrivals: Int { state.withLock { $0.arrivals } }

    /// The waits end, and later ones end at once.
    func open() {
        let waiting = state.withLock { state in
            state.open = true
            defer { state.waiting = [:] }
            return Array(state.waiting.values)
        }
        for continuation in waiting { continuation.resume() }
    }

    private func end(_ id: Int) {
        state.withLock { $0.waiting.removeValue(forKey: id) }?.resume(throwing: CancellationError())
    }
}

/// What the works did, in order.
private final class Log: Sendable {
    private let entries = Mutex<[String]>([])

    func append(_ entry: String) { entries.withLock { $0.append(entry) } }
    var all: [String] { entries.withLock { $0 } }
}

/// How many works run at once, and the most there were.
private final class Overlap: Sendable {
    private let counts = Mutex((now: 0, most: 0))

    func enter() {
        counts.withLock { counts in
            counts.now += 1
            counts.most = max(counts.most, counts.now)
        }
    }

    func leave() { counts.withLock { $0.now -= 1 } }
    var most: Int { counts.withLock { $0.most } }
}

private final class Counter: Sendable {
    private let value = Mutex(0)

    @discardableResult
    func increment() -> Int { value.withLock { $0 += 1; return $0 } }
    var count: Int { value.withLock { $0 } }
}

private struct SomeFailure: Error {}

private let take = "take-001"
private let mask = AnalysisJobKind.personMask(take: take, track: "camera", segment: 1)
private let faces = AnalysisJobKind.faceTrack(take: take, track: "camera", segment: 1)
private let speech = AnalysisJobKind.transcription(take: take, track: "mic-1")
private let loudness = AnalysisJobKind.loudness(take: take, track: "mic-1")
private let clean = AnalysisJobKind.soundIsolation(take: take, track: "mic-1", segment: 1)
private let scan = AnalysisJobKind.sensitiveScan(take: take)
private let output = URL(filePath: "/caches/masks/take-001/camera/seg-0001-10-20-personMask-1.mov")

/// Long enough for a loaded machine under the thread sanitizer: `eventually` returns as soon as it holds.
private let patience = Duration.seconds(60)

@Test func runsOneJobAtATime() async throws {
    let jobs = ProjectJobs()
    let overlap = Overlap()
    let kinds = [mask, speech, scan]
    let gates = kinds.map { _ in Gate() }
    for (kind, gate) in zip(kinds, gates) {
        await jobs.enqueue(kind) { _ in
            overlap.enter()
            defer { overlap.leave() }
            try await gate.wait()
            return .cached(output)
        }
    }
    #expect(await jobs.state(of: mask) == .running(progress: 0))
    #expect(await jobs.state(of: speech) == .waiting)
    #expect(await jobs.state(of: scan) == .waiting)

    // The later ones may go on at once, but never start while the first runs.
    gates[2].open()
    gates[1].open()
    #expect(await eventually(timeout: patience) { gates[0].arrivals == 1 })
    #expect(gates[1].arrivals == 0 && gates[2].arrivals == 0)
    gates[0].open()

    #expect(await eventually(timeout: patience) { await jobs.state(of: scan) == .done })
    for kind in kinds { #expect(await jobs.state(of: kind) == .done) }
    #expect(overlap.most == 1)
}

@Test func runsAtUtilityPriority() async throws {
    let jobs = ProjectJobs()
    let priority = Mutex<TaskPriority?>(nil)
    let result = try await jobs.result(of: loudness) { _ in
        priority.withLock { $0 = Task.currentPriority }
        return .cached(output)
    }
    #expect(result == .cached(output))
    #expect(priority.withLock { $0 } == .utility)
}

@Test func sameKindIsOneJob() async throws {
    let jobs = ProjectJobs()
    let gate = Gate()
    let calls = Counter()
    let work: JobWork = { _ in
        calls.increment()
        try await gate.wait()
        return .cached(output)
    }

    #expect(await jobs.enqueue(mask, work: work) == .running(progress: 0))
    #expect(await jobs.enqueue(mask, work: work) == .running(progress: 0))
    async let first = jobs.result(of: mask, work: work)
    async let second = jobs.result(of: mask, work: work)
    #expect(await eventually(timeout: patience) { await jobs.waiters(of: mask) == 2 })
    gate.open()

    #expect(try await first == .cached(output))
    #expect(try await second == .cached(output))
    #expect(calls.count == 1)
    #expect(await jobs.state(of: mask) == .done)
}

@Test func exportGoesToTheFrontOfTheQueue() async throws {
    let jobs = ProjectJobs()
    let gate = Gate()
    let log = Log()
    func work(_ name: String) -> JobWork {
        { _ in
            log.append(name)
            if name == "A" { try await gate.wait() }
            return .cached(output)
        }
    }

    await jobs.enqueue(mask, work: work("A"))
    await jobs.enqueue(speech, work: work("B"))
    await jobs.enqueue(scan, work: work("D"))
    // C is new and goes first; D is waiting and goes first too, ahead of C.
    async let c = jobs.result(of: loudness, work: work("C"))
    #expect(await eventually(timeout: patience) { await jobs.waiters(of: loudness) == 1 })
    async let d = jobs.result(of: scan, work: work("D, again"))
    #expect(await eventually(timeout: patience) { await jobs.waiters(of: scan) == 1 })
    #expect(await jobs.state(of: loudness) == .waiting)
    #expect(await jobs.state(of: scan) == .waiting)
    gate.open()

    #expect(try await c == .cached(output))
    #expect(try await d == .cached(output))
    #expect(await eventually(timeout: patience) { await jobs.state(of: speech) == .done })
    #expect(log.all == ["A", "D", "C", "B"])
}

@Test func cancellingAWaitingJobNeverRunsIt() async throws {
    let jobs = ProjectJobs()
    let gate = Gate()
    let log = Log()
    await jobs.enqueue(mask) { _ in
        log.append("A")
        try await gate.wait()
        return .cached(output)
    }
    let b: JobWork = { _ in
        log.append("B")
        return .cached(output)
    }
    await jobs.enqueue(speech, work: b)
    await jobs.enqueue(scan) { _ in
        log.append("C")
        return .cached(output)
    }
    let waiter = Task { try await jobs.result(of: speech, work: b) }
    #expect(await eventually(timeout: patience) { await jobs.waiters(of: speech) == 1 })

    await jobs.cancel(speech)
    #expect(await jobs.state(of: speech) == nil)
    await #expect(throws: CancellationError.self) { try await waiter.value }
    gate.open()

    #expect(await eventually(timeout: patience) { await jobs.state(of: scan) == .done })
    #expect(await jobs.state(of: mask) == .done)
    #expect(await jobs.state(of: speech) == nil)
    #expect(log.all == ["A", "C"])
}

@Test func cancellingTheRunningJobStopsIt() async throws {
    let jobs = ProjectJobs()
    let gate = Gate()
    let log = Log()
    let a: JobWork = { _ in
        log.append("A")
        do {
            try await gate.wait()
        } catch {
            log.append(Task.isCancelled ? "A saw the cancel" : "A failed")
            throw error
        }
        return .cached(output)
    }
    await jobs.enqueue(mask, work: a)
    await jobs.enqueue(speech) { _ in
        log.append("B")
        return .cached(output)
    }
    let waiter = Task { try await jobs.result(of: mask, work: a) }
    #expect(await eventually(timeout: patience) { await jobs.waiters(of: mask) == 1 && gate.arrivals == 1 })

    await jobs.cancel(mask)
    #expect(await jobs.state(of: mask) == nil)
    await #expect(throws: CancellationError.self) { try await waiter.value }

    // The next one starts once the cancelled work has returned, never beside it.
    #expect(await eventually(timeout: patience) { await jobs.state(of: speech) == .done })
    #expect(await jobs.state(of: mask) == nil)
    #expect(log.all == ["A", "A saw the cancel", "B"])
}

@Test func cancelAllStopsEverything() async throws {
    let jobs = ProjectJobs()
    let gate = Gate()
    let log = Log()
    await jobs.enqueue(mask) { _ in
        log.append("A")
        try await gate.wait()
        return .cached(output)
    }
    await jobs.enqueue(speech) { _ in
        log.append("B")
        return .cached(output)
    }
    #expect(await eventually(timeout: patience) { gate.arrivals == 1 })

    await jobs.cancelAll()
    #expect(await jobs.state(of: mask) == nil)
    #expect(await jobs.state(of: speech) == nil)
    #expect(await eventually(timeout: patience) { await !jobs.isRunning })
    #expect(log.all == ["A"])

    // Asked again, it runs again.
    #expect(try await jobs.result(of: speech) { _ in .cached(output) } == .cached(output))
}

@Test func recordingPausesAndResumes() async throws {
    let jobs = ProjectJobs()
    let firstRun = Gate()
    let secondRun = Gate()
    let calls = Counter()
    let log = Log()
    let a: JobWork = { _ in
        let call = calls.increment()
        log.append("A\(call)")
        do {
            try await (call == 1 ? firstRun : secondRun).wait()
        } catch {
            log.append("A\(call) stopped")
            throw error
        }
        return .cached(output)
    }
    await jobs.enqueue(mask, work: a)
    await jobs.enqueue(speech) { _ in
        log.append("B")
        return .cached(output)
    }
    let waiter = Task { try await jobs.result(of: mask, work: a) }
    #expect(await eventually(timeout: patience) { await jobs.waiters(of: mask) == 1 && firstRun.arrivals == 1 })

    // A take starts: A is stopped and waits first again; nothing starts while it records.
    await jobs.setRecording(true)
    #expect(await jobs.state(of: mask) == .waiting)
    #expect(await jobs.state(of: speech) == .waiting)
    #expect(await eventually(timeout: patience) { await !jobs.isRunning })
    #expect(await jobs.enqueue(scan) { _ in .cached(output) } == .waiting)
    #expect(await jobs.state(of: mask) == .waiting)
    #expect(await jobs.state(of: speech) == .waiting)
    #expect(log.all == ["A1", "A1 stopped"])
    #expect(await jobs.waiters(of: mask) == 1)

    // It ends: A runs again from the start, to the end, and then B.
    await jobs.setRecording(false)
    #expect(await eventually(timeout: patience) { secondRun.arrivals == 1 })
    #expect(await jobs.state(of: mask) == .running(progress: 0))
    secondRun.open()
    #expect(try await waiter.value == .cached(output))
    #expect(await eventually(timeout: patience) { await jobs.state(of: scan) == .done })
    #expect(await jobs.state(of: mask) == .done)
    #expect(await jobs.state(of: speech) == .done)
    #expect(calls.count == 2)
    #expect(log.all == ["A1", "A1 stopped", "A2", "B"])
}

@Test func failuresKeepTheirReason() async throws {
    let jobs = ProjectJobs()
    await #expect(throws: JobError(.sourceUnreadable(file: "x"))) {
        try await jobs.result(of: mask) { _ in throw JobError(.sourceUnreadable(file: "x")) }
    }
    #expect(await jobs.state(of: mask) == .failed(.sourceUnreadable(file: "x")))

    await #expect(throws: JobError(.needsMacOS26, unavailable: true)) {
        try await jobs.result(of: speech) { _ in throw JobError(.needsMacOS26, unavailable: true) }
    }
    #expect(await jobs.state(of: speech) == .unavailable(.needsMacOS26))

    let described = String(describing: SomeFailure())
    await #expect(throws: JobError(.failed(described))) {
        try await jobs.result(of: clean) { _ in throw SomeFailure() }
    }
    #expect(await jobs.state(of: clean) == .failed(.failed(described)))

    // Asked again, a failed job runs again (and its work finds its cache), as does one that is done.
    let calls = Counter()
    let again: JobWork = { _ in
        calls.increment()
        return .cached(output)
    }
    #expect(try await jobs.result(of: mask, work: again) == .cached(output))
    #expect(await jobs.state(of: mask) == .done)
    await jobs.enqueue(mask, work: again)
    #expect(await eventually(timeout: patience) { calls.count == 2 })
    #expect(await eventually(timeout: patience) { await jobs.state(of: mask) == .done })
    // Cancelling one that is over leaves its state.
    await jobs.cancel(speech)
    #expect(await jobs.state(of: speech) == .unavailable(.needsMacOS26))
}

@Test func progressIsClampedAndOnlyGoesUp() async throws {
    let jobs = ProjectJobs()
    let seen = Mutex<[Double]>([])
    let updates = await jobs.updates()
    let reader = Task {
        for await states in updates {
            if case .running(let progress)? = states[faces] { seen.withLock { $0.append(progress) } }
            if states[faces] == .done { return }
        }
    }
    func seenLast(_ progress: Double) -> Bool { seen.withLock { $0.last } == progress }

    let firstHalf = Gate()
    let secondHalf = Gate()
    await jobs.enqueue(faces) { progress in
        progress.report(0.4)
        try await firstHalf.wait()
        progress.report(0.2)
        progress.report(0.405)
        progress.report(-1)
        progress.report(.nan)
        progress.report(1.7)
        try await secondHalf.wait()
        return .cached(output)
    }
    #expect(await eventually(timeout: patience) { seenLast(0.4) })
    #expect(await jobs.state(of: faces) == .running(progress: 0.4))
    firstHalf.open()
    #expect(await eventually(timeout: patience) { seenLast(1.0) })
    #expect(await jobs.state(of: faces) == .running(progress: 1.0))
    secondHalf.open()
    await reader.value

    let progresses = seen.withLock { $0 }
    #expect(progresses.allSatisfy { [0, 0.4, 1.0].contains($0) })
    #expect(zip(progresses, progresses.dropFirst()).allSatisfy { $0 < $1 })
    #expect(await jobs.state(of: faces) == .done)
}

@Test func updatesStartWithTheStatesNow() async throws {
    let jobs = ProjectJobs()
    let gate = Gate()
    await jobs.enqueue(mask) { _ in
        try await gate.wait()
        return .cached(output)
    }
    await jobs.enqueue(speech) { _ in .cached(output) }
    let now = await RecorderKitTestSupport.first(of: jobs.updates(), within: patience)
    #expect(now == [mask: .running(progress: 0), speech: .waiting])
    gate.open()
    #expect(await eventually(timeout: patience) { await jobs.state(of: speech) == .done })
}

@Test func aCancelledWaiterLeavesTheJobRunning() async throws {
    let jobs = ProjectJobs()
    let gate = Gate()
    let calls = Counter()
    let work: JobWork = { _ in
        calls.increment()
        try await gate.wait()
        return .cached(output)
    }
    let waiter = Task { try await jobs.result(of: mask, work: work) }
    #expect(await eventually(timeout: patience) { await jobs.waiters(of: mask) == 1 })

    waiter.cancel()
    await #expect(throws: CancellationError.self) { try await waiter.value }
    #expect(await jobs.waiters(of: mask) == 0)
    #expect(await jobs.state(of: mask) == .running(progress: 0))
    gate.open()

    #expect(await eventually(timeout: patience) { await jobs.state(of: mask) == .done })
    #expect(calls.count == 1)
}
