// SPDX-License-Identifier: GPL-3.0-or-later
import AudioToolbox
import CoreMedia
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing

@testable import Recording

/// The run life cycle the microphone, the camera and the system audio tap share, with a resource that only counts
/// how often it was ended.
@Suite struct CaptureRunLifecycleTests {
    private final class Resource: CaptureRunResource {
        private let ends = Atomic(0)
        var endCount: Int { ends.load(ordering: .relaxed) }
        func end() { ends.add(1, ordering: .relaxed) }
    }

    private struct Failure: Error, Equatable {
        let code: Int
    }

    private let queue = DispatchSerialQueue(label: "test.lifecycle")

    /// Delivers one sample of run `id` the way a source does: on the run's queue, while it is the active run.
    private func deliver(_ runs: CaptureRunLifecycle<Resource>, run id: Int) throws {
        let sample = try multichannelAudio(
            pts: .now(), startFrame: 0, frames: 480, sampleRate: 48_000, channels: 1, layout: kAudioChannelLayoutTag_Mono)
        nonisolated(unsafe) let unsafeSample = sample
        queue.async {
            guard let run = runs.activeRun(), run.id == id else { return }
            run.sink.source("track", didOutput: unsafeSample)
        }
    }

    /// Installs and starts a run delivering to `sink`.
    private func startedRun(_ runs: CaptureRunLifecycle<Resource>, sink: RecordingSink, device: String? = "device") -> (Int, Resource) {
        let resource = Resource()
        let (id, _) = runs.beginStart()
        #expect(runs.install(id: id, resource: resource, queue: queue, sink: sink))
        guard case .started = runs.finishStart(id: id, deviceUniqueID: device, failure: nil) else {
            Issue.record("the run did not start")
            return (id, resource)
        }
        return (id, resource)
    }

    @Test func overtakenStartGivesUp() {
        let runs = CaptureRunLifecycle<Resource>(trackID: "track")
        let sink = RecordingSink(queue: queue)
        // A stop before the run is installed: it cannot be installed.
        let (first, _) = runs.beginStart()
        _ = runs.stop()
        #expect(!runs.isLatest(first))
        #expect(!runs.install(id: first, resource: Resource(), queue: queue, sink: sink))

        // A later start after it was installed: it ends the run, and the first start finds it gone.
        let resource = Resource()
        let (second, _) = runs.beginStart()
        #expect(runs.install(id: second, resource: resource, queue: queue, sink: sink))
        let (third, lastQueue) = runs.beginStart()
        #expect(third == second + 1 && lastQueue === queue)
        #expect(resource.endCount == 1)
        guard case .overtaken = runs.finishStart(id: second, deviceUniqueID: "device", failure: nil) else {
            Issue.record("expected the start to be overtaken")
            return
        }
        #expect(runs.activeDeviceUniqueID == nil && runs.activeRun() == nil)
    }

    @Test func failureBeforeStartedIsKeptAndThrownByStart() async {
        let runs = CaptureRunLifecycle<Resource>(trackID: "track")
        let sink = RecordingSink(queue: queue)
        let resource = Resource()
        let (id, _) = runs.beginStart()
        #expect(runs.install(id: id, resource: resource, queue: queue, sink: sink))
        runs.fail(runID: id, error: Failure(code: 1))
        runs.fail(runID: id, error: Failure(code: 2))
        await queue.drain()
        // Kept, not delivered; a failed run delivers nothing more.
        #expect(sink.failures.isEmpty && runs.activeRun() == nil && runs.delivery(forRun: id) == nil)
        #expect(runs.isActive(id))

        // It comes before the start's own failure, and only the first one counts.
        guard case .failed(let error) = runs.finishStart(id: id, deviceUniqueID: "device", failure: Failure(code: 3)) else {
            Issue.record("expected the start to fail")
            return
        }
        #expect(error as? Failure == Failure(code: 1))
        // The caller ends the resource, not the life cycle; the run is gone.
        #expect(resource.endCount == 0 && !runs.isActive(id) && runs.activeDeviceUniqueID == nil)
    }

    @Test func startsOwnFailureFailsTheStart() {
        let runs = CaptureRunLifecycle<Resource>(trackID: "track")
        let (id, _) = runs.beginStart()
        #expect(runs.install(id: id, resource: Resource(), queue: queue, sink: RecordingSink(queue: queue)))
        guard case .failed(let error) = runs.finishStart(id: id, deviceUniqueID: "device", failure: Failure(code: 7)) else {
            Issue.record("expected the start to fail")
            return
        }
        #expect(error as? Failure == Failure(code: 7) && !runs.isActive(id))
    }

    @Test func failureAfterStartedIsTheLastDeliveryOnce() async throws {
        let runs = CaptureRunLifecycle<Resource>(trackID: "track")
        let sink = RecordingSink(queue: queue)
        let (id, resource) = startedRun(runs, sink: sink)
        #expect(runs.activeDeviceUniqueID == "device")
        try deliver(runs, run: id)
        try deliver(runs, run: id)
        // From other threads, twice: one error, after the samples already queued, and nothing after it.
        await withTaskGroup(of: Void.self) { group in
            for code in 1...2 {
                group.addTask { runs.fail(runID: id, error: Failure(code: code)) }
            }
        }
        try deliver(runs, run: id)
        await queue.drain()

        #expect(sink.samples.count == 2)
        #expect(sink.failures.count == 1)
        #expect(sink.failures.first?.samplesBefore == 2 && sink.failures.first?.trackID == "track")
        #expect(resource.endCount == 1)
        #expect(runs.activeRun() == nil && !runs.isActive(id))
        // The device stays until `stop`.
        #expect(runs.activeDeviceUniqueID == "device")
        // A failure of a run that ended does nothing.
        runs.failOnQueue(runID: id, error: Failure(code: 3))
        await queue.drain()
        #expect(sink.failures.count == 1 && resource.endCount == 1)
    }

    @Test func activeRunMatchesItsResource() {
        let runs = CaptureRunLifecycle<Resource>(trackID: "track")
        let (id, resource) = startedRun(runs, sink: RecordingSink(queue: queue))
        #expect(runs.activeRun(matching: { $0 === resource })?.id == id)
        #expect(runs.activeRun(matching: { $0 !== resource }) == nil)
        #expect(runs.delivery(forRun: id)?.queue === queue && runs.delivery(forRun: id + 1) == nil)
    }

    @Test func stopEndsTheRunAndDrainsInOrder() async throws {
        let runs = CaptureRunLifecycle<Resource>(trackID: "track")
        let sink = RecordingSink(queue: queue)
        let (id, resource) = startedRun(runs, sink: sink)
        // A delivery already queued behind a busy queue when `stop` comes.
        let busy = DispatchSemaphore(value: 0)
        queue.async { busy.wait() }
        try deliver(runs, run: id)
        let lastQueue = runs.stop()
        #expect(lastQueue === queue)
        #expect(resource.endCount == 1 && runs.activeDeviceUniqueID == nil && !runs.isLatest(id))
        busy.signal()
        await lastQueue?.drain()
        // Nothing arrives once the queue is drained: the delivery found no run.
        #expect(sink.samples.isEmpty && sink.failures.isEmpty)
        // A failure after the stop does nothing, and a second stop ends nothing more.
        runs.fail(runID: id, error: Failure(code: 1))
        _ = runs.stop()
        await queue.drain()
        #expect(sink.failures.isEmpty && resource.endCount == 1)
        // The next start begins with the stopped run's queue to drain.
        #expect(runs.beginStart().lastQueue === queue)
    }
}
