// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Recording
import Testing

/// A microphone whose clock runs 2000 ppm fast: the builder logs the `audioClock` anchors the pipeline would,
/// one every 5 s of host time, each naming the first frame of a 10 ms block and that block's host time.
@Test func takeBuilderLogsAnchorsWithSkew() async throws {
    try await withTemporaryDirectory { dir in
        let start = HostTime(nanoseconds: 5_000_000_000_000)
        let skew = 2000.0
        let builder = try TakeBuilder(in: dir)
        try await builder.addAudioTrack(
            id: "mic", source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic"),
            segments: [AudioSegmentSpec(start: start, seconds: 12, clockSkewPPM: skew)])
        let project = try builder.write()

        let anchors = project.events.compactMap { event -> (frame: Int, t: HostTime)? in
            guard case let .audioClock(track, frame) = event.kind, track == "mic" else { return nil }
            return (frame, event.t)
        }
        try #require(anchors.count == 2, "\(anchors)")
        for anchor in anchors {
            #expect(anchor.frame % 480 == 0)
            let expected = Double(anchor.frame) / 48_000 * (1 + skew * 1e-6)
            #expect(abs(anchor.t.seconds(since: start) - expected) < 0.001, "frame \(anchor.frame) at \(anchor.t.seconds(since: start)) s")
        }
    }
}

/// A package an earlier version of the app created: the manifest says so before and after the take is written.
@Test func takeBuilderWritesAnOlderFormatVersion() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir, formatVersion: 1)
        let created = try Data(contentsOf: builder.package.manifestURL)
        #expect(try Manifest.formatVersion(of: created) == 1)
        try await builder.addAudioTrack(
            id: "mic", source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic"),
            segments: [AudioSegmentSpec(start: HostTime(nanoseconds: 5_000_000_000_000), seconds: 1)])
        let project = try builder.write()

        #expect(project.manifest.formatVersion == 1)
        #expect(try LoadedProject.load(builder.package.url).manifest == project.manifest)
        #expect(project.take.tracks.map(\.id) == ["mic"])
    }
}

/// Counts the video writers a test's `TakeBuilder.makeVideoWriter` was asked for.
private final class WriterAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var made = 0
    var count: Int { lock.withLock { made } }

    /// The number of this attempt, from 1.
    func next() -> Int { lock.withLock { made += 1; return made } }
}

/// A hardware-only segment whose writer fails (the media engine takes no session, and leaves a partial file) is
/// written again from its first frame until a writer takes it: one segment, every frame, one `segmentStarted`.
@Test func takeBuilderWritesAHardwareOnlySegmentAgainUntilAnEncoderTakesIt() async throws {
    try await withTemporaryDirectory { dir in
        let start = HostTime(nanoseconds: 5_000_000_000_000)
        let builder = try TakeBuilder(in: dir)
        builder.videoEncoder = .hardwareOnly
        builder.hardwareEncoderRetryInterval = 0.01
        let attempts = WriterAttempts()
        builder.makeVideoWriter = { url, framesPerSecond, encoder in
            #expect(encoder == .hardwareOnly)
            guard attempts.next() > 2 else {
                try Data(repeating: 0x5A, count: 64).write(to: url)
                throw WriterError.appendFailed("no hardware encoder session")
            }
            // Any encoder: what is tested is the builder, on any machine.
            return try FragmentedTrackWriter(url: url, media: .video(framesPerSecond: framesPerSecond), realTime: false)
        }
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1),
            segments: [VideoSegmentSpec(start: start, seconds: 1)])
        let project = try builder.write()
        #expect(attempts.count == 3)
        let segments = try #require(project.take.track("display-1")).segments
        try #require(segments.count == 1)
        #expect(try await decodedFrameIndices(of: project.package.fileURL(segments[0].file)) == Array(0..<30))
        let started = project.events.filter { if case .segmentStarted = $0.kind { true } else { false } }
        #expect(started.count == 1)
    }
}

/// A hardware-only segment no writer takes within `hardwareEncoderTimeout` fails, saying why, and leaves no file;
/// a segment of any encoder fails on its first error, without trying again.
@Test func takeBuilderGivesUpOnTheHardwareEncoderAfterItsTimeout() async throws {
    try await withTemporaryDirectory { dir in
        let start = HostTime(nanoseconds: 5_000_000_000_000)
        let source = TrackSource(name: "Synthetic Display", displayID: 1)
        let builder = try TakeBuilder(in: dir, name: "Hardware")
        builder.videoEncoder = .hardwareOnly
        builder.hardwareEncoderTimeout = 0.5
        builder.hardwareEncoderRetryInterval = 0.01
        let attempts = WriterAttempts()
        builder.makeVideoWriter = { url, _, _ in
            _ = attempts.next()
            try Data(repeating: 0x5A, count: 64).write(to: url)
            throw WriterError.appendFailed("no hardware encoder session")
        }
        let started = ContinuousClock.now
        do {
            try await builder.addVideoTrack(id: "display-1", source: source, segments: [VideoSegmentSpec(start: start, seconds: 1)])
            Issue.record("the segment was written")
        } catch let TestSupportError.failed(message) {
            #expect(message.contains("hardware HEVC encoder still failed 0.5 s after this take's first encoder failure"), "\(message)")
            #expect(message.contains("no hardware encoder session"), "\(message)")
        }
        // It tried again, and gave up only once the timeout passed (how many times it tried depends on the load).
        #expect(attempts.count >= 2)
        #expect(ContinuousClock.now - started >= .milliseconds(500))
        let url = builder.package.segmentURL(take: "take-001", track: "display-1", index: 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let any = try TakeBuilder(in: dir, name: "Any")
        any.videoEncoder = .any
        let once = WriterAttempts()
        any.makeVideoWriter = { _, _, encoder in
            #expect(encoder == .any)
            _ = once.next()
            throw WriterError.appendFailed("no hardware encoder session")
        }
        await #expect(throws: WriterError.appendFailed("no hardware encoder session")) {
            try await any.addVideoTrack(id: "display-1", source: source, segments: [VideoSegmentSpec(start: start, seconds: 1)])
        }
        #expect(once.count == 1)
    }
}

/// A hardware-only segment that fails for another reason than the encoder (here a format the writer refuses) fails at
/// once: writing it again would only repeat the fault, after waiting the whole timeout for nothing.
@Test func takeBuilderWritesAHardwareOnlySegmentOnceWhenItFailsForAnotherReason() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        builder.videoEncoder = .hardwareOnly
        builder.hardwareEncoderRetryInterval = 0.01
        let attempts = WriterAttempts()
        builder.makeVideoWriter = { _, _, _ in
            _ = attempts.next()
            throw WriterError.unsupportedFormat
        }
        await #expect(throws: WriterError.unsupportedFormat) {
            try await builder.addVideoTrack(
                id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1),
                segments: [VideoSegmentSpec(start: HostTime(nanoseconds: 5_000_000_000_000), seconds: 1)])
        }
        #expect(attempts.count == 1)
        #expect(builder.hardwareEncoderDeadline == nil)
    }
}

/// The wait for the hardware encoder is one for the whole take: it starts at the take's first encoder failure and
/// does not start again with the next segment, so a take of many segments is not given the timeout once per segment.
@Test func takeBuilderWaitsForTheHardwareEncoderOnceForTheWholeTake() async throws {
    try await withTemporaryDirectory { dir in
        let start = HostTime(nanoseconds: 5_000_000_000_000)
        let builder = try TakeBuilder(in: dir)
        builder.videoEncoder = .hardwareOnly
        builder.hardwareEncoderRetryInterval = 0.01
        let attempts = WriterAttempts()
        // The first writer of each segment is refused.
        builder.makeVideoWriter = { url, framesPerSecond, _ in
            guard attempts.next() % 2 == 0 else { throw WriterError.appendFailed("no hardware encoder session") }
            return try FragmentedTrackWriter(url: url, media: .video(framesPerSecond: framesPerSecond), realTime: false)
        }
        let source = TrackSource(name: "Synthetic Display", displayID: 1)
        try await builder.addVideoTrack(id: "display-1", source: source, segments: [VideoSegmentSpec(start: start, seconds: 0.5)])
        let deadline = try #require(builder.hardwareEncoderDeadline)
        try await builder.addVideoTrack(
            id: "display-1", source: source, segments: [VideoSegmentSpec(start: start.adding(seconds: 0.5), seconds: 0.5)])
        #expect(attempts.count == 4)
        #expect(builder.hardwareEncoderDeadline == deadline)
    }
}

/// Without a choice, the fixtures wait for the hardware encoder on a Mac that has one, outside CI.
@Test func takeBuilderPinsTheHardwareEncoderWhereThereIsOne() throws {
    try withTemporaryDirectory { dir in
        let inCI = ProcessInfo.processInfo.environment["TOMA_CI"] == "1"
        let expected: VideoEncoderChoice = !inCI && TakeBuilder.hasHardwareHEVCEncoder ? .hardwareOnly : .any
        #expect(TakeBuilder.defaultVideoEncoder == expected)
        let builder = try TakeBuilder(in: dir)
        #expect(builder.videoEncoder == expected)
    }
}
