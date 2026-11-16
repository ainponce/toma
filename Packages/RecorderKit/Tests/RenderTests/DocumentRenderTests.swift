// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import ProjectFormat
import RecorderKitTestSupport
// @testable for `FrameEvaluator.frame(at:)`, which takes every cursor image as readable.
@testable import Render
import SyntheticCapture
import Testing

// Frames come from the edit document: its clips (through the time map), its screens, its style, its cursor and its
// camera. The legacy document draws what phase 0 and 1a draw.

private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)

private func cursor(_ seconds: Double, x: Double, y: Double) -> InputEvent {
    InputEvent(t: base.adding(seconds: seconds), kind: .cursor(x: x, y: y))
}

/// Clip `number` of `takeID` over the source seconds `[from, to)` from `base`.
private func clip(_ number: Int, from: Double, to: Double, speed: Double = 1) -> Clip {
    Clip(id: "c-0000000\(number)", take: takeID, start: base.adding(seconds: from), end: base.adding(seconds: to), speed: speed)
}

/// `[0, 1)` and `[2, 3)` s: the second second is cut.
private let cutSequence = [clip(1, from: 0, to: 1), clip(2, from: 2, to: 3)]

/// `sample` painted pure red when it is one of the frames of the second second (30 to 59 at 30 fps).
@Sendable private func paintingTheSecondSecondRed(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
    guard (30..<60).contains(frameIndex) else { return sample }
    let pixelBuffer = CMSampleBufferGetImageBuffer(sample)!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
    for y in 0..<CVPixelBufferGetHeight(pixelBuffer) {
        base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer))
            .assumingMemoryBound(to: UInt32.self)
            .update(repeating: 0xFFFF_0000, count: width)  // BGRA (0, 0, 255, 255)
    }
    return sample
}

/// Runs `body` on a thread of its own and waits for it without holding a Swift concurrency thread. Drawing decodes,
/// which blocks in `copyNextSampleBuffer` until AVFoundation's own reads finish: with every thread of the cooperative
/// pool blocked that way by tests running at once, those reads never run and the whole test run hangs
/// (`TrackFrameReader`, `readTrack` in RecorderKitTestSupport).
private func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result(catching: body)) }.start()
    }
}

/// Whether any pixel of tightly packed BGRA `bytes` is pure red.
private func containsRed(_ bytes: [UInt8]) -> Bool {
    stride(from: 0, to: bytes.count, by: 4).contains { bytes[$0 + 2] > 250 && bytes[$0 + 1] < 5 && bytes[$0] < 5 }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func legacyDocumentDrawsWhatTheOldInitDraws() async throws {
    try await withTemporaryDirectory { dir in
        let size = SIMD2(1280, 720)
        for golden in GoldenProjects.cases where !golden.times.isEmpty {
            let project = try await GoldenProjects.make(golden.name, in: dir)
            let legacy = EditDocument.legacy(for: project)
            let old = try FrameRenderer(project: project, outputSize: size)
            let new = try FrameRenderer(project: project, document: legacy, outputSize: size)
            #expect(new.duration == old.duration, "\(golden.name)")
            // Phase 0's style and the legacy document make the same frames, value for value.
            let styled = FrameEvaluator(take: project.take, events: project.events, style: StyleV0(), outputSize: size)
            let documented = FrameEvaluator(take: project.take, events: project.events, document: legacy, outputSize: size)
            let times = golden.times
            let frames = try await offThePool {
                try times.map { (drawn: try new.renderBytes(at: $0), expected: try old.renderBytes(at: $0)) }
            }
            for (t, frame) in zip(times, frames) {
                #expect(documented.frame(at: t) == styled.frame(at: t), "\(golden.name) at \(t) s")
                #expect(frame.drawn == frame.expected, "\(golden.name) at \(t) s")
            }
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func cutPartIsNeverShown() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(
            id: trackID, source: displaySource(globalFrame: screenFrame),
            segments: [VideoSegmentSpec(start: base, seconds: 3, transform: paintingTheSecondSecondRed)])
        let project = try builder.write()
        var document = EditDocument.legacy(for: project)
        document.sequence = cutSequence
        let size = SIMD2(320, 180)
        let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
        #expect(renderer.duration == 2.0)
        let frames = TimeMap(sequence: document.sequence).frameCount(frameRate: 30)
        #expect(frames == 60)
        let red = try await offThePool {
            try (0..<frames).map { containsRed(try renderer.renderBytes(at: Double(TimeMap.frameTime($0, frameRate: 30)) / 1e9)) }
        }
        #expect(red.allSatisfy { !$0 }, "red in frames \(red.indices.filter { red[$0] })")
        // Not cut, the red second is drawn, and seen.
        let uncut = try FrameRenderer(project: project, outputSize: size)
        #expect(try await offThePool { containsRed(try uncut.renderBytes(at: 1.5)) })
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func doubleSpeedShowsTwiceTheSource() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(
            id: trackID, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 3)])
        let project = try builder.write()
        var document = EditDocument.legacy(for: project)
        document.sequence = [clip(1, from: 0, to: 3, speed: 2)]
        let size = SIMD2(1280, 720)
        let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
        #expect(renderer.duration == 1.5)
        let frame = FrameEvaluator(take: project.take, events: project.events, document: document, outputSize: size).frame(at: 0.5)
        #expect(frame.screen?.sourceTime == base.adding(seconds: 1))
        let rect = try #require(frame.screen?.rect)
        let bytes = try await offThePool { try renderer.renderBytes(at: 0.5) }
        let center = pixel(bytes, width: size.x, x: Int(rect.x + rect.width / 2), y: Int(rect.y + rect.height * 0.75))
        #expect(SampleFactory.frameIndex(nearestTo: center) == 30)
    }
}

/// What the pointer did inside a cut is never drawn; where it is when the next clip starts is, from that clip's first
/// instant on (final review B-I1): the last position of the cut, as if the pointer had moved there right then.
@Test func cursorFromACutIsNotShown() throws {
    let display = Rect(x: 0, y: 0, width: 1920, height: 1080)
    let take = makeTake(tracks: [displayTrack(globalFrame: display, segments: [segment(start: base, end: base.adding(seconds: 3))])])
    let before = [cursor(0.5, x: 100, y: 100)]
    let inTheCut = [1.2, 1.5, 1.8].map { cursor($0, x: 600, y: 300) }
    func evaluator(_ events: [InputEvent], sequence: [Clip]) -> FrameEvaluator {
        var document = EditDocument.legacy(take: take, events: events)
        document.sequence = sequence
        return FrameEvaluator(take: take, events: events, document: document, outputSize: [1920, 1080])
    }
    // Not cut, the cursor goes to (600, 300).
    let whole = evaluator(before + inTheCut, sequence: [clip(1, from: 0, to: 3)])
    let wholeRect = try #require(whole.frame(at: 1.5).screen?.rect)
    #expect(abs(try #require(whole.frame(at: 1.5).cursor).hotspot.x - (wholeRect.x + 600.0 / 1920 * wholeRect.width)) < 1e-9)

    // Cut, the first instant after the cut has the cursor where the pointer is then, (600, 300); before it, where it was.
    let cut = evaluator(before + inTheCut, sequence: cutSequence)
    let frame = cut.frame(at: 1)
    #expect(frame.screen?.sourceTime == base.adding(seconds: 2))
    let rect = try #require(frame.screen?.rect)
    let hotspot = try #require(frame.cursor).hotspot
    #expect(abs(hotspot.x - (rect.x + 600.0 / 1920 * rect.width)) < 1e-9 && abs(hotspot.y - (rect.y + 300.0 / 1080 * rect.height)) < 1e-9)
    let movedAtTheClip = evaluator(before + [cursor(2, x: 600, y: 300)], sequence: cutSequence)
    for t in [0.9, 1.0, 1.5, 1.99] {
        #expect(cut.frame(at: t).cursor == movedAtTheClip.frame(at: t).cursor, "at \(t) s")
    }
    #expect(cut.frame(at: 0.9).cursor == evaluator(before, sequence: cutSequence).frame(at: 0.9).cursor, "nothing of the cut before it")
}

@Test func cameraHiddenWhenShowIsOff() {
    let take = makeTake(tracks: [
        displayTrack(globalFrame: screenFrame, segments: [segment(start: base, end: base.adding(seconds: 10))]),
        displayTrack(
            id: cameraID, kind: .camera, globalFrame: nil, segments: [segment(track: cameraID, start: base, end: base.adding(seconds: 10))]),
    ])
    var document = EditDocument.legacy(take: take, events: [])
    #expect(FrameEvaluator(take: take, events: [], document: document, outputSize: [1920, 1080]).frame(at: 1).camera != nil)
    document.camera.show = false
    let hidden = FrameEvaluator(take: take, events: [], document: document, outputSize: [1920, 1080])
    for t in [0, 1, 5, 9.9] {
        let frame = hidden.frame(at: t)
        #expect(frame.camera == nil && frame.screen != nil, "at \(t) s")
    }
}

private let builtIn = Rect(x: 0, y: 0, width: 1512, height: 982)
private let leftDisplay = Rect(x: -1920, y: -200, width: 1920, height: 1080)

/// Display 1 (`builtIn`) and display 2 (`leftDisplay`), each with a 10 s segment.
private func twoDisplays() -> TakeRecord {
    makeTake(tracks: [
        displayTrack(globalFrame: builtIn, segments: [segment(start: base, end: base.adding(seconds: 10))]),
        displayTrack(
            id: "display-2", displayID: 2, globalFrame: leftDisplay,
            segments: [segment(track: "display-2", start: base, end: base.adding(seconds: 10))]),
    ])
}

@Test func screenFollowsThePlanInitial() throws {
    let take = twoDisplays()
    let events = [cursor(0, x: 100, y: 100)]  // on display 1
    var document = EditDocument.legacy(take: take, events: events)
    #expect(document.screens.initial[takeID] == trackID)  // ScreenChoice's
    document.screens.initial[takeID] = "display-2"
    let frame = FrameEvaluator(take: take, events: events, document: document, outputSize: [1920, 1080]).frame(at: 1)
    #expect(frame.screen?.trackID == "display-2")
    // Display 2's shape, and no cursor: it is on display 1.
    let rect = try #require(frame.screen?.rect)
    #expect(abs(rect.width / rect.height - 1920.0 / 1080) < 1e-9)
    #expect(frame.cursor == nil)
    // A track the take does not have, or none for the take: no screen.
    for initial in [[takeID: "display-9"], [:]] {
        document.screens.initial = initial
        #expect(FrameEvaluator(take: take, events: events, document: document, outputSize: [1920, 1080]).frame(at: 1).screen == nil)
    }
}

@Test func screenChangesJumpAtTheirSourceTime() {
    let take = twoDisplays()
    var document = EditDocument.legacy(take: take, events: [])
    document.screens.changes = [
        ScreenChange(id: "p-00000001", take: takeID, t: base.adding(seconds: 4), track: "display-2", origin: .user),
        // Another take's change changes nothing here.
        ScreenChange(id: "p-00000002", take: "take-002", t: base.adding(seconds: 2), track: "display-2", origin: .user),
        ScreenChange(id: "p-00000003", take: takeID, t: base.adding(seconds: 7), track: trackID, origin: .user),
    ]
    let e = FrameEvaluator(take: take, events: [], document: document, outputSize: [1920, 1080])
    #expect(e.frame(at: 3).screen?.trackID == trackID)
    #expect(e.frame(at: 3.999).screen?.trackID == trackID)
    #expect(e.frame(at: 4).screen?.trackID == "display-2")
    #expect(e.frame(at: 6.9).screen?.trackID == "display-2")
    #expect(e.frame(at: 7).screen?.trackID == trackID)
}

@Test func cursorBeforeTheFirstClipCountsAtZero() throws {
    let display = Rect(x: 0, y: 0, width: 1920, height: 1080)
    let take = makeTake(tracks: [displayTrack(globalFrame: display, segments: [segment(start: base, end: base.adding(seconds: 3))])])
    // The recorder starts the cursor before the sources: a sample before the first clip.
    let events = [cursor(-0.05, x: 300, y: 200), cursor(1, x: 900, y: 500)]
    let legacy = FrameEvaluator(take: take, events: events, document: .legacy(take: take, events: events), outputSize: [1920, 1080])
    let frame = legacy.frame(at: 0)
    let rect = try #require(frame.screen?.rect)
    let hotspot = try #require(frame.cursor).hotspot
    #expect(abs(hotspot.x - (rect.x + 300.0 / 1920 * rect.width)) < 1e-9 && abs(hotspot.y - (rect.y + 200.0 / 1080 * rect.height)) < 1e-9)
    #expect(frame.cursor == FrameEvaluator(take: take, events: events, style: StyleV0(), outputSize: [1920, 1080]).frame(at: 0).cursor)

    // So does a sample before a clip that starts later in the take: 0.05 s before output 0.
    let later = [cursor(0.95, x: 300, y: 200), cursor(2, x: 900, y: 500)]
    var trimmed = EditDocument.legacy(take: take, events: later)
    trimmed.sequence = [clip(1, from: 1, to: 3)]
    let atZero = FrameEvaluator(take: take, events: later, document: trimmed, outputSize: [1920, 1080]).frame(at: 0)
    #expect(atZero.screen?.sourceTime == base.adding(seconds: 1))
    let trimmedHotspot = try #require(atZero.cursor).hotspot
    #expect(abs(trimmedHotspot.x - hotspot.x) < 1e-9 && abs(trimmedHotspot.y - hotspot.y) < 1e-9)
}

@Test func cameraChangesAreMappedToTheOutput() throws {
    let take = makeTake(tracks: [
        displayTrack(globalFrame: screenFrame, segments: [segment(start: base, end: base.adding(seconds: 3))]),
        displayTrack(
            id: cameraID, kind: .camera, globalFrame: nil, segments: [segment(track: cameraID, start: base, end: base.adding(seconds: 3))]),
    ])
    let landscape = CameraStyle(shape: .landscape, size: CameraStyle.small, anchor: .topLeading)
    let output = Rect(x: 0, y: 0, width: 1920, height: 1080)
    let from = CameraStyle.default.frame(in: output), to = landscape.frame(in: output)
    func along(_ p: Double) -> Rect {
        func mix(_ a: Double, _ b: Double) -> Double { a * (1 - p) + b * p }
        return Rect(
            x: mix(from.rect.x, to.rect.x), y: mix(from.rect.y, to.rect.y),
            width: mix(from.rect.width, to.rect.width), height: mix(from.rect.height, to.rect.height))
    }

    // A change in a cut rules from the first instant kept after it.
    let inTheCut = [InputEvent(t: base.adding(seconds: 1.5), kind: .cameraStyle(landscape))]
    var document = EditDocument.legacy(take: take, events: inTheCut)
    document.sequence = cutSequence
    let cut = FrameEvaluator(take: take, events: inTheCut, document: document, outputSize: [1920, 1080])
    #expect(try #require(cut.frame(at: 0.9).camera).rect == from.rect)
    #expect(try #require(cut.frame(at: 1).camera).rect == from.rect)
    #expect(try #require(cut.frame(at: 1.25).camera).rect == along(CameraStyleTimeline.progress(seconds: 0.25)))

    // A change before the first clip is under way at output 0, as it always was.
    let early = [InputEvent(t: base.adding(seconds: -0.25), kind: .cameraStyle(landscape))]
    let legacy = FrameEvaluator(take: take, events: early, document: .legacy(take: take, events: early), outputSize: [1920, 1080])
    let atZero = try #require(legacy.frame(at: 0).camera)
    #expect(atZero.rect == along(CameraStyleTimeline.progress(seconds: 0.25)))
    #expect(atZero == FrameEvaluator(take: take, events: early, style: StyleV0(), outputSize: [1920, 1080]).frame(at: 0).camera)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func missingVideoIsInOutputTime() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        // The screen's source [1.5, 2.5) s is gone; so is the camera's [1.2, 1.8) s, all of it in the cut.
        try await builder.addVideoTrack(
            id: trackID, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 1.5)])
        try builder.addEmptySegment(
            track: trackID, index: 2, start: base.adding(seconds: 1.5), end: base.adding(seconds: 2.5), endReason: .stopped, file: .absent)
        try await builder.addVideoTrack(
            id: trackID, source: displaySource(globalFrame: screenFrame),
            segments: [VideoSegmentSpec(start: base.adding(seconds: 2.5), seconds: 0.5)])
        try await builder.addVideoTrack(
            id: cameraID, kind: .camera, source: cameraSource, segments: [VideoSegmentSpec(start: base, seconds: 1.2)])
        try builder.addEmptySegment(
            track: cameraID, index: 2, start: base.adding(seconds: 1.2), end: base.adding(seconds: 1.8), endReason: .stopped, file: .absent)
        try await builder.addVideoTrack(
            id: cameraID, kind: .camera, source: cameraSource, segments: [VideoSegmentSpec(start: base.adding(seconds: 1.8), seconds: 1.2)])
        let project = try builder.write()
        var document = EditDocument.legacy(for: project)
        document.sequence = cutSequence
        let renderer = try FrameRenderer(project: project, document: document, outputSize: [320, 180])
        let screenGap = MissingVideo(track: trackID, file: "takes/\(takeID)/\(trackID)/seg-0002.mov", start: 1, end: 1.5, reason: .fileMissing)
        // Before a frame is drawn, and after every frame of the output.
        #expect(renderer.missingVideo == [screenGap])
        try await offThePool {
            for n in 0..<TimeMap(sequence: cutSequence).frameCount(frameRate: 30) {
                _ = try renderer.renderBytes(at: Double(TimeMap.frameTime(n, frameRate: 30)) / 1e9)
            }
        }
        #expect(renderer.missingVideo == [screenGap])
        // Without the cut, both gaps are listed where the take has them.
        #expect(try FrameRenderer(project: project, outputSize: [320, 180]).missingVideo == [
            MissingVideo(track: cameraID, file: "takes/\(takeID)/\(cameraID)/seg-0002.mov", start: 1.2, end: 1.8, reason: .fileMissing),
            MissingVideo(track: trackID, file: "takes/\(takeID)/\(trackID)/seg-0002.mov", start: 1.5, end: 2.5, reason: .fileMissing),
        ])
    }
}
