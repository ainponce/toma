// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing

@testable import Render

/// An actor on the default executor: its calls need a thread of the cooperative pool.
private actor Pinger {
    func ping() {}
}

@Suite(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired)) struct PreviewPreparationTests {
    /// More previews prepared at once than the pool has threads: each blocks while it decodes, which on the
    /// pool would take every thread and hang the app. They all wait for the preparation queue, which this test holds
    /// until a ping (a call on an actor of the default executor, which needs a thread of the pool) came back: it comes
    /// back only if waiting for the queue holds no thread of the pool, and none of them can have finished by then.
    /// Nothing is timed: a watchdog lets the queue go after 60 s, so that a regression fails instead of hanging.
    @Test(.timeLimit(.minutes(10))) func manyPreparationsAtOnceLeaveThePoolFree() async throws {
        try await withTemporaryDirectory { dir in
            let builder = try TakeBuilder(in: dir)
            let frame = Rect(x: 0, y: 0, width: 640, height: 360)
            try await builder.addVideoTrack(
                id: trackID, source: displaySource(globalFrame: frame), segments: [VideoSegmentSpec(start: base, seconds: 2)])
            let package = try builder.write().package
            let count = ProcessInfo.processInfo.activeProcessorCount + 1
            let finished = Atomic(0)
            let pinger = Pinger()
            let queueHeld = DispatchSemaphore(value: 0)
            PreviewPreparation.queue.async { queueHeld.wait() }
            let watchdog = Watchdog(after: .seconds(60)) { queueHeld.signal() }

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<count {
                    group.addTask {
                        let prepared = try await PreviewPreparation.prepare(url: package.url, take: nil, outputSize: [320, 180])
                        #expect(abs(prepared.duration - 2) < 0.05)
                        finished.add(1, ordering: .relaxed)
                    }
                }
                group.addTask {
                    await pinger.ping()
                    #expect(finished.load(ordering: .relaxed) == 0, "a preparation finished while the queue was held")
                    queueHeld.signal()
                }
                try await group.waitForAll()
            }
            #expect(!watchdog.disarm(), "the ping waited for the preparations: waiting for the queue held the pool's threads")
            #expect(finished.load(ordering: .relaxed) == count)
        }
    }

    @Test func unfinishedTakeIsNotPrepared() async throws {
        try await withTemporaryDirectory { dir in
            let builder = try TakeBuilder(in: dir)
            try await builder.addVideoTrack(id: trackID, source: displaySource(globalFrame: nil), segments: [])
            let package = try builder.write(status: .recording).package
            await #expect(throws: PreviewPreparationError.unfinished(takeID: takeID)) {
                try await PreviewPreparation.prepare(url: package.url, take: nil, outputSize: [320, 180])
            }
        }
    }
}
