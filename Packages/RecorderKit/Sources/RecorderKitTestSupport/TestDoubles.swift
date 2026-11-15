// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import ProjectFormat
import Recording
import Synchronization

/// The free space a `DiskSpaceMonitor` sees, set by the test.
public final class FakeDisk: Sendable {
    private struct State {
        var capacity = DiskCapacity(importantUsage: 100_000_000_000, available: 100_000_000_000)
        var failing = false
        var lowQueryWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    public init() {}

    public func set(importantUsage: Int64, available: Int64) {
        state.withLock { $0.capacity = DiskCapacity(importantUsage: importantUsage, available: available) }
    }

    public func failQueries(_ failing: Bool) {
        state.withLock { $0.failing = failing }
    }

    /// Returns right after the monitor next reads less than 1 GB available.
    public func nextLowQuery() async {
        await withCheckedContinuation { continuation in
            state.withLock { $0.lowQueryWaiters.append(continuation) }
        }
    }

    public func monitor(volume: URL) -> DiskSpaceMonitor {
        DiskSpaceMonitor(volumeURL: volume, interval: .milliseconds(50)) { [self] _ in try query() }
    }

    private func query() throws -> DiskCapacity {
        let (capacity, failing, waiters) = state.withLock { state in
            let low = state.capacity.available < 1_000_000_000
            defer { if low { state.lowQueryWaiters = [] } }
            return (state.capacity, state.failing, low ? state.lowQueryWaiters : [])
        }
        defer { for waiter in waiters { waiter.resume() } }
        if failing { throw CocoaError(.fileReadUnknown) }
        return capacity
    }
}

/// The warnings a take gave, in order.
public final class WarningLog: Sendable {
    private let items = Mutex<[RecordingWarning]>([])

    public init() {}

    public var all: [RecordingWarning] { items.withLock { $0 } }

    public func append(_ warning: RecordingWarning) {
        items.withLock { $0.append(warning) }
    }
}

/// Records what a source delivers. Every call must arrive on `queue` (`dispatchPrecondition` traps
/// otherwise). The records live in a `Mutex` so they can be read from the test at any time.
public final class RecordingSink: CaptureSink {
    public struct Delivery: Sendable {
        public var trackID: String
        public var pts: HostTime
        public var frames: Int
        public var width: Int?
        public var height: Int?
        public var sampleRate: Double?
        public var channels: Int?
        public var isCompleteFrame: Bool
        /// Host time at delivery minus the sample's PTS, in seconds.
        public var lag: Double
    }

    public struct Failure: Sendable {
        public var trackID: String
        public var domain: String
        public var code: Int
        /// Samples delivered before the error.
        public var samplesBefore: Int
    }

    private struct Log {
        var samples: [Delivery] = []
        var failures: [Failure] = []
    }

    public let queue: DispatchSerialQueue
    private let log = Mutex(Log())

    public var samples: [Delivery] { log.withLock { $0.samples } }
    public var failures: [Failure] { log.withLock { $0.failures } }

    public init(queue: DispatchSerialQueue) {
        self.queue = queue
    }

    public func source(_ trackID: String, didOutput sample: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        let now = HostTime.now()
        let pts = HostTime(sample.presentationTimeStamp)
        let image = sample.imageBuffer
        let audio = sample.formatDescription?.audioStreamBasicDescription
        let delivery = Delivery(
            trackID: trackID,
            pts: pts,
            frames: sample.numSamples,
            width: image.map(CVPixelBufferGetWidth),
            height: image.map(CVPixelBufferGetHeight),
            sampleRate: audio?.mSampleRate,
            channels: audio.map { Int($0.mChannelsPerFrame) },
            isCompleteFrame: ScreenCapture.isCompleteFrame(sample),
            lag: now.seconds(since: pts)
        )
        log.withLock { $0.samples.append(delivery) }
    }

    public func source(_ trackID: String, didStopWithError error: any Error) {
        dispatchPrecondition(condition: .onQueue(queue))
        let error = error as NSError
        log.withLock { log in
            log.failures.append(
                Failure(trackID: trackID, domain: error.domain, code: error.code, samplesBefore: log.samples.count))
        }
    }
}

/// The first element of `stream`, or `nil` if none comes within `timeout`.
public func first<T: Sendable>(of stream: AsyncStream<T>, within timeout: Duration) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            for await element in stream { return element }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

/// A call that never returns on its own, not even when its task is cancelled (a system call that hangs), until
/// `release()`: a test lets it go once it is done, so no task is left waiting.
public final class NeverReturningCall: Sendable {
    private struct State {
        var waiting: [CheckedContinuation<Void, Never>] = []
        var released = false
        var cancelled = false
    }

    private let state = Mutex(State())

    public init() {}

    /// Returns only after `release()`. A cancellation is noted (`wasCancelled`) and does not end the wait.
    public func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let released = state.withLock { state in
                    if !state.released { state.waiting.append(continuation) }
                    return state.released
                }
                if released { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.cancelled = true }
        }
    }

    /// The task of a call waiting was cancelled.
    public var wasCancelled: Bool { state.withLock { $0.cancelled } }

    /// The calls waiting return, and later ones return at once.
    public func release() {
        let waiting = state.withLock { state in
            state.released = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}
