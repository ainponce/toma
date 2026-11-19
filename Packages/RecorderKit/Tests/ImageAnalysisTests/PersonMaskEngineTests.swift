// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ImageAnalysis
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing

// Every test here runs in `make tsan`.

@Suite struct PersonMaskEngineTests {
    @Test func maskVideoHasTheCameraFramesTimes() async throws {
        try await withTemporaryDirectory { dir in
            let camera = try await cameraSegment(in: dir, seconds: 2)
            let url = dir.appending(path: "mask.mov")
            // 255 × 143: the movie rounds each side to an even number.
            let segmenter = HalfMask(width: 255, height: 143)
            try await PersonMaskEngine.write(segment: camera.url, to: url, segmenter: segmenter, progress: { _ in })

            let cameraTimes = try await presentationTimes(of: camera.url)
            #expect(cameraTimes.count == 60)
            #expect(try await presentationTimes(of: url) == cameraTimes)
            #expect(segmenter.calls.count == 60)

            let asset = AVURLAsset(url: url)
            let track = try unwrap(try await asset.loadTracks(withMediaType: .video).first, "the mask's video track")
            let (size, formats) = try await track.load(.naturalSize, .formatDescriptions)
            #expect(size == CGSize(width: 256, height: 144))
            #expect(formats.map(\.mediaSubType.rawValue) == [kCMVideoCodecType_HEVC])
            // It ends where the camera ends.
            let cameraEnd = try await videoMediaEnd(of: camera.url)
            #expect(abs(try await videoMediaEnd(of: url) - cameraEnd) < 0.001)
        }
    }

    @Test func maskVideoReadsBackAsTheMask() async throws {
        try await withTemporaryDirectory { dir in
            let camera = try await cameraSegment(in: dir, seconds: 2)
            let url = dir.appending(path: "mask.mov")
            try await PersonMaskEngine.write(
                segment: camera.url, to: url, segmenter: HalfMask(width: 256, height: 144), progress: { _ in })

            let reds = try await redsAtQuarters(of: url)
            #expect(reds.count == 60)
            for (left, right) in reds {
                #expect(left >= 240)
                #expect(right <= 15)
            }
        }
    }

    @Test func cancellingStopsWithinAFrameAndLeavesNoTemporary() async throws {
        try await withTemporaryDirectory { dir in
            let camera = try await cameraSegment(in: dir, seconds: 2)
            let folder = dir.appending(path: "masks", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: ".mask.tmp.mov")
            let reached = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let segmenter = HalfMask(width: 256, height: 144) { call in
                guard call == 10 else { return }
                reached.signal()
                release.wait()
            }
            let task = Task {
                try await PersonMaskEngine.write(segment: camera.url, to: url, segmenter: segmenter, progress: { _ in })
            }
            let arrived = try await offThePool { reached.wait(timeout: .now() + 120) == .success }
            try #require(arrived)
            task.cancel()
            release.signal()

            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(segmenter.calls.count <= 11)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [])
        }
    }

    @Test func somethingAtTheDestinationIsLeftAlone() async throws {
        try await withTemporaryDirectory { dir in
            let camera = try await cameraSegment(in: dir, seconds: 1)
            let url = dir.appending(path: "mask.mov")
            try Data("mine".utf8).write(to: url)
            let segmenter = HalfMask(width: 256, height: 144)
            await #expect(throws: ImageAnalysisError.self) {
                try await PersonMaskEngine.write(segment: camera.url, to: url, segmenter: segmenter, progress: { _ in })
            }
            #expect(try Data(contentsOf: url) == Data("mine".utf8))
            #expect(segmenter.calls.count == 0)
        }
    }

    @Test func aSegmentThatIsNotAMovieIsUnreadable() async throws {
        try await withTemporaryDirectory { dir in
            let segment = dir.appending(path: "seg-0001.mov")
            try Data(repeating: 0x5A, count: 4096).write(to: segment)
            let url = dir.appending(path: "mask.mov")
            await #expect {
                try await PersonMaskEngine.write(
                    segment: segment, to: url, segmenter: HalfMask(width: 256, height: 144), progress: { _ in })
            } throws: { error in
                if case ImageAnalysisError.unreadable = error { true } else { false }
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func progressGoesUpToTheWhole() async throws {
        try await withTemporaryDirectory { dir in
            let camera = try await cameraSegment(in: dir, seconds: 1)
            let reports = Reports()
            try await PersonMaskEngine.write(
                segment: camera.url, to: dir.appending(path: "mask.mov"), segmenter: HalfMask(width: 256, height: 144),
                progress: { reports.append($0) })
            let all = reports.all
            #expect(all.count >= 30)
            #expect(zip(all, all.dropFirst()).allSatisfy { $0 <= $1 })
            #expect(all.last == 1)
        }
    }

    @Test(.enabled(if: ImageAnalysisCondition.visionIsAvailable))
    func realVisionMakesAMask() async throws {
        try await withTemporaryDirectory { dir in
            let camera = try await cameraSegment(in: dir, seconds: 1)
            let url = dir.appending(path: "mask.mov")
            try await PersonMaskEngine.write(segment: camera.url, to: url, segmenter: VisionPersonSegmenter(), progress: { _ in })

            #expect(try await presentationTimes(of: url) == (try await presentationTimes(of: camera.url)))
            let asset = AVURLAsset(url: url)
            let track = try unwrap(try await asset.loadTracks(withMediaType: .video).first, "the mask's video track")
            let size = try await track.load(.naturalSize)
            #expect(size.width > 0 && size.height > 0)
            #expect(Int(size.width) % 2 == 0 && Int(size.height) % 2 == 0)
        }
    }

    /// The speed of `personMask-1` against the camera's own time (phase 2 design §13: at least twice real time with a
    /// camera of 30 fps): 10 s of 1920 × 1080 and of 1280 × 720 at 30 fps, each in at most 5 s.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1" && ImageAnalysisCondition.visionIsAvailable))
    func masksAreTwiceRealTime() async throws {
        for (width, height) in [(1920, 1080), (1280, 720)] {
            try await withTemporaryDirectory { dir in
                let camera = try await cameraSegment(in: dir, seconds: 10, width: width, height: height)
                let url = dir.appending(path: "mask.mov")
                let clock = ContinuousClock()
                let elapsed = try await clock.measure {
                    try await PersonMaskEngine.write(
                        segment: camera.url, to: url, segmenter: VisionPersonSegmenter(), progress: { _ in })
                }
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                print("personMask-1, 10 s of \(width) × \(height) at 30 fps: \(String(format: "%.2f", seconds)) s, \(String(format: "%.1f", 10 / seconds)) × real time")
                #expect(seconds <= 5)
            }
        }
    }
}

// MARK: - Fixtures shared by the tests of the camera's engines

/// Where the camera segments of these tests start.
let cameraStart = HostTime(nanoseconds: 7_000_000_000_000)

/// A camera segment of `seconds` at `framesPerSecond`, written the way the recorder does (`TakeBuilder`): its file and
/// its record.
func cameraSegment(
    in dir: URL, seconds: Double, framesPerSecond: Int = 30, width: Int = 640, height: Int = 360
) async throws -> (url: URL, record: SegmentRecord) {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: "camera", kind: .camera, source: TrackSource(name: "Camera"),
        segments: [
            VideoSegmentSpec(start: cameraStart, seconds: seconds, framesPerSecond: framesPerSecond, width: width, height: height)
        ])
    let project = try builder.write()
    let record = try unwrap(project.take.track("camera")?.segments.first, "the camera's segment")
    return (project.package.fileURL(record.file), record)
}

/// The presentation time of every sample of the movie's video track, in nanoseconds of its file, as stored.
func presentationTimes(of url: URL) async throws -> [Int64] {
    let asset = AVURLAsset(url: url)
    let track = try unwrap(try await asset.loadTracks(withMediaType: .video).first, "a video track in \(url.lastPathComponent)")
    return try await readTrack(track, of: asset, outputSettings: nil, into: [Int64]()) { times, sample in
        // Not the reader's markers, which carry no sample.
        guard CMSampleBufferGetNumSamples(sample) > 0 else { return }
        for timing in try sample.sampleTimingInfos() where timing.presentationTimeStamp.isNumeric {
            times.append(Int64(HostTime(timing.presentationTimeStamp).nanoseconds))
        }
    }
}

/// The red of each decoded frame of the movie at a quarter and at three quarters of its width, halfway down.
private func redsAtQuarters(of url: URL) async throws -> [(UInt8, UInt8)] {
    let asset = AVURLAsset(url: url)
    let track = try unwrap(try await asset.loadTracks(withMediaType: .video).first, "a video track in \(url.lastPathComponent)")
    let settings: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let reds = try await readTrack(track, of: asset, outputSettings: settings, into: [[UInt8]]()) { reds, sample in
        guard let frame = CMSampleBufferGetImageBuffer(sample) else { return }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let width = CVPixelBufferGetWidth(frame)
        let row = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
            + CVPixelBufferGetHeight(frame) / 2 * CVPixelBufferGetBytesPerRow(frame)
        reds.append([row[width / 4 * 4 + 2], row[width * 3 / 4 * 4 + 2]])
    }
    return reds.map { ($0[0], $0[1]) }
}

/// A one-component 8-bit buffer of `width × height`, each pixel `value(x, y)`.
func oneComponentBuffer(width: Int, height: Int, _ value: (Int, Int) -> UInt8) throws -> CVPixelBuffer {
    var made: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_OneComponent8, nil, &made) == kCVReturnSuccess,
          let buffer = made
    else { throw TestSupportError.failed("no \(width) × \(height) buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let row = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        for x in 0..<width { base[y * row + x] = value(x, y) }
    }
    return buffer
}

/// How many times something was called.
final class Calls: Sendable {
    private let value = Mutex(0)

    /// One more; its number, from 1.
    func next() -> Int { value.withLock { $0 += 1; return $0 } }
    var count: Int { value.withLock { $0 } }
}

/// A segmenter that finds the person in the left half of every frame: a mask of `width × height`, 255 on the left and
/// 0 on the right. `onCall` is told each call's number, from 1, before it answers.
private struct HalfMask: PersonSegmenter {
    let width: Int
    let height: Int
    let calls = Calls()
    var onCall: (@Sendable (Int) -> Void)?

    init(width: Int, height: Int, onCall: (@Sendable (Int) -> Void)? = nil) {
        self.width = width
        self.height = height
        self.onCall = onCall
    }

    func mask(of frame: CVPixelBuffer) throws -> CVPixelBuffer {
        // Counted first: `onCall?(…)` would not evaluate its argument without one.
        let call = calls.next()
        onCall?(call)
        let half = width / 2
        return try oneComponentBuffer(width: width, height: height) { x, _ in x < half ? 255 : 0 }
    }
}

/// What a progress closure was told, in order.
private final class Reports: Sendable {
    private let values = Mutex<[Double]>([])

    func append(_ value: Double) { values.withLock { $0.append(value) } }
    var all: [Double] { values.withLock { $0 } }
}
