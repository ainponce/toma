// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat
@testable import Render
import Testing

// A path that jumps (an instant zoom block's entry and exit, an unsmoothed cursor at a cut) is never blurred across the
// jump (final review B-M1): a shutter that crosses one samples only the side of it the frame's time is on, so the frame
// is one image, not the two on either side of the jump.

private let size = SIMD2(1280, 720)

private func at(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

/// The legacy document of `take`, its camera's shutter half a frame.
private func instantZoom(_ take: TakeRecord, from: Double, to: Double) -> EditDocument {
    var document = EditDocument.legacy(take: take, events: [])
    document.zoom.regions = [StageDrawing.zoom(1, from: from, to: to, depth: 2, focus: .fixed(x: 0.3, y: 0.6), instant: true)]
    document.zoom.motionBlur = 0.5
    return document
}

@Test func anInstantZoomIsNeverBlurredAcrossItsEdges() {
    let take = StageDrawing.bareTake()
    // Entering at 1 s (a frame's time) and at 1.0035 s (between two frames), leaving at 2 s: each frame on the grid at
    // 60 fps whose half-frame shutter crosses an edge.
    for (from, edgeFrame) in [(1.0, 60), (1.0035, 60)] {
        let document = instantZoom(take, from: from, to: 2)
        let paths = MotionPaths(take: take, events: [], document: document)
        let evaluator = FrameEvaluator(take: take, events: [], document: document, outputSize: size, paths: paths, frameRate: 60)
        for n in [edgeFrame, 120] {
            let t = TimeMap.frameTime(n, frameRate: 60)
            let frame = evaluator.frame(at: Double(t) / 1e9)
            #expect(frame.subframes.isEmpty, "frame \(n) (block from \(from) s): \(frame.subframes.map(\.stage.depth))")
            #expect((frame.stage?.depth ?? 1) == paths.zoom.state(atOutput: Int64(t)).depth, "frame \(n): the depth at its time")
        }
    }
}

@Test func heldShutterTimesStayOnTheirSide() {
    let t: Int64 = 1_000_000_000, frame60 = TimeMap.frameTime(1, frameRate: 60)
    let free = MotionBlurPlan.sampleTimes(at: t, shutter: 0.5, frameDuration: frame60, count: 5)
    // No jump, or one outside the shutter: the times of the frame, bit for bit.
    #expect(MotionBlurPlan.sampleTimes(at: t, shutter: 0.5, frameDuration: frame60, count: 5, jumps: []) == free)
    #expect(MotionBlurPlan.sampleTimes(at: t, shutter: 0.5, frameDuration: frame60, count: 5, jumps: [(t + 10_000_000)...(t + 11_000_000)]) == free)
    // A jump after `t`: up to its old value; at or before `t`: from its new one.
    let before = MotionBlurPlan.sampleTimes(at: t, shutter: 0.5, frameDuration: frame60, count: 5, jumps: [(t + 1_000_000)...(t + 2_000_000)])
    #expect(before.first == free.first && before.last == t + 1_000_000 && before.count == 5)
    let after = MotionBlurPlan.sampleTimes(at: t, shutter: 0.5, frameDuration: frame60, count: 5, jumps: [(t - 2_000_000)...t])
    #expect(after.first == t && after.last == free.last && after.count == 5)
    #expect(after == after.sorted() && before == before.sorted())
}

@Test func anUnsmoothedCursorIsNeverBlurredAcrossACut() {
    let take = StageDrawing.bareTake()
    // At (100, 100) until the cut over [1, 2) s, where it went to (500, 300) and stayed: it jumps there at output 1 s.
    let events = [StageDrawing.event(0, .cursor(x: 100, y: 100)), StageDrawing.event(1.5, .cursor(x: 500, y: 300))]
    var document = EditDocument.legacy(take: take, events: events)
    document.sequence = [
        Clip(id: "c-00000001", take: takeID, start: base, end: base.adding(seconds: 1), speed: 1),
        Clip(id: "c-00000002", take: takeID, start: base.adding(seconds: 2), end: base.adding(seconds: 3), speed: 1),
    ]
    document.cursor.smoothing = .off
    document.cursor.motionBlur = 0.5
    let paths = MotionPaths(take: take, events: events, document: document)
    let evaluator = FrameEvaluator(take: take, events: events, document: document, outputSize: size, paths: paths, frameRate: 60)
    let frame = evaluator.frame(at: 1)
    #expect(frame.cursor != nil)
    #expect(frame.cursorSamples.isEmpty, "\(frame.cursorSamples.map(\.hotspot))")
    #expect(paths.cursor.jumps == [(at(1) - 1)...at(1)])
}
