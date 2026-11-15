// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import CoreMedia
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Recording
import SyntheticCapture
import Testing

/// A source whose every `start` throws `error`.
private final class ThrowingSource: CaptureSource {
    let trackID = "mic"
    let kind = TrackKind.microphone
    let media = TrackMedia.audio
    let sourceInfo = TrackSource(name: "Throwing Microphone")
    var activeDeviceUniqueID: String? { nil }
    private let error: any Error

    init(_ error: any Error) {
        self.error = error
    }

    func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        throw error
    }

    func stop() async {}
}

/// Ignores everything it is sent.
private final class NullSink: CaptureSink {
    func source(_ trackID: String, didOutput sample: CMSampleBuffer) {}
    func source(_ trackID: String, didStopWithError error: any Error) {}
}

/// Starts (and, if it started, stops) a take of `sources` in a new package in `directory`; returns what `start()`
/// threw, if anything.
private func startTake(_ sources: [any CaptureSource], in directory: URL) async throws -> (any Error)? {
    let package = try ProjectPackage.create(
        in: directory, name: UUID().uuidString, app: AppInfo(name: "Tests", version: "0"), now: Date())
    let roomy = DiskCapacity(importantUsage: 100_000_000_000, available: 100_000_000_000)
    let coordinator = RecordingCoordinator(
        package: package, sources: sources, input: NoInputRecorder(),
        diskMonitor: DiskSpaceMonitor(volumeURL: directory, query: { _ in roomy }),
        systemActivity: AsyncStream { $0.finish() })
    do {
        _ = try await coordinator.start()
    } catch {
        return error
    }
    _ = try await coordinator.stop()
    return nil
}

private func display() -> SyntheticVideoSource {
    SyntheticVideoSource(width: 64, height: 36, framesPerSecond: 30)
}

@Test func aMicrophoneThatFailsToStartIsDroppedForARetry() async throws {
    try await withTemporaryDirectory { directory in
        let audio = SyntheticAudioSource()
        audio.failOnStart = 1
        let microphone = StartTrackingSource(audio)
        let thrown = try #require(try await startTake([display(), microphone], in: directory))
        #expect((thrown as NSError).domain == "Synthetic")
        #expect((microphone.firstStartFailure as? NSError)?.domain == "Synthetic")
        #expect(OptionalSourceFallback.failedOptionalKinds(after: thrown, among: [microphone]) == [.microphone])
    }
}

@Test func aCameraThatFailsToStartIsDroppedAloneForARetry() async throws {
    try await withTemporaryDirectory { directory in
        let video = SyntheticVideoSource(trackID: "camera", kind: .camera, width: 64, height: 36, framesPerSecond: 30)
        video.failOnStart = 1
        let camera = StartTrackingSource(video)
        let microphone = StartTrackingSource(SyntheticAudioSource())
        let systemAudio = StartTrackingSource(SyntheticAudioSource(trackID: "system-audio", kind: .systemAudio))
        let thrown = try #require(try await startTake([display(), camera, microphone, systemAudio], in: directory))
        // The sources start in order: the ones after the camera were never started.
        #expect(microphone.firstStartFailure == nil && systemAudio.firstStartFailure == nil)
        #expect(OptionalSourceFallback.failedOptionalKinds(after: thrown, among: [camera, microphone, systemAudio]) == [.camera])
    }
}

@Test func aDisplayThatFailsToStartIsNoReasonToDropTheMicrophone() async throws {
    try await withTemporaryDirectory { directory in
        let video = display()
        video.failOnStart = 1
        let microphone = StartTrackingSource(SyntheticAudioSource())
        let thrown = try #require(try await startTake([video, microphone], in: directory))
        // The display starts first, so the microphone was never started.
        #expect(microphone.firstStartFailure == nil)
        #expect(OptionalSourceFallback.failedOptionalKinds(after: thrown, among: [microphone]).isEmpty)
    }
}

@Test func aMicrophoneThatStartedIsNoReasonToRetry() async throws {
    try await withTemporaryDirectory { directory in
        let microphone = StartTrackingSource(SyntheticAudioSource())
        let error = try await startTake([display(), microphone], in: directory)
        #expect(error == nil)
        #expect(OptionalSourceFallback.failedOptionalKinds(after: CocoaError(.fileWriteUnknown), among: [microphone]).isEmpty)
    }
}

@Test func onlyTheFirstStartCounts() async throws {
    let audio = SyntheticAudioSource()
    let microphone = StartTrackingSource(audio)
    let queue = DispatchSerialQueue(label: "AppSupportTests.onlyTheFirstStartCounts")
    try await microphone.start(on: queue, sink: NullSink())
    await microphone.stop()
    audio.failOnStart = 1
    await #expect(throws: (any Error).self) { try await microphone.start(on: queue, sink: NullSink()) }
    // A failed restart is the coordinator's business: the take had started.
    #expect(microphone.firstStartFailure == nil)
}

@Test func aCancelledStartIsNeverRetried() async {
    let cancelled = StartTrackingSource(ThrowingSource(CancellationError()))
    await #expect(throws: CancellationError.self) {
        try await cancelled.start(on: DispatchSerialQueue(label: "AppSupportTests.cancelled"), sink: NullSink())
    }
    #expect(cancelled.firstStartFailure == nil)
    #expect(OptionalSourceFallback.failedOptionalKinds(after: CancellationError(), among: [cancelled]).isEmpty)

    let failed = StartTrackingSource(ThrowingSource(CocoaError(.fileReadUnknown)))
    await #expect(throws: CocoaError.self) {
        try await failed.start(on: DispatchSerialQueue(label: "AppSupportTests.failed"), sink: NullSink())
    }
    // Stopped while starting: the take's own error is a cancellation, whatever the microphone threw.
    #expect(OptionalSourceFallback.failedOptionalKinds(after: CancellationError(), among: [failed]).isEmpty)
    #expect(OptionalSourceFallback.failedOptionalKinds(after: CocoaError(.fileReadUnknown), among: [failed]) == [.microphone])
}

@Test func withoutOptionalSourcesThereIsNothingToDrop() {
    #expect(OptionalSourceFallback.failedOptionalKinds(after: CocoaError(.fileReadUnknown), among: []).isEmpty)
}
