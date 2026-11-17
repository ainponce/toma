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
        let without = try await GIFEstimate.estimate(settings: settings, preview: nil, first: nil) { _ in
            calls.withLock { $0 += 1 }
            return Data(count: 1000)
        }
        #expect(calls.withLock { $0 } == 8)
        // 1000 bytes a stretch of 15 frames, none a GIF whose first image this reads: each stretch whole, 8 000 bytes over
        // 120 frames, times 900.
        #expect(without.bytes == 60_000 && without.seconds == 60 && without.frames == 900 && without.warnings.isEmpty)
        calls.withLock { $0 = 0 }
        // A real 1 s GIF (not 3 s), so its length is read from the file itself.
        let with = try await GIFEstimate.estimate(settings: settings, preview: gif, first: nil) { _ in
            calls.withLock { $0 += 1 }
            return Data(count: 1000)
        }
        #expect(calls.withLock { $0 } == 7)
        #expect(with.seconds == 60)
    }

    @Test func firstEstimateComesFromThePreviewAloneNoExtraEncodes() async throws {
        let gif = try await withTemporaryDirectory { dir -> Data in
            let project = try await movingTake(in: dir, seconds: 1)
            let document = EditDocument.legacy(for: project)
            return try await GIFEstimate.preview(
                project: project, document: document,
                settings: GIFSettings(longSide: 480, range: .whole(TimeMap(sequence: document.sequence))), playhead: 0)
        }
        let length = try #require(GIFEstimate.duration(of: gif))
        let settings = GIFSettings(range: ExportRange(start: 0, end: 60 * second))
        let calls = Mutex(0)
        let firsts = Mutex<[(result: GIFEstimateResult, calls: Int)]>([])
        let final = try await GIFEstimate.estimate(
            settings: settings, preview: gif, first: { result in firsts.withLock { $0.append((result, calls.withLock { $0 })) } }
        ) { _ in
            calls.withLock { $0 += 1 }
            return Data(count: gif.count)
        }
        let first = try #require(firsts.withLock { $0 }.first)
        #expect(firsts.withLock { $0 }.count == 1)
        #expect(first.calls == 0, "the first estimate is given before any other stretch is encoded")
        #expect(calls.withLock { $0 } == 7)
        // The preview's first image once, and its bytes after it per frame times the 899 frames after the first.
        let firstImage = try #require(GIFEstimate.firstImageEnd(of: gif))
        let previewFrames = Int((length * 15).rounded())
        let expected = GIFEstimate.roundedToTwoDigits(
            Int64((Double(firstImage) + Double(gif.count - firstImage) * 899 / Double(previewFrames - 1)).rounded()))
        #expect(first.result.bytes == expected && first.result.seconds == 60 && first.result.frames == 900)
        #expect(first.result.warnings == GIFEstimate.warnings(bytes: expected, seconds: 60))
        // Without a preview, or on a short range, there is no first estimate.
        var none = 0
        _ = try await GIFEstimate.estimate(settings: settings, preview: nil, first: { _ in none += 1 }) { _ in Data(count: 10) }
        _ = try await GIFEstimate.estimate(
            settings: GIFSettings(range: ExportRange(start: 0, end: 5 * second)), preview: gif, first: { _ in none += 1 }
        ) { _ in Data(count: 10) }
        #expect(none == 0)
    }

    @Test func theStreamEndsWithTheSameEstimateAndOneRendererGivesTheSameBytes() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await movingTake(in: dir, seconds: 10)
            var document = EditDocument.legacy(for: project)
            document.frameRate = 30
            let range = ExportRange.whole(TimeMap(sequence: document.sequence))
            let settings = GIFSettings(longSide: 480, fps: 15, range: range)
            let preview = try await GIFEstimate.preview(project: project, document: document, settings: settings, playhead: 0)
            let plain = try await GIFEstimate.estimate(project: project, document: document, settings: settings, preview: preview)
            var seen: [GIFEstimateResult] = []
            for try await result in GIFEstimate.estimates(project: project, document: document, settings: settings, preview: preview) {
                seen.append(result)
            }
            #expect(seen.count == 2)
            #expect(seen.last == plain)
            #expect(seen.first?.frames == plain.frames && seen.first?.seconds == plain.seconds)
            // One renderer for several stretches: the bytes of each are those of a renderer of its own.
            let exporter = GIFExporter(project: project, document: document, settings: settings)
            let renderer = try exporter.makeRenderer()
            for sample in GIFEstimate.sampleRanges(range).prefix(3) {
                let shared = try await exporter.encodeInMemory(range: sample, renderer: renderer)
                let own = try await exporter.encodeInMemory(range: sample)
                #expect(shared == own)
            }
        }
    }

    @Test func cancellingTheStreamStopsIt() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await movingTake(in: dir, seconds: 10)
            let document = EditDocument.legacy(for: project)
            let settings = GIFSettings(longSide: 480, range: .whole(TimeMap(sequence: document.sequence)))
            let task = Task {
                var count = 0
                for try await _ in GIFEstimate.estimates(project: project, document: document, settings: settings, preview: nil) { count += 1 }
                return count
            }
            task.cancel()
            let outcome = await task.result
            if case .success(let count) = outcome { #expect(count == 0) }
        }
    }

    @Test func aShortRangeIsEncodedWhole() async throws {
        let settings = GIFSettings(range: ExportRange(start: 0, end: 6 * second))
        let seen = Mutex<[ExportRange]>([])
        let result = try await GIFEstimate.estimate(settings: settings, preview: Data(count: 10), first: nil) { range in
            seen.withLock { $0.append(range) }
            return Data(count: 2000)
        }
        #expect(seen.withLock { $0 } == [settings.range])
        #expect(result.bytes == 2000 && result.frames == 90)
    }

    /// A still GIF is a whole first image and next to nothing after: each 1 s stretch has one first image of its own, and
    /// the estimate pays it once, not once a second. A range encoded whole is its own size, to the byte.
    @Test func theFirstImageIsPaidOnce() {
        let still = [GIFEstimate.Stretch](repeating: GIFEstimate.Stretch(bytes: 1_112, firstImage: 1_000, frames: 15), count: 8)
        // 1 000 + 896 × 899 / (8 × 14) = 8 192; per second of every stretch it would be 8 896 / 8 × 60 = 66 720.
        #expect(GIFEstimate.estimatedSize(still, frames: 900) == 8_192)
        #expect(GIFEstimate.estimatedBytes(still, frames: 900) == 8_200)
        let mixed = [
            GIFEstimate.Stretch(bytes: 3_840, firstImage: 1_200, frames: 45),
            GIFEstimate.Stretch(bytes: 1_640, firstImage: 800, frames: 15),
        ]
        // (1 200 + 800) / 2 + (2 640 + 840) × 299 / (44 + 14) = 18 940.
        #expect(GIFEstimate.estimatedSize(mixed, frames: 300) == 18_940)
        #expect(GIFEstimate.estimatedSize([GIFEstimate.Stretch(bytes: 2_345, firstImage: 1_000, frames: 90)], frames: 90) == 2_345)
    }

    /// A stretch whose first image cannot be split from the rest counts whole, its bytes per frame: a range of one frame
    /// is the bytes of its GIF (the trailer too), stretches not read as GIFs are their total bytes, and one not read
    /// among others read does not count as a first image of 0 bytes. Never 0 when something was encoded.
    @Test func aStretchThatCannotBeSplitCountsWhole() {
        #expect(GIFEstimate.estimatedSize([GIFEstimate.Stretch(bytes: 1_234, firstImage: 1_233, frames: 1)], frames: 1) == 1_234)
        let unread = [GIFEstimate.Stretch](repeating: GIFEstimate.Stretch(bytes: 1_000, firstImage: nil, frames: 15), count: 8)
        #expect(GIFEstimate.estimatedSize(unread, frames: 900) == 60_000)
        let some = [
            GIFEstimate.Stretch(bytes: 1_640, firstImage: 800, frames: 15), GIFEstimate.Stretch(bytes: 500, firstImage: nil, frames: 15),
        ]
        // 800, the first image read (not their mean with 0), + 840 × 99 / 14.
        #expect(GIFEstimate.estimatedSize(some, frames: 100) == 6_740)
        #expect(GIFEstimate.estimatedSize([GIFEstimate.Stretch(bytes: 70, firstImage: nil, frames: 1)], frames: 1) == 70)
        #expect(GIFEstimate.estimatedBytes([GIFEstimate.Stretch(bytes: 70, firstImage: nil, frames: 1)], frames: 1) == 70)
    }

    /// The first image ends where the second's graphic control begins, past the header, the loop extension and its own
    /// control, descriptor, colour table and data; anything else is not read.
    @Test func firstImageEndsBeforeTheSecond() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appending(path: "two.gif")
            let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o644)
            try #require(fd >= 0)
            defer { close(fd) }
            var writer = try GIFWriter(fileDescriptor: fd, width: 300, height: 2, loops: true)
            func coded(_ index: UInt8, count: Int) throws -> [UInt8] {
                try [UInt8](repeating: index, count: count).withUnsafeBufferPointer { try LZWEncoder.encode($0, minimumCodeSize: 2) }
            }
            let first = GIFImageBlock(
                x: 0, y: 0, width: 300, height: 2, palette: [SIMD3(0, 0, 0), SIMD3(255, 255, 255), SIMD3(9, 9, 9)],
                transparentIndex: nil, delay: 7, minimumCodeSize: 2, data: try coded(1, count: 600))
            try writer.write(first)
            try writer.write(GIFImageBlock(
                x: 1, y: 1, width: 1, height: 1, palette: [SIMD3(0, 0, 0), SIMD3(255, 255, 255)], transparentIndex: 2, delay: 6,
                minimumCodeSize: 2, data: try coded(0, count: 1)))
            try writer.finish()
            let gif = try Data(contentsOf: url)
            // Header and screen 13, loop 19; the first image: control 8, descriptor 10, a table of 4 colours 12, code size
            // 1, its data in sub-blocks of up to 255 bytes and the terminator.
            let subBlocks = (first.data.count + 254) / 255
            let end = 13 + 19 + 8 + 10 + 12 + 1 + first.data.count + subBlocks + 1
            #expect(GIFEstimate.firstImageEnd(of: gif) == end)
            #expect(gif[end] == 0x21 && gif[end + 1] == 0xF9, "the second image's graphic control")
            #expect(GIFEstimate.firstImageEnd(of: gif.prefix(end - 1)) == nil, "cut inside the first image")
            #expect(GIFEstimate.firstImageEnd(of: Data(count: 1_000)) == nil)
        }
    }

    @Test func estimateCanBeCancelled() async throws {
        let settings = GIFSettings(range: ExportRange(start: 0, end: 60 * second))
        let task = Task {
            try await GIFEstimate.estimate(settings: settings, preview: nil, first: nil) { _ in
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
            let start = clock.now
            let preview = try await GIFEstimate.preview(project: project, document: document, settings: settings, playhead: 20 * second)
            let previewed = start.duration(to: clock.now)
            var firstAt: Duration?
            var last: GIFEstimateResult?
            for try await estimate in GIFEstimate.estimates(project: project, document: document, settings: settings, preview: preview) {
                if firstAt == nil { firstAt = start.duration(to: clock.now) }
                last = estimate
            }
            let refined = start.duration(to: clock.now)
            let first = try #require(firstAt)
            print("firstEstimateAndPreviewAreQuick: preview \(previewed), first estimate \(first), refined \(refined); \(String(describing: last))")
            // The design's bound is for the first estimate of a 4K60 take; the fallback take in Debug only prints.
            if ProcessInfo.processInfo.environment["TOMA_BENCH_TAKE"] != nil {
                #expect(first <= .milliseconds(600))
            }
        }
    }
}
