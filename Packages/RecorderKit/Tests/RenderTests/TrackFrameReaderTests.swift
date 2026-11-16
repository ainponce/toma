// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreVideo
import Foundation
import ProjectFormat
import RecorderKitTestSupport
@testable import Render
import SyntheticCapture
import Testing

private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)

/// The display track of a take of `segments` written with `TakeBuilder`, and its package.
private func displayTake(in dir: URL, _ segments: [VideoSegmentSpec]) async throws -> (ProjectPackage, TrackRecord) {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(id: trackID, source: displaySource(globalFrame: screenFrame), segments: segments)
    let project = try builder.write()
    return (project.package, try #require(project.take.track(trackID)))
}

/// The number of the frame `reader` gives at `t`, or `nil` for none. Read off the cooperative pool: the reader decodes,
/// and blocks while it does (`TrackFrameReader` is never called from a Swift concurrency thread).
private func index(_ reader: TrackFrameReader, at t: HostTime) async throws -> Int? {
    try await offThePool { reader.pixelBuffer(at: t).map(frameIndex(of:)) }
}

/// The numbers of the frames `reader` gives at `times`, one after the other, off the cooperative pool.
private func indices(_ reader: TrackFrameReader, at times: [HostTime]) async throws -> [Int?] {
    try await offThePool { times.map { reader.pixelBuffer(at: $0).map(frameIndex(of:)) } }
}

/// `renderer`'s frame at `t`, drawn off the cooperative pool: drawing decodes, and blocks while it does.
private func drawn(_ renderer: FrameRenderer, at t: Double) async throws -> [UInt8] {
    try await offThePool { try renderer.renderBytes(at: t) }
}

@Test func readerReturnsLatestFrameNotAfterTime() async throws {
    try await withTemporaryDirectory { dir in
        let (package, track) = try await displayTake(in: dir, [VideoSegmentSpec(start: base, seconds: 3)])
        let reader = TrackFrameReader(package: package, track: track)

        #expect(try await index(reader, at: base.adding(seconds: -0.5)) == nil)
        let first = try await offThePool { () -> (index: Int, format: OSType, width: Int, height: Int)? in
            reader.pixelBuffer(at: base).map {
                (frameIndex(of: $0), CVPixelBufferGetPixelFormatType($0), CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0))
            }
        }
        #expect(first?.index == 0)
        #expect(first?.format == kCVPixelFormatType_32BGRA)
        #expect(first?.width == 640 && first?.height == 360)
        #expect(try await indices(reader, at: [base.adding(seconds: 0.49), base.adding(seconds: 0.51)]) == [14, 15])
        #expect(reader.openedReaderCount == 1)

        // A jump of 2 s or more, or any step back, opens a new reader from t − 1 s.
        #expect(try await index(reader, at: base.adding(seconds: 2.61)) == 78 % 64)
        #expect(reader.openedReaderCount == 2)
        #expect(try await index(reader, at: base.adding(seconds: 0.51)) == 15)
        #expect(reader.openedReaderCount == 3)
        // After the end, the last frame.
        #expect(try await index(reader, at: base.adding(seconds: 30)) == 89 % 64)
    }
}

@Test func readerReadsSequentiallyWithOneReaderPerSegment() async throws {
    try await withTemporaryDirectory { dir in
        let (package, track) = try await displayTake(in: dir, [VideoSegmentSpec(start: base, seconds: 3)])
        let reader = TrackFrameReader(package: package, track: track)
        // 60 fps output over 30 fps media: every frame twice, in order.
        let read = try await indices(reader, at: (0..<180).map { base.adding(seconds: (Double($0) + 0.5) / 60) })
        for (k, index) in read.enumerated() {
            #expect(index == (k / 2) % 64, "output frame \(k)")
        }
        #expect(reader.openedReaderCount == 1)
    }
}

@Test func readerHoldsLastFrameAcrossGap() async throws {
    try await withTemporaryDirectory { dir in
        // The frames of the second segment are numbered from 30, after the first one's.
        let (package, track) = try await displayTake(in: dir, [
            VideoSegmentSpec(start: base, seconds: 1),
            VideoSegmentSpec(start: base.adding(seconds: 1.5), seconds: 1),
        ])

        // Straight into the gap.
        let seeking = TrackFrameReader(package: package, track: track)
        #expect(try await indices(seeking, at: [base.adding(seconds: 1.2), base.adding(seconds: 1.6 + 1.0 / 60)]) == [29, 33])

        // Playing through it.
        let playing = TrackFrameReader(package: package, track: track)
        let times = (0..<150).map { (Double($0) + 0.5) / 60 }
        let read = try await indices(playing, at: times.map { base.adding(seconds: $0) })
        for (k, (seconds, index)) in zip(times, read).enumerated() {
            let expected = seconds < 1 ? k / 2 : seconds < 1.5 ? 29 : 30 + Int((seconds - 1.5) * 30)
            #expect(index == expected, "output frame \(k) at \(seconds) s")
        }
        #expect(playing.openedReaderCount == 2)
    }
}

@Test func readerTreatsEmptyUnreadableAndMissingSegmentsAsGaps() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(
            id: trackID, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 1)])
        // Recovery marks these, but a reader must survive them however they are marked.
        try builder.addEmptySegment(
            track: trackID, index: 2, start: base.adding(seconds: 1), end: base.adding(seconds: 2), endReason: .empty, file: .zeroBytes)
        try builder.addEmptySegment(
            track: trackID, index: 3, start: base.adding(seconds: 2), end: base.adding(seconds: 3), endReason: .stopped,
            file: .garbage(bytes: 4096))
        try builder.addEmptySegment(
            track: trackID, index: 4, start: base.adding(seconds: 3), end: base.adding(seconds: 4), endReason: .stopped, file: .absent)
        try builder.addEmptySegment(
            track: trackID, index: 5, start: base.adding(seconds: 4), end: base.adding(seconds: 5), endReason: .unreadable(bytes: 10),
            file: .absent)
        let project = try builder.write()
        let reader = TrackFrameReader(package: project.package, track: try #require(project.take.track(trackID)))
        let times = [1.5, 2.5, 3.5, 4.5, 2.2]
        for (seconds, index) in zip(times, try await indices(reader, at: times.map { base.adding(seconds: $0) })) {
            #expect(index == 29, "at \(seconds) s")
        }
        // Every span held over is listed: the marked and missing ones from the start, the garbage once read.
        let gaps = reader.gaps
        #expect(gaps.map(\.file) == [2, 4, 5, 3].map { "takes/\(takeID)/\(trackID)/seg-000\($0).mov" })
        #expect(gaps.map { $0.start.seconds(since: base) } == [1, 3, 4, 2])
        #expect(gaps.map { $0.end.seconds(since: base) } == [2, 4, 5, 3])
        #expect(Array(gaps.map(\.reason).prefix(3)) == [.empty, .fileMissing, .unreadable])
        guard case .cannotOpen = gaps.last?.reason else {
            Issue.record("expected cannotOpen for the garbage file, got \(String(describing: gaps.last))")
            return
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func rendererOpensTakeWithEmptyAndMissingSegments() async throws {
    try await withTemporaryDirectory { dir in
        // 1: a file of 0 bytes that recovery marked empty; 2: valid; 3: its file is gone.
        let builder = try TakeBuilder(in: dir)
        let source = displaySource(globalFrame: screenFrame)
        try await builder.addVideoTrack(id: trackID, source: source, segments: [])
        try builder.addEmptySegment(
            track: trackID, index: 1, start: base, end: base.adding(seconds: 1), endReason: .empty, file: .zeroBytes)
        try await builder.addVideoTrack(
            id: trackID, source: source, segments: [VideoSegmentSpec(start: base.adding(seconds: 1), seconds: 1)])
        try builder.addEmptySegment(
            track: trackID, index: 3, start: base.adding(seconds: 2), end: base.adding(seconds: 3), endReason: .recoveredAfterCrash,
            file: .absent)
        let project = try builder.write()
        let take = project.take

        let size = SIMD2(640, 360)
        let renderer = try FrameRenderer(project: project, outputSize: size)
        #expect(renderer.duration == 3)
        let rect = try #require(FrameEvaluator(take: take, events: [], style: StyleV0(), outputSize: size).frame(at: 0).screen?.rect)
        let x = Int(rect.x + rect.width / 2), y = Int(rect.y + rect.height * 0.75)
        func indexAt(_ t: Double) async throws -> Int {
            SampleFactory.frameIndex(nearestTo: pixel(try await drawn(renderer, at: t), width: size.x, x: x, y: y))
        }

        // Before any frame: only the background.
        let style = StyleV0()
        let background = expectedBackground(
            x: x, y: y, size: size, start: style.gradientStart, end: style.gradientEnd, angleDegrees: style.gradientAngleDegrees)
        #expect(isClose(pixel(try await drawn(renderer, at: 0.5), width: size.x, x: x, y: y), background))
        // The frames of the second segment, then its last one held over the missing third.
        #expect(try await indexAt(1.51) == 15)
        #expect(try await indexAt(1.99) == 29)
        #expect(try await indexAt(2.5) == 29)
        #expect(try await indexAt(3) == 29)
        #expect(try await indexAt(1.21) == 6)
    }
}

/// Counts track loads and times out the first `timeouts` of them for the file named `failing`.
private final class FlakyLoader: @unchecked Sendable {
    let failing: String
    var timeouts: Int
    var calls = 0

    init(failing: String, timeouts: Int) {
        self.failing = failing
        self.timeouts = timeouts
    }

    func load(_ asset: AVURLAsset) -> TrackFrameReader.TrackLoad {
        guard asset.url.lastPathComponent == failing else { return TrackFrameReader.loadFirstVideoTrack(of: asset) }
        calls += 1
        if timeouts > 0 {
            timeouts -= 1
            return .timedOut
        }
        return TrackFrameReader.loadFirstVideoTrack(of: asset)
    }
}

@Test(arguments: [0.0, 3600.0])
func readerRetriesASegmentWhoseTrackLoadTimedOut(backoff: Double) async throws {
    try await withTemporaryDirectory { dir in
        let (package, track) = try await displayTake(in: dir, [
            VideoSegmentSpec(start: base, seconds: 1),
            VideoSegmentSpec(start: base.adding(seconds: 1), seconds: 1),
        ])
        let reader = TrackFrameReader(package: package, track: track)
        let loader = FlakyLoader(failing: "seg-0002.mov", timeouts: 1)
        reader.trackLoader = loader.load
        reader.timeoutBackoff = backoff

        #expect(try await index(reader, at: base.adding(seconds: 0.51)) == 15)
        // The second segment's load times out: its time shows the frame before it, for now.
        #expect(try await index(reader, at: base.adding(seconds: 1.51)) == 29)
        #expect(loader.calls == 1)
        let next = try #require(try await index(reader, at: base.adding(seconds: 1.55)))
        let gap = try #require(reader.gaps.first)
        #expect(reader.gaps.count == 1 && gap.reason == .loadTimedOut && gap.file == "takes/\(takeID)/\(trackID)/seg-0002.mov")
        #expect(abs(gap.start.seconds(since: base) - 1.51) < 1e-6)
        if backoff == 0 {
            // Tried again on the next request, which now loads.
            #expect(loader.calls == 2)
            #expect(next == 30 + 16)
            #expect(abs(gap.end.seconds(since: base) - 1.51) < 1e-6)
        } else {
            // Still backing off: no new attempt, so a stuck load stalls one frame, not every frame.
            #expect(loader.calls == 1)
            #expect(next == 29)
            // The span grows with every frame shown while it backs off.
            #expect(abs(gap.end.seconds(since: base) - 1.55) < 1e-6)
        }
    }
}

@Test func readerMarksASegmentWhoseTrackFailsToLoadUnreadable() async throws {
    try await withTemporaryDirectory { dir in
        let (package, track) = try await displayTake(in: dir, [
            VideoSegmentSpec(start: base, seconds: 1),
            VideoSegmentSpec(start: base.adding(seconds: 1), seconds: 1),
        ])
        let reader = TrackFrameReader(package: package, track: track)
        let calls = FlakyLoader(failing: "seg-0002.mov", timeouts: 0)
        reader.trackLoader = { asset in
            guard asset.url.lastPathComponent == "seg-0002.mov" else { return TrackFrameReader.loadFirstVideoTrack(of: asset) }
            calls.calls += 1
            return .failed("injected")
        }
        reader.timeoutBackoff = 0
        #expect(try await indices(reader, at: [base.adding(seconds: 1.51), base.adding(seconds: 1.21)]) == [29, 29])
        #expect(calls.calls == 1)
        #expect(reader.gaps == [TrackFrameReader.Gap(
            file: "takes/\(takeID)/\(trackID)/seg-0002.mov", start: base.adding(seconds: 1), end: track.segments[1].endHostTime ?? base,
            reason: .cannotOpen("injected"))])
    }
}

/// The camera is read by a reader of its own, which holds its last frame across a gap like the screen's.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func cameraHoldsLastFrameAcrossAGap() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(
            id: trackID, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 3)])
        // The frames of the second segment are numbered from 30, after the first one's.
        try await builder.addVideoTrack(id: cameraID, kind: .camera, source: cameraSource, segments: [
            VideoSegmentSpec(start: base, seconds: 1, endReason: .paused),
            VideoSegmentSpec(start: base.adding(seconds: 2), seconds: 1),
        ])
        let project = try builder.write()
        let size = SIMD2(640, 360)
        let renderer = try FrameRenderer(project: project, outputSize: size)
        let evaluator = FrameEvaluator(take: project.take, events: [], style: StyleV0(), outputSize: size)
        func indices(at t: Double) async throws -> (screen: Int, camera: Int) {
            let frame = evaluator.frame(at: t)
            let screen = try #require(frame.screen?.rect), camera = try #require(frame.camera?.rect)
            let bytes = try await drawn(renderer, at: t)
            func index(_ x: Double, _ y: Double) -> Int {
                SampleFactory.frameIndex(nearestTo: pixel(bytes, width: size.x, x: Int(x), y: Int(y)))
            }
            return (index(screen.x + screen.width / 4, screen.y + screen.height * 0.75),
                    index(camera.x + camera.width / 2, camera.y + camera.height / 2))
        }
        #expect(try await indices(at: 0.5) == (15, 15))
        #expect(try await indices(at: 1.5) == (45, 29))
        #expect(try await indices(at: 2.5) == (75 % 64, 45))
        #expect(renderer.missingVideo.isEmpty)  // a gap between segments is not missing video
    }
}

/// What could not be read of the screen and of the camera is listed together, each span with its track.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func rendererListsWhatItMissesOfEachTrack() throws {
    try withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Gaps", app: AppInfo(name: "Tests", version: "0"), now: Date())
        let take = makeTake(tracks: [
            displayTrack(globalFrame: screenFrame, segments: [
                segment(index: 1, start: base, end: base.adding(seconds: 2), reason: .empty),
                segment(index: 2, start: base.adding(seconds: 2), end: base.adding(seconds: 4)),
            ]),
            displayTrack(id: cameraID, kind: .camera, globalFrame: nil, segments: [
                segment(track: cameraID, index: 1, start: base.adding(seconds: 1), end: base.adding(seconds: 3), reason: .unreadable(bytes: 10)),
            ]),
        ])
        let renderer = try FrameRenderer(project: makeProject(package, take: take), outputSize: [320, 180])
        #expect(renderer.missingVideo == [
            MissingVideo(track: trackID, file: "takes/\(takeID)/\(trackID)/seg-0001.mov", start: 0, end: 2, reason: .empty),
            MissingVideo(track: cameraID, file: "takes/\(takeID)/\(cameraID)/seg-0001.mov", start: 1, end: 3, reason: .unreadable),
            MissingVideo(track: trackID, file: "takes/\(takeID)/\(trackID)/seg-0002.mov", start: 2, end: 4, reason: .fileMissing),
        ])
    }
}
