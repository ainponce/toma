// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import CoreMedia
import Darwin
import Dispatch
import ProjectFormat
import RecorderKitTestSupport
import Recording
import Synchronization
import SyntheticCapture
import Testing
import Transcription

/// Listening to a metered microphone (plan 3d, decision 15): the listener hears every block on the capture queue, after
/// the sink, and never holds the capture up, not even with a live feed nobody reads.
@Suite(.timeLimit(.minutes(1))) struct MeteredSourceListenTests {
    @Test func listenerGetsEveryBlockAndPeaksStillCount() async throws {
        let queue = DispatchSerialQueue(label: "MeteredSourceListenTests")
        let burst = BurstSource()
        let metered = MeteredSource(burst)
        let sink = RecordingSink(queue: queue)
        // For each block the listener hears, how many the sink had by then.
        let heard = Mutex<[Int]>([])
        metered.listen { _ in
            let delivered = sink.samples.count
            heard.withLock { $0.append(delivered) }
        }
        try await metered.start(on: queue, sink: sink)
        _ = await burst.deliver(blocks(40))
        // Every block, each one after the sink had it.
        #expect(heard.withLock { $0 } == Array(1...40))
        #expect(sink.samples.count == 40 && sink.samples.allSatisfy { $0.trackID == "mic" && $0.frames == 480 })

        // The peak is the one a source without a listener reads: a sine at a quarter of full scale.
        let unheard = BurstSource()
        let plain = MeteredSource(unheard)
        try await plain.start(on: queue, sink: RecordingSink(queue: queue))
        _ = await unheard.deliver(blocks(40))
        #expect(abs(metered.peakDecibels - -12.04) < 0.1 && metered.peakDecibels == plain.peakDecibels)
        await plain.stop()

        // The listener stays from one run to the next.
        await metered.stop()
        try await metered.start(on: queue, sink: sink)
        _ = await burst.deliver(blocks(10))
        #expect(heard.withLock { $0.count } == 50 && sink.samples.count == 50)
        await metered.stop()
    }

    @Test func listenerNeverBlocksTheCaptureQueue() async throws {
        let feed = LiveMicrophoneFeed()
        // 6 s of microphone at once, to a feed nobody reads, and to a source nobody listens to.
        let (listened, alone) = try await timesOnTheCaptureQueue(blocks(600)) { feed.append($0) }
        // What the listener adds to the capture queue for the 600: the metering alone (30 ms in Debug on a quiet
        // machine, 50 ms with the load at 55) is the same with or without it. Not under the thread sanitizer
        // (`make tsan`), which checks the same path for races: there the times follow the machine's load.
        if !isThreadSanitized {
            #expect(listened - alone < .milliseconds(50), "600 blocks took \(listened) listened to, \(alone) not")
        }

        // Nobody read: the feed kept the newest two seconds of the thirty, converted off the capture queue.
        feed.finish()
        var kept = 0
        for await chunk in feed.chunks { kept += chunk.samples.count }
        #expect(kept == 96_000)
    }

    @Test func nilStopsListening() async throws {
        let queue = DispatchSerialQueue(label: "MeteredSourceListenTests")
        let burst = BurstSource()
        let metered = MeteredSource(burst)
        let sink = RecordingSink(queue: queue)
        let first = Mutex(0)
        metered.listen { _ in first.withLock { $0 += 1 } }
        try await metered.start(on: queue, sink: sink)
        _ = await burst.deliver(blocks(10))
        #expect(first.withLock { $0 } == 10)

        // 100 s of microphone, then the listener is let go: it stays as it was set, however many blocks it heard (a
        // closure called through the lock once nested deeper with each block, and releasing it overflowed the stack).
        let one = blocks(1)[0]
        _ = await burst.deliver(Array(repeating: one, count: 10_000))
        #expect(first.withLock { $0 } == 10_010)
        metered.listen(nil)
        _ = await burst.deliver(blocks(10))
        // None more to the listener; the sink gets them all.
        #expect(first.withLock { $0 } == 10_010 && sink.samples.count == 10_020)

        // Another listener hears from when it is set, and the one before stays quiet.
        let second = Mutex(0)
        metered.listen { _ in second.withLock { $0 += 1 } }
        _ = await burst.deliver(blocks(5))
        #expect(first.withLock { $0 } == 10_010 && second.withLock { $0 } == 5 && sink.samples.count == 10_025)
        await metered.stop()
    }
}

/// How long `blocks` take on the capture queue through a metered source that `listener` listens to, and through one
/// nobody listens to: five times each, the fastest of each.
private func timesOnTheCaptureQueue(
    _ blocks: [HeldSample], listener: @escaping @Sendable (CMSampleBuffer) -> Void
) async throws -> (listened: Duration, alone: Duration) {
    let queue = DispatchSerialQueue(label: "MeteredSourceListenTests")
    let (heardBurst, unheardBurst) = (BurstSource(), BurstSource())
    let (heard, unheard) = (MeteredSource(heardBurst), MeteredSource(unheardBurst))
    heard.listen(listener)
    try await heard.start(on: queue, sink: CountingSink())
    try await unheard.start(on: queue, sink: CountingSink())
    var listened = Duration.seconds(60)
    var alone = Duration.seconds(60)
    for _ in 0..<5 {
        alone = min(alone, await unheardBurst.deliver(blocks))
        listened = min(listened, await heardBurst.deliver(blocks))
    }
    await heard.stop()
    await unheard.stop()
    heard.listen(nil)
    return (listened, alone)
}

/// Whether the tests run under the thread sanitizer (`make tsan`), whose runtime is then loaded.
private let isThreadSanitized = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil

/// `count` 10 ms blocks of a 440 Hz sine at a quarter of full scale, mono Float32 at 48 kHz, one after the other.
private func blocks(_ count: Int) -> [HeldSample] {
    (0..<count).map { block in
        HeldSample(sample: SampleFactory.audioSample(
            pts: HostTime(nanoseconds: 1_000_000_000 + UInt64(block) * 10_000_000), frames: 480, sampleRate: 48_000, channels: 1))
    }
}

/// A block made on the test's task and delivered on the capture queue. `@unchecked Sendable`: nothing writes to it once
/// made, as with a capture source's blocks.
private struct HeldSample: @unchecked Sendable {
    let sample: CMSampleBuffer
}

/// A microphone that delivers the blocks it is given all at once on its run's queue, as fast as its sink takes them.
private final class BurstSource: CaptureSource {
    let trackID = "mic"
    let kind = TrackKind.microphone
    let media = TrackMedia.audio
    var sourceInfo: TrackSource { TrackSource(name: "Burst Microphone", deviceUniqueID: "burst-mic") }
    var activeDeviceUniqueID: String? { nil }

    private let run = Mutex<Run?>(nil)

    private struct Run: Sendable {
        let queue: DispatchSerialQueue
        let sink: any CaptureSink
    }

    func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        run.withLock { $0 = Run(queue: queue, sink: sink) }
    }

    func stop() async {
        let queue = run.withLock { run in
            defer { run = nil }
            return run?.queue
        }
        // Whatever was being delivered has finished.
        await withCheckedContinuation { continuation in
            guard let queue else { return continuation.resume() }
            queue.async { continuation.resume() }
        }
    }

    /// Delivers `blocks` on the run's queue, one after the other, and gives how long that took there.
    func deliver(_ blocks: [HeldSample]) async -> Duration {
        guard let run = run.withLock({ $0 }) else { return .zero }
        let trackID = trackID
        return await withCheckedContinuation { continuation in
            run.queue.async {
                let clock = ContinuousClock()
                let start = clock.now
                for block in blocks { run.sink.source(trackID, didOutput: block.sample) }
                continuation.resume(returning: clock.now - start)
            }
        }
    }
}

/// A sink that only counts what it gets, so the time on the capture queue is the metering's and the listener's.
private final class CountingSink: CaptureSink {
    private let count = Atomic(0)

    func source(_ trackID: String, didOutput sample: CMSampleBuffer) {
        count.add(1, ordering: .relaxed)
    }

    func source(_ trackID: String, didStopWithError error: any Error) {}
}

