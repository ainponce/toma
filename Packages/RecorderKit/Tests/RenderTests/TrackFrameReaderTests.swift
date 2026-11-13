// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Foundation
import ProjectFormat
@testable import Render
import SyntheticCapture
import Testing

private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)

@Test func readerReturnsLatestFrameNotAfterTime() async throws {
    try await withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        let seg = try await writeSegment(in: package, index: 1, start: base, seconds: 3)
        let reader = TrackFrameReader(package: package, track: displayTrack(globalFrame: screenFrame, segments: [seg]))

        #expect(reader.pixelBuffer(at: base.adding(seconds: -0.5)) == nil)
        let first = try #require(reader.pixelBuffer(at: base))
        #expect(frameIndex(of: first) == 0)
        #expect(CVPixelBufferGetPixelFormatType(first) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetWidth(first) == 640 && CVPixelBufferGetHeight(first) == 360)
        #expect(frameIndex(of: try #require(reader.pixelBuffer(at: base.adding(seconds: 0.49)))) == 14)
        #expect(frameIndex(of: try #require(reader.pixelBuffer(at: base.adding(seconds: 0.51)))) == 15)
        #expect(reader.openedReaderCount == 1)

        // A jump of 2 s or more, or any step back, opens a new reader from t − 1 s.
        #expect(frameIndex(of: try #require(reader.pixelBuffer(at: base.adding(seconds: 2.61)))) == 78 % 64)
        #expect(reader.openedReaderCount == 2)
        #expect(frameIndex(of: try #require(reader.pixelBuffer(at: base.adding(seconds: 0.51)))) == 15)
        #expect(reader.openedReaderCount == 3)
        // After the end, the last frame.
        #expect(frameIndex(of: try #require(reader.pixelBuffer(at: base.adding(seconds: 30)))) == 89 % 64)
    }
}

@Test func readerReadsSequentiallyWithOneReaderPerSegment() async throws {
    try await withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        let seg = try await writeSegment(in: package, index: 1, start: base, seconds: 3)
        let reader = TrackFrameReader(package: package, track: displayTrack(globalFrame: screenFrame, segments: [seg]))
        // 60 fps output over 30 fps media: every frame twice, in order.
        for k in 0..<180 {
            let t = base.adding(seconds: (Double(k) + 0.5) / 60)
            let buffer = try #require(reader.pixelBuffer(at: t))
            #expect(frameIndex(of: buffer) == (k / 2) % 64, "output frame \(k)")
        }
        #expect(reader.openedReaderCount == 1)
    }
}

@Test func readerHoldsLastFrameAcrossGap() async throws {
    try await withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        let first = try await writeSegment(in: package, index: 1, start: base, seconds: 1)
        let second = try await writeSegment(
            in: package, index: 2, start: base.adding(seconds: 1.5), seconds: 1, firstFrame: 30)
        let track = displayTrack(globalFrame: screenFrame, segments: [first, second])

        // Straight into the gap.
        let seeking = TrackFrameReader(package: package, track: track)
        #expect(frameIndex(of: try #require(seeking.pixelBuffer(at: base.adding(seconds: 1.2)))) == 29)
        #expect(frameIndex(of: try #require(seeking.pixelBuffer(at: base.adding(seconds: 1.6 + 1.0 / 60)))) == 33)

        // Playing through it.
        let playing = TrackFrameReader(package: package, track: track)
        for k in 0..<150 {
            let seconds = (Double(k) + 0.5) / 60
            let expected = seconds < 1 ? k / 2 : seconds < 1.5 ? 29 : 30 + Int((seconds - 1.5) * 30)
            let buffer = try #require(playing.pixelBuffer(at: base.adding(seconds: seconds)))
            #expect(frameIndex(of: buffer) == expected, "output frame \(k) at \(seconds) s")
        }
        #expect(playing.openedReaderCount == 2)
    }
}

@Test func readerTreatsEmptyUnreadableAndMissingSegmentsAsGaps() async throws {
    try await withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        let first = try await writeSegment(in: package, index: 1, start: base, seconds: 1)
        // Recovery marks these, but a reader must survive them however they are marked.
        let emptyURL = package.segmentURL(take: takeID, track: trackID, index: 2)
        try Data().write(to: emptyURL)
        let garbageURL = package.segmentURL(take: takeID, track: trackID, index: 3)
        try Data(repeating: 0x5A, count: 4096).write(to: garbageURL)
        let segments = [
            first,
            segment(index: 2, start: base.adding(seconds: 1), end: base.adding(seconds: 2), reason: .empty),
            segment(index: 3, start: base.adding(seconds: 2), end: base.adding(seconds: 3), reason: .stopped),
            segment(index: 4, start: base.adding(seconds: 3), end: base.adding(seconds: 4), reason: .stopped),
            segment(index: 5, start: base.adding(seconds: 4), end: base.adding(seconds: 5), reason: .unreadable(bytes: 10)),
        ]
        let reader = TrackFrameReader(package: package, track: displayTrack(globalFrame: screenFrame, segments: segments))
        for seconds in [1.5, 2.5, 3.5, 4.5, 2.2] {
            let buffer = try #require(reader.pixelBuffer(at: base.adding(seconds: seconds)), "at \(seconds) s")
            #expect(frameIndex(of: buffer) == 29, "at \(seconds) s")
        }
    }
}

@Test(.enabled(if: metalAvailable))
func rendererOpensTakeWithEmptyAndMissingSegments() async throws {
    try await withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        // 1: a file of 0 bytes that recovery marked empty; 2: valid; 3: its file is gone.
        let emptyURL = package.segmentURL(take: takeID, track: trackID, index: 1)
        try FileManager.default.createDirectory(at: emptyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: emptyURL)
        let valid = try await writeSegment(in: package, index: 2, start: base.adding(seconds: 1), seconds: 1)
        let take = makeTake(tracks: [displayTrack(globalFrame: screenFrame, segments: [
            segment(index: 1, start: base, end: base.adding(seconds: 1), reason: .empty),
            valid,
            segment(index: 3, start: base.adding(seconds: 2), end: base.adding(seconds: 3), reason: .recoveredAfterCrash),
        ])])
        try ManifestStore(package: package).update { $0.takes.append(take) }
        let project = try LoadedProject.load(package.url)

        let size = SIMD2(640, 360)
        let renderer = try FrameRenderer(project: project, outputSize: size)
        #expect(renderer.duration == 3)
        let rect = try #require(FrameEvaluator(take: take, events: [], style: StyleV0(), outputSize: size).frame(at: 0).screen?.rect)
        let x = Int(rect.x + rect.width / 2), y = Int(rect.y + rect.height * 0.75)
        func indexAt(_ t: Double) throws -> Int {
            SampleFactory.frameIndex(nearestTo: pixel(try renderer.renderBytes(at: t), width: size.x, x: x, y: y))
        }

        // Before any frame: only the background.
        let style = StyleV0()
        let background = expectedBackground(
            x: x, y: y, size: size, start: style.gradientStart, end: style.gradientEnd, angleDegrees: style.gradientAngleDegrees)
        #expect(isClose(pixel(try renderer.renderBytes(at: 0.5), width: size.x, x: x, y: y), background))
        // The frames of the second segment, then its last one held over the missing third.
        #expect(try indexAt(1.51) == 15)
        #expect(try indexAt(1.99) == 29)
        #expect(try indexAt(2.5) == 29)
        #expect(try indexAt(3) == 29)
        #expect(try indexAt(1.21) == 6)
    }
}
