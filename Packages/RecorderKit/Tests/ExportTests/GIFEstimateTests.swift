// SPDX-License-Identifier: GPL-3.0-or-later
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing

// The export sheet's estimate and preview (1c design §7.3): stretches of the range really encoded, never a formula.
// Serialized like GIFExporterTests: two renderers evaluating a smoothed cursor at once trip TSan in CursorPath.

private let second: Int64 = 1_000_000_000

private func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// A take of `seconds` of display 1 with the cursor always moving (the frame changes every time).
private func movingTake(in dir: URL, seconds: Double) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: "Estimate")
    try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: seconds)])
    try builder.addEvents((0..<Int(seconds * 120)).map { i in
        let phase = Double(i % 120) / 120
        return InputEvent(t: at(Double(i) / 120), kind: .cursor(x: 40 + 560 * (phase < 0.5 ? 2 * phase : 2 - 2 * phase), y: 60 + 20 * phase))
    })
    return try builder.write()
}

private func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result(catching: body)) }.start()
    }
}

@Suite(.serialized) struct GIFEstimateTests {
    @Test func samplesAreSpreadOrTheWholeRange() {
        let long = GIFEstimate.sampleRanges(ExportRange(start: 0, end: 60 * second))
        #expect(long.count == 8)
        #expect(long.first == ExportRange(start: 0, end: second))
        #expect(long.last?.end == 60 * second)
        #expect(long.allSatisfy { $0.end - $0.start == second })
        #expect(zip(long, long.dropFirst()).allSatisfy { $0.start < $1.start && $0.end <= $1.start + second })
        let offset = GIFEstimate.sampleRanges(ExportRange(start: 5 * second, end: 25 * second))
        #expect(offset.first?.start == 5 * second && offset.last?.end == 25 * second)
        let short = ExportRange(start: 0, end: 6 * second)
        #expect(GIFEstimate.sampleRanges(short) == [short])
        let eight = ExportRange(start: 0, end: 8 * second)
        #expect(GIFEstimate.sampleRanges(eight) == [eight])
    }

    @Test func previewStartsAtThePlayheadInsideTheRange() {
        let range = ExportRange(start: 10 * second, end: 30 * second)
        #expect(GIFEstimate.previewRange(range, playhead: 15 * second) == ExportRange(start: 15 * second, end: 18 * second))
        #expect(GIFEstimate.previewRange(range, playhead: 29 * second) == ExportRange(start: 29 * second, end: 30 * second))
        #expect(GIFEstimate.previewRange(range, playhead: 5 * second) == ExportRange(start: 10 * second, end: 13 * second))
        #expect(GIFEstimate.previewRange(range, playhead: 30 * second) == ExportRange(start: 10 * second, end: 13 * second))
        let tiny = ExportRange(start: 0, end: second)
        #expect(GIFEstimate.previewRange(tiny, playhead: 0) == tiny)
    }

    @Test func roundsToTwoSignificantDigits() {
        #expect(GIFEstimate.roundedToTwoDigits(3_141_592) == 3_100_000)
        #expect(GIFEstimate.roundedToTwoDigits(987) == 990)
        #expect(GIFEstimate.roundedToTwoDigits(12_345_678) == 12_000_000)
        #expect(GIFEstimate.roundedToTwoDigits(99) == 99)
        #expect(GIFEstimate.roundedToTwoDigits(0) == 0)
    }

    @Test func warningsFollowTheThresholds() {
        #expect(GIFEstimate.warnings(bytes: 1_000_000, seconds: 61) == [.longerThanAMinute])
        #expect(GIFEstimate.warnings(bytes: 1_000_000, seconds: 60).isEmpty)
        #expect(GIFEstimate.warnings(bytes: 11_000_000, seconds: 30) == [.over10MB])
        #expect(GIFEstimate.warnings(bytes: 51_000_000, seconds: 30) == [.over10MB, .over50MB])
    }

    @Test func previewIsARealGIF() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await movingTake(in: dir, seconds: 4)
            var document = EditDocument.legacy(for: project)
            document.frameRate = 30
            let range = ExportRange.whole(TimeMap(sequence: document.sequence))
            let settings = GIFSettings(longSide: 480, fps: 15, range: range)
            let data = try await GIFEstimate.preview(project: project, document: document, settings: settings, playhead: second / 2)
            let frames = GIFTestDecoder.frames(data)
            #expect(!frames.isEmpty)
            #expect(frames.map(\.delay).reduce(0, +) == 300)
            #expect(GIFEstimate.duration(of: data) == 3)
            // Only what is left of the range when the playhead is near its end.
            let tail = try await GIFEstimate.preview(project: project, document: document, settings: settings, playhead: 3 * second)
            #expect(GIFTestDecoder.frames(tail).map(\.delay).reduce(0, +) == 100)
        }
    }

    @Test func estimateReusesThePreviewAsASample() async throws {
        let settings = GIFSettings(range: ExportRange(start: 0, end: 60 * second))
        let gif = try await withTemporaryDirectory { dir -> Data in
            let project = try await movingTake(in: dir, seconds: 1)
            let document = EditDocument.legacy(for: project)
            return try await GIFEstimate.preview(
                project: project, document: document,
                settings: GIFSettings(longSide: 480, range: .whole(TimeMap(sequence: document.sequence))), playhead: 0)
        }
        let calls = Mutex(0)
        let without = try await GIFEstimate.estimate(settings: settings, preview: nil) { _ in
            calls.withLock { $0 += 1 }
            return Data(count: 1000)
        }
        #expect(calls.withLock { $0 } == 8)
        #expect(without.bytes == 1_000 * 60 && without.seconds == 60 && without.frames == 900 && without.warnings.isEmpty)
        calls.withLock { $0 = 0 }
        // A real 1 s GIF (not 3 s), so its length is read from the file itself.
        let with = try await GIFEstimate.estimate(settings: settings, preview: gif) { _ in
            calls.withLock { $0 += 1 }
            return Data(count: 1000)
        }
        #expect(calls.withLock { $0 } == 7)
        #expect(with.seconds == 60)
    }

    @Test func aShortRangeIsEncodedWhole() async throws {
        let settings = GIFSettings(range: ExportRange(start: 0, end: 6 * second))
        let seen = Mutex<[ExportRange]>([])
        let result = try await GIFEstimate.estimate(settings: settings, preview: Data(count: 10)) { range in
            seen.withLock { $0.append(range) }
            return Data(count: 2000)
        }
        #expect(seen.withLock { $0 } == [settings.range])
        #expect(result.bytes == 2000 && result.frames == 90)
    }

    @Test func estimateCanBeCancelled() async throws {
        let settings = GIFSettings(range: ExportRange(start: 0, end: 60 * second))
        let task = Task {
            try await GIFEstimate.estimate(settings: settings, preview: nil) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return Data(count: 10)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
    func firstEstimateAndPreviewAreQuick() async throws {
        // TOMA_BENCH_TAKE: a `.toma` recorded by `recorder-dev synth-record --width 3840 --height 2160 --fps 60 --camera
        // --duration 60`; without it, a 60 s take of the test fixtures (640 × 360). The numbers of the design's target are
        // those of `recorder-dev bench-gif --synthetic --estimate`, with its all-on document, in release.
        try await withTemporaryDirectory { dir in
            let project: LoadedProject
            if let path = ProcessInfo.processInfo.environment["TOMA_BENCH_TAKE"] {
                project = try LoadedProject.load(URL(fileURLWithPath: path, isDirectory: true))
            } else {
                project = try await movingTake(in: dir, seconds: 60)
            }
            var document = EditDocument.legacy(for: project)
            document.frameRate = 60
            document.style.background = .wallpaper("aurora-1")
            let settings = GIFSettings(longSide: 800, range: .whole(TimeMap(sequence: document.sequence)))
            let clock = ContinuousClock()
            let result = try await clock.measure {
                let preview = try await GIFEstimate.preview(project: project, document: document, settings: settings, playhead: 20 * second)
                let estimate = try await GIFEstimate.estimate(project: project, document: document, settings: settings, preview: preview)
                print("estimate: \(estimate.bytes) bytes, \(estimate.frames) frames, \(estimate.warnings); preview \(preview.count) bytes")
            }
            print("firstEstimateAndPreviewAreQuick: \(result)")
            #expect(result <= .milliseconds(600))
        }
    }
}
