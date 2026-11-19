// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
import Foundation
import ProjectFormat
import Testing
@testable import ImageAnalysis

@Suite("ScanSampling")
struct ScanSamplingTests {
    private static let base: UInt64 = 1_000_000_000_000
    private static let takeID = "take-001"

    private func at(_ seconds: Double) -> HostTime {
        HostTime(nanoseconds: Self.base + UInt64((seconds * 1e9).rounded()))
    }

    private let frame1 = Rect(x: 0, y: 0, width: 1000, height: 500)
    private let frame2 = Rect(x: 1000, y: 0, width: 800, height: 600)

    /// A display track with segments over `spans` (seconds), and its Area if any.
    private func display(_ id: String, _ displayID: UInt32, frame: Rect, _ spans: [(Double, Double)], area: Rect? = nil)
        -> TrackRecord
    {
        TrackRecord(
            id: id, kind: .display,
            source: TrackSource(name: id, displayID: displayID, globalFrame: frame, pixelScale: 2, captureArea: area),
            segments: spans.enumerated().map { k, span in
                SegmentRecord(
                    index: k + 1, file: "takes/\(Self.takeID)/\(id)/seg-000\(k + 1).mov", startHostTime: at(span.0),
                    endHostTime: at(span.1), endReason: k + 1 < spans.count ? .paused : .stopped, droppedFrames: 0,
                    heartbeatFrames: 0)
            })
    }

    private func take(_ tracks: [TrackRecord]) -> TakeRecord {
        TakeRecord(id: Self.takeID, status: .complete, startedAt: Date(timeIntervalSince1970: 0), tracks: tracks)
    }

    private func change(to track: String, at seconds: Double) -> ScreenChange {
        ScreenChange(id: "s-0000000\(Int(seconds * 10) % 10)", take: Self.takeID, t: at(seconds), track: track, origin: .user)
    }

    private func pausedAndResumed(_ pause: Double, _ resume: Double) -> [InputEvent] {
        [InputEvent(t: at(pause), kind: .paused(reason: "user")), InputEvent(t: at(resume), kind: .resumed)]
    }

    private func described(_ samples: [ScanSample]) -> [String] {
        samples.map { "\(Double($0.t.nanoseconds - Self.base) / 1e9) \($0.track)" }
    }

    // MARK: - Samples

    @Test func fourPerSecondOfSourceOverTheWholeTake() {
        // Two segments with a pause between them, and a second display shown from 4.1 s on.
        let take = take([
            display("display-1", 1, frame: frame1, [(0, 2), (3, 5)]),
            display("display-2", 2, frame: frame2, [(0, 5)]),
        ])
        let events = pausedAndResumed(2, 3)
        var document = EditDocument.legacy(take: take, events: events)
        document.screens.changes = [change(to: "display-2", at: 4.1)]
        let samples = ScanSampling.samples(take: take, events: events, document: document)
        // Every 250 ms from the first frame, pauses included (a document can show the frozen frame), the last less than
        // 250 ms before the end; at each, the screen shown then.
        let expected = (0..<20).map { k -> String in
            let s = 0.25 * Double(k)
            return "\(s) \(s < 4.1 ? "display-1" : "display-2")"
        }
        #expect(described(samples) == expected)
        #expect(samples.first?.t == take.tracks[0].segments[0].startHostTime)
        #expect(ScanSampling.span(take: take, events: events) == at(0)..<at(5))
    }

    @Test func eachScreenFromItsFirstFrame() {
        // Shown from the start, the window's first frame comes at 1 s: nothing of it is drawn before.
        let window = TrackRecord(
            id: "window-1", kind: .window,
            source: TrackSource(name: "Notes", globalFrame: Rect(x: 100, y: 100, width: 400, height: 300), pixelScale: 2, windowID: 7),
            segments: [SegmentRecord(
                index: 1, file: "takes/\(Self.takeID)/window-1/seg-0001.mov", startHostTime: at(1), endHostTime: at(2),
                endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)])
        let take = take([display("display-1", 1, frame: frame1, [(0, 2)]), window])
        var document = EditDocument.legacy(take: take, events: [])
        document.screens.initial = [Self.takeID: "window-1"]
        let samples = ScanSampling.samples(take: take, events: [], document: document)
        #expect(described(samples) == ["1.0 window-1", "1.25 window-1", "1.5 window-1", "1.75 window-1"])
        #expect(samples.allSatisfy { $0.crop == Rect(x: 0, y: 0, width: 1, height: 1) })
    }

    @Test func aTakeWithNothingToLookAtHasNoSamples() {
        let empty = take([display("display-1", 1, frame: frame1, [(3, 3)])])
        #expect(ScanSampling.samples(take: empty, events: [], document: .legacy(take: empty, events: [])).isEmpty)
        let microphoneOnly = take([TrackRecord(
            id: "mic-1", kind: .microphone, source: TrackSource(name: "Mic"),
            segments: [SegmentRecord(
                index: 1, file: "takes/\(Self.takeID)/mic-1/seg-0001.m4a", startHostTime: at(0), endHostTime: at(4),
                endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)])])
        #expect(ScanSampling.samples(take: microphoneOnly, events: [], document: .legacy(take: microphoneOnly, events: [])).isEmpty)
        // A short take still has its first frame looked at.
        let short = take([display("display-1", 1, frame: frame1, [(0, 0.1)])])
        #expect(described(ScanSampling.samples(take: short, events: [], document: .legacy(take: short, events: []))) == ["0.0 display-1"])
    }

    @Test func samplesCarryTheAreaCrop() {
        // The area in Area mode, as fractions of the display: what the blocks' rects are fractions of.
        let take = take([display("display-1", 1, frame: frame1, [(0, 1)], area: Rect(x: 100, y: 50, width: 500, height: 250))])
        let samples = ScanSampling.samples(take: take, events: [], document: .legacy(take: take, events: []))
        #expect(samples.count == 4)
        #expect(samples.allSatisfy { $0.crop == Rect(x: 0.1, y: 0.1, width: 0.5, height: 0.5) })
    }

    @Test func theScreenBeingLeftIsLookedAtThroughItsCrossfade() {
        let take = take([
            display("display-1", 1, frame: frame1, [(0, 5)]),
            display("display-2", 2, frame: frame2, [(0, 5)]),
        ])
        func samples(speed: Double = 1, clips: [(Double, Double)] = [(0, 5)], changeAt: Double = 2.1, spring: Bool = true) -> [String] {
            var document = EditDocument.legacy(take: take, events: [])
            document.style.geometryTransition = spring ? .spring : .none
            document.sequence = clips.enumerated().map { k, clip in
                Clip(id: "c-0000000\(k + 1)", take: Self.takeID, start: at(clip.0), end: at(clip.1), speed: speed)
            }
            document.screens.changes = [change(to: "display-2", at: changeAt)]
            return described(ScanSampling.samples(take: take, events: [], document: document))
                .filter { $0.hasSuffix("display-1") && !$0.hasPrefix("0.") && !$0.hasPrefix("1.") }
        }
        // 0.25 s of output from the change on: display-1 at the change and at the grid's instants in it, after the screen
        // shown at the same instant.
        #expect(samples() == ["2.0 display-1", "2.1 display-1", "2.25 display-1"])
        // At 2×, 0.5 s of source.
        #expect(samples(speed: 2) == ["2.0 display-1", "2.1 display-1", "2.25 display-1", "2.5 display-1"])
        // A change in a cut crossfades from the next clip's first instant on, where display-2 is shown.
        #expect(samples(clips: [(0, 2), (3, 5)], changeAt: 2.5) == ["2.0 display-1", "2.25 display-1", "3.0 display-1"])
        // Clips wholly before the crossfade or after it play no part; a change before the first clip is over by then.
        #expect(samples(clips: [(0, 1), (1.5, 2), (2.6, 2.8), (3, 5)], changeAt: 2.9) == ["2.0 display-1", "2.25 display-1", "2.5 display-1", "2.75 display-1", "3.0 display-1"])
        #expect(samples(clips: [(3, 5)], changeAt: 1.0) == [])
        // Without the spring, the screen jumps: only the one shown.
        #expect(samples(spring: false) == ["2.0 display-1"])

        var document = EditDocument.legacy(take: take, events: [])
        document.style.geometryTransition = .spring
        document.screens.changes = [change(to: "display-2", at: 2.1)]
        let all = described(ScanSampling.samples(take: take, events: [], document: document))
        #expect(all.firstIndex(of: "2.25 display-2")! < all.firstIndex(of: "2.25 display-1")!)
        #expect(all.filter { $0.hasPrefix("2.25 ") }.count == 2)
    }

    // MARK: - Thumbnails

    /// A `width × height` frame of `format` whose luma is `inside` in `area` (in pixels) and `outside` elsewhere.
    private func frame(
        _ format: OSType, width: Int = 256, height: Int = 144, area: (x: Range<Int>, y: Range<Int>), inside: UInt8,
        outside: UInt8
    ) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &made)
        let buffer = try #require(status == kCVReturnSuccess ? made : nil)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        func value(_ x: Int, _ y: Int) -> UInt8 { area.x.contains(x) && area.y.contains(y) ? inside : outside }
        switch format {
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB:
            let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    let p = base + y * bytesPerRow + 4 * x
                    (p[0], p[1], p[2], p[3]) = (value(x, y), value(x, y), value(x, y), 255)
                }
            }
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for y in 0..<height {
                let row = (base + y * bytesPerRow).assumingMemoryBound(to: UInt16.self)
                // 8-bit video levels to 10-bit ones, in the high bits.
                for x in 0..<width { row[x] = (UInt16(value(x, y)) << 2) << 6 }
            }
        default:
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for y in 0..<height {
                for x in 0..<width { base[y * bytesPerRow + x] = value(x, y) }
            }
        }
        return buffer
    }

    @Test func thumbnailIsTheCropsLuma() throws {
        // The Area is the middle half of the frame: bright there (video white), dark (video black) around it.
        let area = (x: 64..<192, y: 36..<108)
        let crop = Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange] {
            let buffer = try frame(format, area: area, inside: 235, outside: 16)
            #expect(LumaThumbnail(pixelBuffer: buffer, crop: crop).luma == [UInt8](repeating: 255, count: 64 * 36))
            // The whole frame: dark at the corners, bright in the middle.
            let whole = LumaThumbnail(pixelBuffer: buffer, crop: Rect(x: 0, y: 0, width: 1, height: 1)).luma
            #expect(whole.count == 64 * 36)
            #expect(whole[0] == 0 && whole[64 * 36 - 1] == 0 && whole[18 * 64 + 32] == 255)
        }
        let full = try frame(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, area: area, inside: 200, outside: 10)
        #expect(LumaThumbnail(pixelBuffer: full, crop: crop).luma == [UInt8](repeating: 200, count: 64 * 36))
        let bgra = try frame(kCVPixelFormatType_32BGRA, area: area, inside: 255, outside: 0)
        #expect(LumaThumbnail(pixelBuffer: bgra, crop: crop).luma == [UInt8](repeating: 255, count: 64 * 36))

        // A crop smaller than the thumbnail still fills it; one outside the frame, or a format it cannot read, gives no
        // luma, which is never still.
        let tiny = LumaThumbnail(pixelBuffer: full, crop: Rect(x: 0.3, y: 0.3, width: 0.05, height: 0.05))
        #expect(tiny.luma == [UInt8](repeating: 200, count: 64 * 36))
        let outside = LumaThumbnail(pixelBuffer: full, crop: Rect(x: 1.2, y: 0, width: 0.5, height: 1))
        #expect(outside.luma.isEmpty && !outside.reusesResult(of: outside))
        let argb = try frame(kCVPixelFormatType_32ARGB, area: area, inside: 255, outside: 0)
        #expect(LumaThumbnail(pixelBuffer: argb, crop: crop).luma.isEmpty)
    }

    @Test func aStillFrameReusesItsResult() throws {
        let gray = LumaThumbnail(luma: [UInt8](repeating: 100, count: 64 * 36))
        // 2 / 255 ≈ 0.008: reused; 4 / 255 ≈ 0.016: recognized again.
        #expect(LumaThumbnail(luma: [UInt8](repeating: 102, count: 64 * 36)).reusesResult(of: gray))
        #expect(!LumaThumbnail(luma: [UInt8](repeating: 104, count: 64 * 36)).reusesResult(of: gray))
        #expect(abs(gray.difference(from: LumaThumbnail(luma: [UInt8](repeating: 102, count: 64 * 36))) - 2.0 / 255) < 1e-12)
        #expect(gray.reusesResult(of: gray))
        #expect(!gray.reusesResult(of: LumaThumbnail(luma: [])))

        // A new address on a plain screen changes the whole by far less than 1 % but its boxes by far more.
        let blank = try frame(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, width: 1920, height: 1080, area: (0..<0, 0..<0), inside: 0, outside: 235)
        let typed = try frame(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, width: 1920, height: 1080, area: (600..<760, 500..<512), inside: 40, outside: 235)
        let whole = Rect(x: 0, y: 0, width: 1, height: 1)
        let (before, after) = (LumaThumbnail(pixelBuffer: blank, crop: whole), LumaThumbnail(pixelBuffer: typed, crop: whole))
        let changed: [Double] = zip(before.luma, after.luma).map { abs(Double($0.0) - Double($0.1)) }
        let mean = changed.reduce(0, +) / Double(64 * 36 * 255)
        #expect(mean < LumaThumbnail.reuseThreshold)
        #expect(!after.reusesResult(of: before))
        #expect(LumaThumbnail(pixelBuffer: blank, crop: whole).reusesResult(of: before))
    }
}
