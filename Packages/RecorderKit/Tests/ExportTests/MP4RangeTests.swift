// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import CryptoKit
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Render
import Synchronization
import SyntheticCapture
import Testing

// The MP4 export of a range of the edited video (1c design §7.1): frame `n` at `range.frameTime(n, fps:)`, and the mix
// of output `[start, end)` from frame `round(start × 48 000 / 10⁹)` with no fade of its own at the range's edges. Without
// a range, or with the whole one, it is the export of 1b.

private func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// Clip `number` of the take over the source seconds `[from, to)` from `base`, at `speed`.
private func clip(_ number: Int, from: Double, to: Double, speed: Double = 1) -> Clip {
    Clip(id: String(format: "c-%08x", number), take: takeID, start: at(from), end: at(to), speed: speed)
}

/// What a test's frame sink saw: each frame's index and the SHA-256 of its bytes, and the bytes of every frame.
private final class SeenFrames: Sendable {
    struct Frame: Equatable, Sendable {
        var index: Int
        var hash: String
    }

    private let seen = Mutex<(frames: [Frame], bytes: [Int: [UInt8]])>(([], [:]))

    var frames: [Frame] { seen.withLock { $0.frames } }
    var bytes: [Int: [UInt8]] { seen.withLock { $0.bytes } }

    var sink: MP4Exporter.FrameSink {
        { [self] index, pixelBuffer in
            let bytes = packedBytes(of: pixelBuffer)
            seen.withLock { seen in
                seen.frames.append(Frame(index: index, hash: sha256(bytes)))
                seen.bytes[index] = bytes
            }
        }
    }
}

private func sha256(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

/// A take of 7 s: the screen (its colour telling the source frame), the microphone's 440 Hz sine with a 50 ms burst of
/// 1000 Hz at 3 s, and the cursor going across.
private func take(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: "Range")
    try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 7)])
    let burst = toneBurst(at: at(3), start: base, skewPPM: 0, frequency: 1000, channels: 1)
    try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 7, transform: burst)])
    try builder.addEvents((0..<(7 * 60)).map { i in
        InputEvent(t: at(Double(i) / 60), kind: .cursor(x: 20 + Double(i % 120) * 5, y: 180))
    })
    return try builder.write()
}

/// The take's edit: 0 to 1 s and 1.5 to 6.5 s of it, 6 s of output.
private func edit(of project: LoadedProject) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.sequence = [clip(1, from: 0, to: 1), clip(2, from: 1.5, to: 6.5)]
    return document
}

/// Exports `range` of `document` of `project` (all of it for `nil`) to `dir/<name>.mp4`, its frames seen by `seen`;
/// returns the MP4 and the summary.
@discardableResult
private func export(
    _ project: LoadedProject, _ document: EditDocument, settings: ExportSettings, range: ExportRange?, to dir: URL, name: String,
    seen: SeenFrames? = nil
) async throws -> (url: URL, summary: ExportSummary) {
    let destination = dir.appending(path: "\(name).mp4")
    let summary = try await MP4Exporter(project: project, document: document, settings: settings, range: range, frameSink: seen?.sink)
        .export(to: destination) { _ in }
    return (destination, summary)
}

/// Every decoded frame of `url`, in presentation order.
private func decodedFrames(of url: URL) async throws -> [DecodedFrame] {
    try await readVideoFrames(of: url, into: [DecodedFrame]()) { $0.append($1) }
}

/// Whether `a` and `b` are the same audio decoded: from the same time, as many samples, each within 10⁻⁵ (−100 dB).
///
/// Not bit for bit: under load, two exports of the same samples have decoded a few ulps apart (2.4 × 10⁻⁷ at most), while
/// one sample of shift moves the take's 440 Hz sine by up to 0.014. What the exports give the encoder is compared bit for
/// bit instead (`MP4Exporter.mixSamples`).
private func sameAudioDecoded(_ a: (start: Double, samples: [Float]), _ b: (start: Double, samples: [Float])) -> Bool {
    a.start == b.start && a.samples.count == b.samples.count && zip(a.samples, b.samples).allSatisfy { abs($0 - $1) <= 1e-5 }
}

/// Whether `a` and `b` are the same frames decoded: at the same times, showing the same frames of the screen, alike.
///
/// Not byte for byte: two exports of the same frames can get different encoders (VideoToolbox's hardware one, or its
/// software one when the media engine has no session left, as when many tests export at once), so their bytes differ.
/// What the exports give the encoder is compared byte for byte instead (`SeenFrames`).
private func sameFramesDecoded(_ a: [DecodedFrame], _ b: [DecodedFrame]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { a, b in
        a.time == b.time && paletteIndex(a) == paletteIndex(b) && ssimLuma(a.bytes, b.bytes, width: a.width, height: a.height) >= 0.98
    }
}

/// The source frame the screen of a decoded frame shows (`SampleFactory`'s palette, which repeats every 64 frames), read
/// halfway across and three quarters down, away from the cursor and from the square moving along the top.
private func paletteIndex(_ frame: DecodedFrame) -> Int {
    SampleFactory.frameIndex(nearestTo: pixel(frame.bytes, width: frame.width, x: frame.width / 2, y: frame.height * 3 / 4))
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func rangeExportsOnlyThatPart() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir)
        let document = edit(of: project)
        let size = SIMD2(320, 180)
        let settings = ExportSettings(outputSize: size, framesPerSecond: 30, quality: .high)
        // Output 2 s to 5 s: source 2.5 s to 5.5 s, past the cut.
        let range = ExportRange(start: 2_000_000_000, end: 5_000_000_000)
        let seen = SeenFrames()
        let (destination, summary) = try await export(project, document, settings: settings, range: range, to: dir, name: "range", seen: seen)
        #expect(summary == ExportSummary())

        // 90 frames, each drawn at its time in the range, and appended at its time in the MP4.
        #expect(seen.frames.map(\.index) == Array(0..<90))
        let renderer = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: 30)
        let drawn = try await offThePool {
            try [0, 45, 89].map { try renderer.renderBytes(at: Double(range.frameTime($0, fps: 30)) / 1e9) }
        }
        let atZero = try await offThePool { try renderer.renderBytes(at: 0) }
        #expect(seen.bytes[0] == drawn[0], "frame 0 is the frame at 2 s")
        #expect(seen.bytes[45] == drawn[1], "frame 45 is the frame at 3.5 s")
        #expect(seen.bytes[89] == drawn[2], "frame 89 is the frame at 2 s + 89/30 s")
        #expect(seen.bytes[0] != atZero, "and not the video's first frame")
        let times = try await readVideoFrames(of: destination, into: [Double]()) { $0.append($1.time) }
        #expect(times.count == 90)
        #expect(times.enumerated().allSatisfy { abs($0.element - Double($0.offset) / 30) < 1e-6 }, "\(times)")
        let first = try await videoFrame(of: destination, nearest: 0)
        #expect(ssimLuma(first.bytes, drawn[0], width: size.x, height: size.y) >= 0.98)
        // Source 2.5 s, frame 75 of the screen.
        #expect(paletteIndex(first) == 75 % 64)

        // The audio lasts the 3 s, with the burst at source 3 s, 0.5 s into the range.
        let (start, samples) = try await decodedAudio(of: destination)
        let seconds = start + Double(samples.count) / 48_000
        #expect(abs(seconds - 3) <= 1.0 / 30, "the audio lasts \(seconds) s")
        let onset = try await toneOnset(in: destination, frequency: 1000, near: 0.5, window: 0.2)
        #expect(abs(onset - 0.5) < 0.003, "the burst at \(onset) s")

        // The samples are the whole mix's from 2 s on, 144 000 of them: no fade at the range's edges.
        let whole = try await MP4Exporter.mixSamples(of: project, document: document, framesPerSecond: 30)
        let part = try await MP4Exporter.mixSamples(of: project, document: document, framesPerSecond: 30, range: range)
        #expect(part.count == 144_000)
        #expect(part == Array(whole[96_000..<240_000]))
        // A fade over the first or the last 192 frames would take their RMS down to about 1/√3 of the sine's.
        for edge in [0..<192, 143_808..<144_000] {
            let rms = sqrt(part[edge].reduce(0) { $0 + Double($1) * Double($1) } / 192)
            #expect(abs(rms - 0.25 / 2.0.squareRoot()) < 0.02, "frames \(edge): RMS \(rms), not faded")
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func noRangeIsTodaysExport() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir)
        var document = EditDocument.legacy(for: project)
        // 2.01 s of output: 60 frames at 30 fps (60.3 rounded), though 61 frame times fall before its end.
        document.sequence = [clip(1, from: 0, to: 1), clip(2, from: 1.5, to: 2.51)]
        document.audio.limiter = true
        let timeMap = TimeMap(sequence: document.sequence)
        #expect(timeMap.frameCount(frameRate: 30) == 60)
        #expect(ExportRange.whole(timeMap).frameCount(fps: 30) == 61)
        let settings = ExportSettings(outputSize: [320, 180], framesPerSecond: 30)

        let seen1b = SeenFrames(), seenNil = SeenFrames(), seenWhole = SeenFrames()
        let destination = dir.appending(path: "1b.mp4")
        let summary1b = try await MP4Exporter(project: project, document: document, settings: settings, frameSink: seen1b.sink)
            .export(to: destination) { _ in }
        let (noRange, summaryNil) = try await export(project, document, settings: settings, range: nil, to: dir, name: "nil", seen: seenNil)
        let (whole, summaryWhole) = try await export(
            project, document, settings: settings, range: .whole(timeMap), to: dir, name: "whole", seen: seenWhole)

        #expect(seen1b.frames.map(\.index) == Array(0..<60))
        #expect(seenNil.frames == seen1b.frames, "the same frames drawn")
        #expect(seenWhole.frames == seen1b.frames, "the same frames drawn")
        let decoded1b = try await decodedFrames(of: destination)
        #expect(decoded1b.count == 60)
        #expect(sameFramesDecoded(try await decodedFrames(of: noRange), decoded1b), "the same frames decoded")
        #expect(sameFramesDecoded(try await decodedFrames(of: whole), decoded1b), "the same frames decoded")
        let audio1b = try await decodedAudio(of: destination)
        let audioNil = try await decodedAudio(of: noRange), audioWhole = try await decodedAudio(of: whole)
        #expect(sameAudioDecoded(audioNil, audio1b), "the same audio decoded")
        #expect(sameAudioDecoded(audioWhole, audio1b), "the same audio decoded")
        #expect(summaryNil == summary1b && summaryWhole == summary1b)

        let mix1b = try await MP4Exporter.mixSamples(of: project, document: document, framesPerSecond: 30)
        #expect(mix1b.count == 96_000)
        #expect(try await MP4Exporter.mixSamples(of: project, document: document, framesPerSecond: 30, range: .whole(timeMap)) == mix1b)
    }
}

/// A range that starts off the grid of the export's frames (`TimeMap.frameTime`) is drawn at its own times all the same.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func rangeOffTheGridIsDrawnAtItsOwnTimes() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir)
        let document = edit(of: project)
        let size = SIMD2(320, 180)
        let start: Int64 = 1_234_567_891
        let range = ExportRange(start: start, end: start + TimeMap.frameTime(10, frameRate: 60))
        let seen = SeenFrames()
        try await export(
            project, document, settings: ExportSettings(outputSize: size, framesPerSecond: 60), range: range, to: dir, name: "off", seen: seen)
        #expect(seen.frames.map(\.index) == Array(0..<10))
        let renderer = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: 60)
        let drawn = try await offThePool {
            try (0..<10).map { try renderer.renderBytes(at: Double(range.frameTime($0, fps: 60)) / 1e9) }
        }
        for n in 0..<10 { #expect(seen.bytes[n] == drawn[n], "frame \(n)") }
    }
}

/// A range that lasts less than a frame, or nothing of the video, exports nothing and writes nothing.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func rangeWithoutAFrameIsRefused() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir)
        let document = edit(of: project)
        let folder = dir.appending(path: "out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let settings = ExportSettings(outputSize: [320, 180], framesPerSecond: 30)
        let ranges = [
            ExportRange(start: 2_000_000_000, end: 2_010_000_000),  // 10 ms
            ExportRange(start: 2_000_000_000, end: 2_033_333_332),  // 2 ns short of a frame (1 ns is the marks' rounding)
            ExportRange(start: 2_000_000_000, end: 2_000_000_000),
            ExportRange(start: 3_000_000_000, end: 2_000_000_000),
            ExportRange(start: 6_000_000_000, end: 7_000_000_000),  // after the video's 6 s
        ]
        for range in ranges {
            await #expect(throws: ExportError.nothingToExport, "\(range)") {
                try await MP4Exporter(project: project, document: document, settings: settings, range: range)
                    .export(to: folder.appending(path: "out.mp4")) { _ in }
            }
            await #expect(throws: ExportError.nothingToExport, "\(range)") {
                try await MP4Exporter.mixSamples(of: project, document: document, framesPerSecond: 30, range: range)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        // Marks a frame apart are one frame, though on the grid of 30 fps they are 33 333 333 or 33 333 334 ns apart
        // (frames 60 to 61, and 1 to 2): frame 1 of the second, at 33 333 333 ns, starts 1 ns before its end.
        let oneFrame = [
            ExportRange(start: TimeMap.frameTime(60, frameRate: 30), end: TimeMap.frameTime(61, frameRate: 30)),
            ExportRange(start: TimeMap.frameTime(1, frameRate: 30), end: TimeMap.frameTime(2, frameRate: 30)),
        ]
        #expect(oneFrame.map { $0.end - $0.start } == [33_333_333, 33_333_334])
        for (k, range) in oneFrame.enumerated() {
            let seen = SeenFrames()
            try await export(project, document, settings: settings, range: range, to: folder, name: "one-\(k)", seen: seen)
            #expect(seen.frames.map(\.index) == [0], "\(range)")
            #expect(try await MP4Exporter.mixSamples(of: project, document: document, framesPerSecond: 30, range: range).count == 1_600)
        }
    }
}

/// Marks dragged to the end of a video that is not on the MP4's grid: the range is cut where the export of all of it
/// ends (`TimeMap.exportEnd`, its last whole frame), and what is left is checked, as the export sheet checks it
/// (`ExportRangeRules.canExport(kind:range:duration:fps:)`, which calls the same two rules).
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func marksDraggedToTheEndAreCutToTheLastWholeFrame() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir)
        // 6.015 s of output: at 24 fps, 144 frames (144.36 rounded), the last one ending at 6 s.
        var document = edit(of: project)
        document.sequence = [clip(1, from: 0, to: 1), clip(2, from: 1.5, to: 6.515)]
        let duration = TimeMap(sequence: document.sequence).duration
        #expect(duration == 6_015_000_000)
        #expect(TimeMap.exportEnd(duration: duration, frameRate: 24) == 6_000_000_000)
        let folder = dir.appending(path: "out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let settings = ExportSettings(outputSize: [320, 180], framesPerSecond: 24)
        // From frame 358 of 60 fps to the end: 48.3 ms, a frame of 24 fps; cut at 6 s, 33.3 ms, not one.
        let marks = ExportRange(start: TimeMap.frameTime(358, frameRate: 60), end: duration)
        #expect(marks.lastsAFrame(fps: 24))
        await #expect(throws: ExportError.nothingToExport) {
            try await MP4Exporter(project: project, document: document, settings: settings, range: marks)
                .export(to: folder.appending(path: "out.mp4")) { _ in }
        }
        await #expect(throws: ExportError.nothingToExport) {
            try await MP4Exporter.mixSamples(of: project, document: document, framesPerSecond: 24, range: marks)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        // From frame 357, 50 ms after the cut: its frames.
        let earlier = ExportRange(start: TimeMap.frameTime(357, frameRate: 60), end: duration)
        let samples = try await MP4Exporter.mixSamples(of: project, document: document, framesPerSecond: 24, range: earlier)
        #expect(!samples.isEmpty)
    }
}

/// What the export left out is listed in seconds of the range's MP4, and only what falls in it.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func leftOutIsListedWithinTheRange() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 1)])
        try builder.addEmptySegment(  // its file is gone
            track: displayID, index: 2, start: at(1), end: at(2), endReason: .recoveredAfterCrash, file: .absent)
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 3)])
        try builder.addEmptySegment(track: micID, index: 2, start: at(3), end: at(4), endReason: .stopped, file: .absent)
        let project = try builder.write()
        let document = EditDocument.legacy(for: project)
        let settings = ExportSettings(outputSize: [320, 180], framesPerSecond: 30)
        let whole = try await export(project, document, settings: settings, range: nil, to: dir, name: "whole").summary
        #expect(whole.missingVideo.map { [$0.start, $0.end] } == [[1, 2]])
        #expect(whole.missingAudio.map { [$0.start, $0.end] } == [[3, 4]])

        // 1.5 s to 3.5 s: half of each.
        let part = try await export(
            project, document, settings: settings, range: ExportRange(start: 1_500_000_000, end: 3_500_000_000), to: dir, name: "part"
        ).summary
        #expect(part.missingVideo == [
            MissingVideo(track: displayID, file: "takes/take-001/display-1/seg-0002.mov", start: 0, end: 0.5, reason: .fileMissing),
        ])
        #expect(part.missingAudio == [
            MissingAudio(track: micID, file: "takes/take-001/mic/seg-0002.mov", start: 1.5, end: 2, reason: .fileMissing),
        ])
        // 2.2 s to 2.8 s: neither.
        let none = try await export(
            project, document, settings: settings, range: ExportRange(start: 2_200_000_000, end: 2_800_000_000), to: dir, name: "none"
        ).summary
        #expect(none == ExportSummary())
    }
}

/// Marks on the document's frame grid (`TimeMap.frameTime`, rounded to the nanosecond), `k` frames of the document
/// apart, hold the frames of the export that start within those `k` frames, `⌈k × export rate / document rate⌉`, and
/// last a frame of the export when `k / document rate ≥ 1 / export rate`: at every position on the grid, at every rate
/// of a document and of an export (the GIF's 10 to 30, the MP4's 24 to 60).
@Test func marksOnTheGridHoldTheFramesBetweenThem() {
    var wrong: [String] = []
    for documentRate in [24, 25, 30, 50, 60] {
        for exportRate in [10, 15, 20, 24, 25, 30, 50, 60] {
            // The grid's rounding repeats every second, so marks from each frame of the first second cover it.
            for i in 0..<documentRate {
                for k in 1...(2 * documentRate) {
                    let range = ExportRange(
                        start: TimeMap.frameTime(i, frameRate: documentRate), end: TimeMap.frameTime(i + k, frameRate: documentRate))
                    let frames = (k * exportRate + documentRate - 1) / documentRate
                    let lasts = k * exportRate >= documentRate
                    if range.frameCount(fps: exportRate) != frames || range.lastsAFrame(fps: exportRate) != lasts {
                        wrong.append("\(documentRate) → \(exportRate) fps, frames \(i) to \(i + k): \(range.frameCount(fps: exportRate)) frames, "
                            + "lasts a frame \(range.lastsAFrame(fps: exportRate)); \(frames) and \(lasts) expected")
                    }
                }
            }
        }
    }
    #expect(wrong.isEmpty, "\(wrong.count) mark pairs: \(wrong.prefix(5))")
}

/// The presentation times of the decoded frames of `url` whose centre is white: the flashes.
private func whiteFrameTimes(of url: URL) async throws -> [Double] {
    try await readVideoFrames(of: url, into: [Double]()) { times, frame in
        let p = pixel(frame.bytes, width: frame.width, x: frame.width / 2, y: frame.height / 2)
        if p.x > 240, p.y > 240, p.z > 240 { times.append(frame.time) }
    }
}

/// A range from 1 s and a quarter of a frame into a 1× clip, across the cut, to inside a clip at 2×: at both ends, the
/// flash and the 1000 Hz burst recorded at the same instant are where the edit puts them in the range's MP4.
///
/// The screen flashes from source 1.2 s (frames 36 to 38) and 5.6 s (frames 168 to 173), with a burst there of 0.1 and
/// 0.2 s. Output 1.2 s is 0.191 667 s into the range, and source 5.6 s, at 2× after the cut at source 2 s to 3 s, is
/// output 3.3 s, 2.291 667 s into it: the bursts start there. The frames of the range, at 30 fps from a quarter of a
/// frame past 1 s, sample the source a quarter of a frame and, at 2×, half a frame from its frames' edges: the first
/// white ones are the frames after those instants, 6 and 69, at 0.2 and 2.3 s, three each (at 2×, six of the source).
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func rangeAcrossACutIntoAFasterClipKeepsSync() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir, name: "Sync")
        let flashes = Set(36..<39).union(168..<174)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [
            VideoSegmentSpec(start: base, seconds: 8) { frame, sample in
                flashes.contains(frame) ? whiteVideoSample(width: 640, height: 360, pts: sample.presentationTimeStamp) : sample
            },
        ])
        let first = toneBurst(at: at(1.2), start: base, skewPPM: 0, frequency: 1000, channels: 1, seconds: 0.1)
        let second = toneBurst(at: at(5.6), start: base, skewPPM: 0, frequency: 1000, channels: 1, seconds: 0.2)
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [
            AudioSegmentSpec(start: base, seconds: 8, amplitude: 0) { block, sample in second(block, first(block, sample)) },
        ])
        let project = try builder.write()
        var document = EditDocument.legacy(for: project)
        document.sequence = [clip(1, from: 0, to: 2), clip(2, from: 3, to: 7, speed: 2)]  // 4 s of output, the cut at 2 s
        let range = ExportRange(start: 1_008_333_333, end: 3_500_000_000)
        let (destination, _) = try await export(
            project, document, settings: ExportSettings(outputSize: [320, 180], framesPerSecond: 30), range: range, to: dir, name: "sync")

        let times = try await readVideoFrames(of: destination, into: [Double]()) { $0.append($1.time) }
        #expect(times.count == 75)
        let whites = try await whiteFrameTimes(of: destination)
        let expected = [6, 7, 8, 69, 70, 71].map { Double($0) / 30 }
        #expect(whites.count == expected.count && zip(whites, expected).allSatisfy { abs($0 - $1) < 1e-6 }, "white frames at \(whites)")
        for (flash, burst) in [(0.2, 0.191_667), (2.3, 2.291_667)] {
            let onset = try await toneOnset(in: destination, frequency: 1000, near: burst, window: 0.15)
            #expect(abs(onset - burst) < 0.003, "the burst at \(onset) s, \(burst) s expected, the flash at \(flash) s")
        }

        // The audio is the whole mix's from output 1 008 333 333 ns, 48 400 frames in, across the cut and the stretch.
        let whole = try await MP4Exporter.mixSamples(of: project, document: document, framesPerSecond: 30)
        let part = try await MP4Exporter.mixSamples(of: project, document: document, framesPerSecond: 30, range: range)
        #expect(part.count == 120_000)
        #expect(part == Array(whole[48_400..<168_400]))
    }
}
