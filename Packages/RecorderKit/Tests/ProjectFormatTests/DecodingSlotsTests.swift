// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import Foundation
@testable import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing

/// How many bodies have started, and how many run at once at most.
private final class Bodies: Sendable {
    private let state = Mutex((started: 0, running: 0, most: 0))
    var started: Int { state.withLock { $0.started } }
    var most: Int { state.withLock { $0.most } }

    func enter() {
        state.withLock {
            $0.started += 1
            $0.running += 1
            $0.most = max($0.most, $0.running)
        }
    }

    func leave() { state.withLock { $0.running -= 1 } }
}

@Test func noMoreJobsRunAtOnceThanTheSlots() async throws {
    let slots = DecodingSlots(width: 3)
    let bodies = Bodies()
    let results = try await withThrowingTaskGroup(of: Int.self) { group in
        for k in 0..<24 {
            group.addTask {
                try await slots.run {
                    bodies.enter()
                    defer { bodies.leave() }
                    usleep(2_000)
                    return k
                }
            }
        }
        return try await group.reduce(into: Set<Int>()) { $0.insert($1) }
    }
    #expect(results == Set(0..<24))
    #expect(bodies.most <= 3)
}

@Test func aJobWaitsWithoutStartingUntilASlotIsFree() async throws {
    let slots = DecodingSlots(width: 2)
    let bodies = Bodies()
    let release = DispatchSemaphore(value: 0)
    let jobs = (0..<5).map { _ in
        Task {
            try await slots.run {
                bodies.enter()
                defer { bodies.leave() }
                _ = release.wait(timeout: .now() + 30)
            }
        }
    }
    #expect(await eventually { bodies.started == 2 && slots.waitingCount == 3 })
    try await Task.sleep(for: .milliseconds(100))
    #expect(bodies.started == 2, "a third job started while two held both slots")
    for _ in jobs { release.signal() }
    for job in jobs { try await job.value }
    #expect(bodies.started == 5 && bodies.most == 2)
}

@Test func aJobCancelledWhileItWaitsLeavesWithoutRunning() async throws {
    let slots = DecodingSlots(width: 1)
    let holding = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let holder = Task {
        try await slots.run {
            holding.signal()
            _ = release.wait(timeout: .now() + 30)
        }
    }
    #expect(try await offThePool { holding.wait(timeout: .now() + 30) == .success })
    let bodies = Bodies()
    let waiter = Task { try await slots.run { bodies.enter() } }
    #expect(await eventually { slots.waitingCount == 1 })
    waiter.cancel()
    await #expect(throws: CancellationError.self) { try await waiter.value }
    #expect(slots.waitingCount == 0)
    release.signal()
    try await holder.value
    #expect(bodies.started == 0)
    // The slot came back: the next job runs at once.
    #expect(try await slots.run { 7 } == 7)
}

@Test func aCancelledJobThatFindsASlotFreeRuns() async throws {
    let slots = DecodingSlots(width: 1)
    let ran = try await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await slots.run { true }
    }.value
    #expect(ran, "its body sees the cancellation in its own way")
}

@Test func aJobThatThrowsFreesItsSlot() async throws {
    struct Failure: Error {}
    let slots = DecodingSlots(width: 1)
    await #expect(throws: Failure.self) { try await slots.run { throw Failure() } }
    #expect(try await slots.run { 1 } == 1)
    let held: Int = try await slots.withSlot { 2 }
    #expect(held == 2 && slots.waitingCount == 0)
}
