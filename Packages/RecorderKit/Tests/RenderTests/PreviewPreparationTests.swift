// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Synchronization
import Testing

@testable import Render

/// An actor on the default executor: its calls need a thread of the cooperative pool.
private actor Pinger {
    func ping() {}
}

@Suite(.enabled(if: metalAvailable)) struct PreviewPreparationTests {
    /// More previews prepared at once than the pool has threads: each blocks while it decodes, which on the
    /// pool would take every thread and hang the app.
    @Test func manyPreparationsAtOnceLeaveThePoolFree() async throws {
        try await withTemporaryDirectory { dir in
            let package = try makePackage(in: dir)
            let record = try await writeSegment(in: package, index: 1, start: base, seconds: 2)
            let frame = Rect(x: 0, y: 0, width: 640, height: 360)
            try ManifestStore(package: package).update {
                $0.takes.append(makeTake(tracks: [displayTrack(globalFrame: frame, segments: [record])]))
            }
            let count = ProcessInfo.processInfo.activeProcessorCount + 1
            let finished = Atomic(0)
            let clock = ContinuousClock()
            let started = clock.now
            let pinger = Pinger()

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<count {
                    group.addTask {
                        let prepared = try await PreviewPreparation.prepare(url: package.url, take: nil, outputSize: [320, 180])
                        #expect(abs(prepared.duration - 2) < 0.05)
                        finished.add(1, ordering: .relaxed)
                    }
                }
                group.addTask {
                    let pinged = clock.now
                    await pinger.ping()
                    #expect(clock.now - pinged < .seconds(1))
                    // Made while they run: one at a time, they take far longer than a ping.
                    #expect(finished.load(ordering: .relaxed) < count)
                }
                try await group.waitForAll()
            }
            #expect(finished.load(ordering: .relaxed) == count)
            #expect(clock.now - started < .seconds(30))
        }
    }

    @Test func unfinishedTakeIsNotPrepared() async throws {
        try await withTemporaryDirectory { dir in
            let package = try makePackage(in: dir)
            var take = makeTake(tracks: [displayTrack(globalFrame: nil, segments: [])])
            take.status = .recording
            try ManifestStore(package: package).update { [take] in $0.takes.append(take) }
            await #expect(throws: PreviewPreparationError.unfinished) {
                try await PreviewPreparation.prepare(url: package.url, take: nil, outputSize: [320, 180])
            }
        }
    }
}
