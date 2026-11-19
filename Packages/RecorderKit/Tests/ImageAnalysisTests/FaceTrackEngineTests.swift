// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Foundation
import ImageAnalysis
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing

@Suite struct FaceTrackEngineTests {
    @Test func faceTrackSamplesEvery100ms() async throws {
        try await withTemporaryDirectory { dir in
            let camera = try await cameraSegment(in: dir, seconds: 1)
            let detector = ScriptedFaces { _ in [] }
            let track = try await FaceTrackEngine.track(
                segment: camera.url, start: camera.record.startHostTime, detector: detector, progress: { _ in })

            let times = try await presentationTimes(of: camera.url)
            #expect(times.count == 30)
            // The first frame at or after each 100 ms of the segment.
            let expected = try (0..<10).map { k in
                try unwrap(times.first { $0 >= Int64(k) * 100_000_000 }, "a frame after \(k * 100) ms")
            }
            #expect(track.samples.map(\.t) == expected.map { HostTime(nanoseconds: camera.record.startHostTime.nanoseconds + UInt64($0)) })
            #expect(detector.calls.count == 10)
            #expect(track.algorithm == "faceTrack-1")
            #expect(track.frameSize == [640, 360])
            #expect(track.samples.allSatisfy { $0.face == nil })
        }
    }

    @Test func faceTrackKeepsTheLargestFaceTopLeft() async throws {
        try await withTemporaryDirectory { dir in
            let camera = try await cameraSegment(in: dir, seconds: 0.5)
            // In Vision's coordinates: the origin at the bottom left, y going up.
            let small = NormalizedRect(x: 0.125, y: 0.125, width: 0.125, height: 0.125)
            let large = NormalizedRect(x: 0.5, y: 0.25, width: 0.25, height: 0.5)
            let partlyOut = NormalizedRect(x: 0.75, y: -0.25, width: 0.5, height: 0.5)
            let detector = ScriptedFaces { call in
                switch call {
                case 1: [small, large]
                case 2: []
                case 3: [partlyOut, small]
                default: [large, small]
                }
            }
            let track = try await FaceTrackEngine.track(
                segment: camera.url, start: camera.record.startHostTime, detector: detector, progress: { _ in })

            #expect(track.samples.count == 5)
            #expect(track.samples.map(\.face) == [
                NormalizedRect(x: 0.5, y: 0.25, width: 0.25, height: 0.5),
                nil,
                // Held to the frame: its part inside is larger than the small face.
                NormalizedRect(x: 0.75, y: 0.75, width: 0.25, height: 0.25),
                NormalizedRect(x: 0.5, y: 0.25, width: 0.25, height: 0.5),
                NormalizedRect(x: 0.5, y: 0.25, width: 0.25, height: 0.5),
            ])
        }
    }

    @Test func faceTrackStopsWhenCancelled() async throws {
        try await withTemporaryDirectory { dir in
            let camera = try await cameraSegment(in: dir, seconds: 2)
            let reached = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let detector = ScriptedFaces { call in
                if call == 3 {
                    reached.signal()
                    release.wait()
                }
                return []
            }
            let task = Task {
                try await FaceTrackEngine.track(segment: camera.url, start: camera.record.startHostTime, detector: detector, progress: { _ in })
            }
            let arrived = try await offThePool { reached.wait(timeout: .now() + 120) == .success }
            try #require(arrived)
            task.cancel()
            release.signal()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(detector.calls.count == 3)
        }
    }

    @Test(.enabled(if: ImageAnalysisCondition.visionIsAvailable))
    func realVisionFindsNoFaceInFramesWithoutOne() async throws {
        try await withTemporaryDirectory { dir in
            let camera = try await cameraSegment(in: dir, seconds: 0.5)
            let track = try await FaceTrackEngine.track(
                segment: camera.url, start: camera.record.startHostTime, detector: VisionFaceDetector(), progress: { _ in })
            #expect(track.samples.count == 5)
            #expect(track.samples.allSatisfy { $0.face == nil })
        }
    }
}

/// A detector that answers each call (numbered from 1) with what `answer` says, and counts them.
private struct ScriptedFaces: FaceDetector {
    let calls = Calls()
    let answer: @Sendable (Int) -> [NormalizedRect]

    init(_ answer: @escaping @Sendable (Int) -> [NormalizedRect]) {
        self.answer = answer
    }

    func faces(in frame: CVPixelBuffer) throws -> [NormalizedRect] {
        answer(calls.next())
    }
}
