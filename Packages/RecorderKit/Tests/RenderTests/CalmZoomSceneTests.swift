// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat
// @testable for `FrameEvaluator.frame(at:)`.
@testable import Render
import Testing

/// Every frame with its calm zoom (phase 3 design §6, plan 3b Task Z4, decision 6): `CalmZoomScene` puts the path of the
/// calm blocks (`MotionPaths.calmZoom`) on each frame, its focus in the output's stage coordinates, where the classic
/// zoom's crop would be, while the stage stays still. Over the zoom of the golden case `zoomWithBlur` (a block of the
/// user's at 2× over [0.5, 2.5) s at a fixed point, the screen's centre, with the zoom's and the cursor's motion blur at
/// 0.5) on a take without files, as no frame is drawn here.

/// A take of 4 s on display 1, with the cursor moving over it the whole time.
private let take = StageDrawing.bareTake(seconds: 4)
private let events = cursorEvents(from: base, seconds: 4, across: Rect(x: 0, y: 0, width: 640, height: 360))
private let calmModes: [ZoomMode] = [.highlight, .dim, .loupe]

/// `zoomWithBlur`'s document with its block in `mode` and its lens `loupe`.
private func document(_ mode: ZoomMode, loupe: LoupeStyle? = nil) -> EditDocument {
    var document = EditDocument.legacy(take: take, events: events)
    var block = StageDrawing.zoom(1, from: 0.5, to: 2.5, depth: 2)
    block.mode = mode
    block.loupe = loupe
    document.zoom.regions = [block]
    document.zoom.motionBlur = 0.5
    document.cursor.motionBlur = 0.5
    return document
}

/// The scene of `document` at `size`.
private func scene(_ document: EditDocument, _ size: SIMD2<Int> = [1280, 720]) -> FrameEvaluator {
    FrameEvaluator(take: take, events: events, document: document, outputSize: size)
}

/// The output times of the frames at 60 fps from `from` to `to` seconds.
private func frames(from: Double = 0, to: Double = 4) -> [Double] {
    stride(from: from, to: to, by: 1.0 / 60).map { $0 }
}

private func near(_ a: Rect, _ b: Rect, _ tolerance: Double) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.width - b.width) <= tolerance
        && abs(a.height - b.height) <= tolerance
}

@Suite struct CalmZoomSceneTests {
    @Test func settledFocusIsTheClassicCropAtEachSize() throws {
        for size in [SIMD2(1280, 720), SIMD2(1920, 1080), SIMD2(3840, 2160)] {
            let classic = scene(document(.classic), size).frame(at: 2.4)
            #expect(classic.calmZoom == nil)
            let stage = try #require(classic.stage)
            let half = SIMD2<Double>(size) / stage.depth / 2
            let crop = Rect(x: stage.center.x - half.x, y: stage.center.y - half.y, width: 2 * half.x, height: 2 * half.y)
            for mode in calmModes {
                let layer = try #require(scene(document(mode), size).frame(at: 2.4).calmZoom, "\(mode) at \(size)")
                #expect(near(layer.focus, crop, 1e-6), "\(mode) at \(size): \(layer.focus) \(crop)")
            }
        }
    }

    @Test func calmFramesKeepTheStageStill() throws {
        for mode in calmModes {
            let calm = scene(document(mode))
            var seen = 0
            for t in frames() {
                let frame = calm.frame(at: t)
                #expect(frame.stage == nil && frame.subframes.isEmpty, "\(mode) at \(t) s")
                if frame.calmZoom != nil { seen += 1 }
            }
            // Seen over the block, and while it fades.
            #expect(seen >= 120, "\(mode): \(seen)")
        }
        #expect(!scene(document(.classic)).frame(at: 0.6).subframes.isEmpty)
    }

    @Test func loupeReadsItsBlock() throws {
        let lens = LoupeStyle(radius: 0.2, shape: .roundedRect)
        for (size, radius) in [(SIMD2(1920, 1080), 216.0), (SIMD2(3840, 2160), 432.0), (SIMD2(1080, 1920), 216.0)] {
            let evaluator = scene(document(.loupe, loupe: lens), size)
            let calm = try #require(evaluator.paths.calmZoom)
            for t in [0.8, 1.5, 2.4, 2.7] {
                let layer = try #require(evaluator.frame(at: t).calmZoom, "\(size) at \(t) s")
                let state = try #require(calm.state(atOutput: TimeMap.outputNanoseconds(seconds: t)))
                #expect(layer.mode == .loupe)
                #expect(
                    layer.loupe == LoupeLayer(radius: radius, shape: .roundedRect, magnification: state.depth),
                    "\(size) at \(t) s")
            }
            let settled = try #require(evaluator.frame(at: 2.4).calmZoom?.loupe)
            #expect(abs(settled.magnification - 2) < 1e-3, "\(settled)")
        }
        // Highlight and Dim have no lens.
        for mode: ZoomMode in [.highlight, .dim] {
            #expect(scene(document(mode, loupe: lens)).frame(at: 1.5).calmZoom?.loupe == nil)
        }
    }

    @Test func amountAndModeAreThePaths() throws {
        for mode in calmModes {
            let evaluator = scene(document(mode))
            let calm = try #require(evaluator.paths.calmZoom)
            var before = 0, after = 0
            for t in frames() {
                let layer = evaluator.frame(at: t).calmZoom
                let state = calm.state(atOutput: TimeMap.outputNanoseconds(seconds: t))
                #expect(layer?.amount == state?.amount && layer?.mode == state?.mode, "\(mode) at \(t) s")
                if layer != nil { #expect(layer?.mode == mode) }
                if t < 0.5 {
                    #expect(layer == nil, "\(mode) at \(t) s")
                    before += 1
                }
                if t > 2.5, layer == nil { after += 1 }
            }
            #expect(before == 30)
            // Faded before the end, and none from there on.
            #expect(after > 0, "\(mode)")
            #expect(evaluator.frame(at: 3.99).calmZoom == nil)
        }
    }

    @Test func switchingModeKeepsTheFocus() throws {
        let scenes = calmModes.map { scene(document($0)) }
        var compared = 0
        for t in frames() {
            let focuses = scenes.map { $0.frame(at: t).calmZoom?.focus }
            #expect(focuses.allSatisfy { $0 == focuses[0] }, "at \(t) s: \(focuses)")
            if focuses[0] != nil { compared += 1 }
        }
        #expect(compared >= 120)
    }

    /// Across a short gap into a deeper block the path places the focus at that block's depth already (`CalmZoomPath`),
    /// so it does not jump on the screen's edge as that block starts: the frame keeps it where the path put it, and does
    /// not jump there either. Here a short block at 2× between two at 4× leaves the focus on its way in from the first
    /// as the gap starts, outside where a crop of the shallower depth can be: placed again at that depth, it would jump
    /// as the third block starts. The path's own jump as that gap starts is a known issue of the path (plan 3b Task Z2).
    @Test func blocksOfOtherDepthsNearAnEdgeDoNotJump() throws {
        let take = StageDrawing.bareTake(seconds: 8)
        let size = SIMD2(1280, 720)
        func block(_ number: Int, _ from: Double, _ to: Double, _ depth: Double, _ mode: ZoomMode) -> ZoomRegion {
            var region = StageDrawing.zoom(number, from: from, to: to, depth: depth, focus: .fixed(x: 0.95, y: 0.5))
            region.mode = mode
            return region
        }
        // Each case's steps checked one after the other, and those where the path itself jumps (a known issue).
        let cases: [(label: String, regions: [ZoomRegion], steps: ClosedRange<Double>, pathJumps: ClosedRange<Double>?)] = [
            ("4× then 2×, 0.1 s apart", [block(1, 1, 3, 4, .highlight), block(2, 3.1, 5.1, 2, .loupe)], 2.8...3.4, nil),
            ("2× then 4×, 0.1 s apart", [block(1, 1, 3, 2, .highlight), block(2, 3.1, 5.1, 4, .loupe)], 2.8...3.4, nil),
            ("4× then 2× then 4×, touching", [
                block(1, 1, 2, 4, .highlight), block(2, 2, 2.2, 2, .dim), block(3, 2.2, 4.5, 4, .loupe),
            ], 1.9...2.5, nil),
            ("4× then 2× then 4×, 0.1 s apart", [
                block(1, 1, 2, 4, .highlight), block(2, 2.1, 2.3, 2, .dim), block(3, 2.4, 4.5, 4, .loupe),
            ], 2.32...2.7, 2.0...2.7),
        ]
        for (label, regions, steps, pathJumps) in cases {
            var document = EditDocument.legacy(take: take, events: [])
            document.zoom.regions = regions
            let evaluator = FrameEvaluator(take: take, events: [], document: document, outputSize: size)
            let calm = try #require(evaluator.paths.calmZoom)
            let stageSize = evaluator.paths.stage.stageSize
            let scale = SIMD2<Double>(size) / stageSize
            /// The frame's focus at step `s`, after checking it is the path's; `nil` where there is none.
            func focus(atStep s: Int) throws -> Rect? {
                let t = Double(s) / 600
                let layer = evaluator.frame(at: t).calmZoom
                let state = calm.state(atOutput: TimeMap.outputNanoseconds(seconds: t))
                #expect((layer == nil) == (state == nil), "\(label) at \(t) s")
                guard let layer, let state else { return nil }
                let focus = state.focus(stageSize: stageSize)
                let expected = Rect(
                    x: focus.x * scale.x, y: focus.y * scale.y, width: focus.width * scale.x, height: focus.height * scale.y)
                #expect(near(layer.focus, expected, 1e-6), "\(label) at \(t) s: \(layer.focus) \(expected)")
                return layer.focus
            }
            // Every frame of 60 fps from 1 s to 7 s is the path's, and every step about the last block's start follows
            // the one before.
            let seen = try stride(from: 600, to: 600 * 7, by: 10).filter { try focus(atStep: $0) != nil }.count
            #expect(seen > 60 * 3, "\(label)")
            /// The largest move of an edge of the focus from one step to the next over `seconds`.
            func largestMove(over seconds: ClosedRange<Double>) throws -> Double {
                var previous: Rect?
                var largest = 0.0
                for s in Int(seconds.lowerBound * 600)...Int(seconds.upperBound * 600) {
                    let current = try #require(try focus(atStep: s), "\(label) at step \(s)")
                    if let previous {
                        largest = max(
                            largest, abs(current.x - previous.x), abs(current.y - previous.y),
                            abs(current.x + current.width - previous.x - previous.width),
                            abs(current.y + current.height - previous.y - previous.height))
                    }
                    previous = current
                }
                return largest
            }
            let largest = try largestMove(over: steps)
            #expect(largest <= 0.01 * 720, "\(label): \(largest) px")
            if let pathJumps {
                let jump = try largestMove(over: pathJumps)
                withKnownIssue("CalmZoomPath jumps where a gap into a deeper block starts with the focus on its way") {
                    #expect(jump <= 0.01 * 720, "\(label): \(jump) px")
                }
            }
        }
    }

    /// The loupe magnifies at most 4× (phase 3 design §6, 1.25 to 4), whatever the block's depth (blocks read 1 to 16):
    /// from 1× as it comes in to 4× settled, for a block of the user's at 8× and for an automatic one of `zoom.auto.depth`
    /// 8; Highlight's focus is still the stage over the depth of the instant.
    @Test func loupeMagnifiesAtMostFourTimes() throws {
        var user = document(.loupe)
        user.zoom.regions[0].depth = 8
        var automatic = document(.classic)
        automatic.zoom.regions[0].origin = .auto
        automatic.zoom.regions[0].mode = nil
        automatic.zoom.regions[0].depth = nil
        automatic.zoom.auto.depth = 8
        automatic.zoom.auto.mode = .loupe
        for (label, document) in [("user's", user), ("automatic", automatic)] {
            let evaluator = scene(document)
            let calm = try #require(evaluator.paths.calmZoom)
            var below = 0, capped = 0
            for t in frames() {
                guard let layer = evaluator.frame(at: t).calmZoom else { continue }
                let state = try #require(calm.state(atOutput: TimeMap.outputNanoseconds(seconds: t)))
                let lens = try #require(layer.loupe, "\(label) at \(t) s")
                #expect(lens.magnification == min(state.depth, 4), "\(label) at \(t) s: \(lens) \(state.depth)")
                #expect(lens.magnification >= 1 && lens.magnification <= 4)
                if lens.magnification < 4 { below += 1 } else { capped += 1 }
                #expect(abs(layer.focus.width - 1280 / state.depth) < 1e-9, "\(label) at \(t) s")
            }
            #expect(below > 0 && capped > 30, "\(label): \(below) \(capped)")
            let settled = try #require(calm.state(atOutput: TimeMap.outputNanoseconds(seconds: 2.4)))
            #expect(settled.depth > 7.9 && evaluator.frame(at: 2.4).calmZoom?.loupe?.magnification == 4, "\(label)")
        }
        var lit = user
        lit.zoom.regions[0].mode = .highlight
        #expect(scene(lit).frame(at: 2.4).calmZoom?.loupe == nil)
    }

    /// No calm block, or `zoom.show` off: no layer anywhere.
    @Test func noCalmBlockNoLayer() {
        var off = document(.highlight)
        off.zoom.show = false
        for document in [document(.classic), off, EditDocument.legacy(take: take, events: events)] {
            let evaluator = scene(document)
            #expect(evaluator.paths.calmZoom == nil)
            #expect(frames().allSatisfy { evaluator.frame(at: $0).calmZoom == nil })
        }
    }
}
