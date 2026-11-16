// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Testing
@testable import Analysis

// The zoom inside the screen's card of a split (1c design §5.4) over the take of `ZoomFixtures`, the project's layout a
// split unless a test says otherwise. The card's camera is in fractions of the screen's content: its crop is 1/z of it on
// each axis.

private let display = Rect(x: 0, y: 0, width: 1440, height: 900)
/// A 16:9 display: under a macOS window frame its bar is 5.4 % of the window's height, more than the 5 % of the content
/// a crop at 4× leaves between its central box and its edge.
private let wide = Rect(x: 0, y: 0, width: 1920, height: 1080)
private let cardRest = CardZoomState(logDepth: 0, center: SIMD2(0.5, 0.5))
private let framed = WindowFrame.macWindow(appearance: .dark, title: "Card", buttons: true)

/// The global point at fractions `f` of `frame` (the 1440×900 display at the origin unless said otherwise).
private func global(_ f: SIMD2<Double>, of frame: Rect = display) -> SIMD2<Double> {
    SIMD2(frame.x, frame.y) + f * SIMD2(frame.width, frame.height)
}

/// A curve over the whole of `frame` (the display unless said otherwise), its corners included, and a bit beyond them.
private func sweep(_ t: Double, over frame: Rect = display) -> SIMD2<Double> {
    global(SIMD2(cos(1.3 * t), sin(2.1 * t)) * 0.55 + 0.5, of: frame)
}

/// The output time of every step from `first` through `last`.
private func steps(_ first: Int, through last: Int) -> [(step: Int, output: Int64)] {
    (first...last).map { ($0, StepGrid.outputTime(ofStep: $0)) }
}

extension ZoomFixtures {
    /// A camera block of `kind` over source `from` to `to`.
    fileprivate static func layoutBlock(_ number: Int, _ kind: LayoutKind, from: Double, to: Double) -> LayoutBlock {
        LayoutBlock(
            id: "l-0000000\(number)", take: zoomTakeID, start: source(from), end: source(to), kind: kind, instant: false,
            bubble: kind == .bubble ? BubbleLayout(style: .default) : nil, split: SplitLayout())
    }

    /// `zoomDocument` with the project's layout a split unless said otherwise.
    fileprivate static func cardDocument(
        aspect: Aspect = .landscape, padding: Double = 0, frame: WindowFrame = .none,
        sequence: [Clip] = [zoomClip(1, from: 0, to: 20)], regions: [ZoomRegion] = [], show: Bool = true,
        smoothing: CursorSmoothing = .off, layout: CameraLayout = CameraLayout(kind: .split), layouts: [LayoutBlock] = []
    ) -> EditDocument {
        zoomDocument(
            aspect: aspect, padding: padding, frame: frame, sequence: sequence, regions: regions, show: show,
            smoothing: smoothing, layout: layout, layouts: layouts)
    }

    /// The card's path of `document`.
    fileprivate static func cardPath(
        _ document: EditDocument, events: [InputEvent] = [], take: TakeRecord = zoomTake(),
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> CardZoomPath {
        try #require(paths(document, events: events, take: take).cardZoom, sourceLocation: sourceLocation)
    }
}

extension ZoomFixtures {
    @Suite struct CardZoomPathTests {
        @Test func noSplitNoPath() throws {
            // Every other layout, for the project and in blocks; the blocks keep their split settings, as a block that was a
            // split and is not any more does.
            let others: [LayoutKind] = [.bubble, .screenOnly, .cameraOnly, .cameraFull]
            let blocks = others.enumerated().map { k, kind in layoutBlock(k + 1, kind, from: 4 * Double(k), to: 4 * Double(k) + 3) }
            let regions = [block(1, from: 1, to: 3), block(2, from: 5, to: 9, focus: .fixed(x: 0.2, y: 0.8))]
            for kind in others {
                let document = cardDocument(regions: regions, layout: CameraLayout(kind: kind, split: SplitLayout()), layouts: blocks)
                let motion = paths(document, events: trail(from: 0, to: 10) { sweep($0) })
                #expect(motion.cardZoom == nil, "\(kind)")
                let path = CardZoomPath(
                    document: document, timeMap: motion.timeMap, stage: motion.stage, cursor: motion.cursor, take: zoomTake())
                #expect(path == nil, "\(kind)")
            }
            // The project's layout a split, or a single block: a path, the one `CardZoomPath` builds.
            let oneBlock = blocks + [layoutBlock(9, .split, from: 17, to: 18)]
            for document in [cardDocument(regions: regions), cardDocument(regions: regions, layout: .bubble, layouts: oneBlock)] {
                let events = trail(from: 0, to: 10) { sweep($0) }
                let motion = paths(document, events: events)
                let card = try #require(motion.cardZoom)
                let built = try #require(CardZoomPath(
                    document: document, timeMap: motion.timeMap, stage: motion.stage, cursor: motion.cursor, take: zoomTake()))
                #expect(stride(from: 0, through: 6_000, by: 7).allSatisfy { card.state(atStep: $0) == built.state(atStep: $0) })
                #expect(card.state(atStep: step(2.5)).logDepth > 0.5)
            }
        }

        @Test func aLayoutEditThatMakesOrRemovesASplitIsNotTheSamePaths() throws {
            // `MotionPaths.areThePaths(of:)` keeps the paths of an edit they don't read: the layouts decide the card's
            // path, so an edit that makes a split or takes it away builds them again.
            let regions = [block(1, from: 1, to: 3)]
            let events = trail(from: 0, to: 10) { sweep($0) }
            let bubble = cardDocument(regions: regions, layout: .bubble)
            let projectSplit = cardDocument(regions: regions)
            let blockSplit = cardDocument(regions: regions, layout: .bubble, layouts: [layoutBlock(1, .split, from: 2, to: 6)])
            var blockNoLongerSplit = blockSplit
            blockNoLongerSplit.camera.layouts[0].kind = .screenOnly

            let noSplit = paths(bubble, events: events)
            #expect(noSplit.cardZoom == nil)
            #expect(noSplit.areThePaths(of: bubble))
            for (name, split) in [("the project's layout", projectSplit), ("a block", blockSplit)] {
                // Made: the paths without a split are not the split's.
                #expect(!noSplit.areThePaths(of: split), "\(name)")
                let motion = paths(split, events: events)
                #expect(motion.cardZoom != nil, "\(name)")
                #expect(motion.areThePaths(of: split), "\(name)")
                // Removed: the split's are not the paths without it.
                #expect(!motion.areThePaths(of: bubble), "\(name)")
            }
            // A block that stops being a split, the project's layout still not one.
            #expect(paths(blockNoLongerSplit, events: events).cardZoom == nil)
            #expect(!paths(blockSplit, events: events).areThePaths(of: blockNoLongerSplit))
            #expect(!paths(blockNoLongerSplit, events: events).areThePaths(of: blockSplit))
        }

        @Test func cropNeverLeavesTheScreen() throws {
            var generator = ZoomRandom(seed: 0x6361_7264)
            // A 16:10 display in 16:9; a 16:9 display in 9:16, padded, with the macOS window frame; a vertical window in 1:1.
            let tall = Rect(x: 100, y: 0, width: 500, height: 900)
            let cases: [(name: String, aspect: Aspect, padding: Double, frame: WindowFrame, take: TakeRecord, area: Rect)] = [
                ("16:9", .landscape, 0, .none, zoomTake(), display),
                ("9:16 of 16:9 with a window frame", .portrait, 0.08, framed, zoomTake(frame: wide), wide),
                ("1:1 of a vertical window", .square, 0.08, .none, zoomTake(frame: tall, window: true), tall),
            ]
            let corners = [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)]
            for (name, aspect, padding, frame, take, area) in cases {
                // Ten blocks of 1.3 s: the corners, then focuses at random and some following the cursor, some instant.
                let regions = (0..<10).map { k -> ZoomRegion in
                    let depth = Double.random(in: 1.25...4, using: &generator)
                    let corner = k < corners.count ? corners[k] : nil
                    let focus: ZoomFocus = corner.map { .fixed(x: $0.0, y: $0.1) }
                        ?? (Bool.random(using: &generator)
                            ? .follow
                            : .fixed(x: Double.random(in: 0...1, using: &generator), y: Double.random(in: 0...1, using: &generator)))
                    let from = 1.5 * Double(k)
                    return block(k + 1, from: from, to: from + 1.3, depth: depth, focus: focus, instant: k % 4 == 3)
                }
                // The cursor sweeps the screen, its corners and a bit beyond.
                let events = trail(from: 0, to: 15) { sweep($0, over: area) }
                let document = cardDocument(aspect: aspect, padding: padding, frame: frame, regions: regions, smoothing: smoothed)
                let card = try cardPath(document, events: events, take: take)
                var bad: [String] = []
                func check(_ state: CardZoomState, at label: String) {
                    let half = 1 / (2 * state.depth)
                    let low = half - 1e-12, high = 1 - half + 1e-12
                    if !(state.logDepth >= 0) || state.center.x < low || state.center.x > high || state.center.y < low
                        || state.center.y > high
                    {
                        bad.append("\(label): \(state.center) at depth \(state.depth)")
                    }
                }
                let span = card.span(from: 0, through: output(15))
                var depths: [Double] = []
                for (s, τ) in steps(0, through: 15 * 600) {
                    let state = span.state(atOutput: τ)
                    check(state, at: "step \(s)")
                    depths.append(state.logDepth)
                }
                for _ in 0..<500 {
                    let τ = Int64.random(in: -1_000_000_000..<16_000_000_000, using: &generator)
                    check(card.state(atOutput: τ), at: "τ \(τ)")
                }
                #expect(bad.isEmpty, "\(name): \(bad.count): \(bad.prefix(3))")
                // The blocks did zoom, and the camera headed to the first corner, placed in the crop's room, and got there.
                #expect(depths.contains { $0 > 0.2 }, "\(name)")
                let corner = SIMD2(repeating: 1 / (2 * (regions[0].depth ?? 0)))
                #expect(near(card.camera(atStep: step(0.5)).target, corner, 1e-12), "\(name)")
                #expect(near(card.state(atStep: step(1.29)).center, corner, 1e-3), "\(name)")
            }
        }

        @Test func followMovesOnlyOutsideTheCentralBox() throws {
            // Depth 2: the crop is half of the screen on each axis and its central box (60 %) 0.3, so 0.15 on each side of
            // the centre. The cursor (without smoothing) is at the screen's centre when the block starts at 1 s.
            let middle = SIMD2(0.5, 0.5)
            let crop = 0.5
            let half = crop * 0.3
            let inside = middle + SIMD2(half - 0.01, -(half - 0.01))
            let outRight = SIMD2(middle.x + half + 0.05, 0.5)
            let movedRight = SIMD2(middle.x + 0.05 + 0.15 * crop, 0.5)
            // Then out of the top of the new box by 0.05.
            let outTop = SIMD2(movedRight.x, 0.5 - half - 0.05)
            let movedUp = SIMD2(movedRight.x, 0.5 - 0.05 - 0.15 * crop)
            let events = [
                pointer(0, global(middle)), pointer(4, global(inside)), pointer(8, global(outRight)), pointer(14, global(outTop)),
            ]
            let card = try cardPath(cardDocument(regions: [block(1, from: 1, to: 19.5)]), events: events)

            #expect(near(card.camera(atStep: step(1)).target, middle))
            // Inside the box: the target does not move at all.
            let held = (step(1)..<step(8)).filter { card.camera(atStep: $0).target != card.camera(atStep: step(1)).target }
            #expect(held.isEmpty, "\(held.prefix(3))")
            // Out by 0.05 to the right: it moves 0.05 and 15 % of the crop that way, once, and the camera gets there.
            #expect(near(card.camera(atStep: step(8)).target, movedRight))
            #expect((step(8)..<step(14)).allSatisfy { card.camera(atStep: $0).target == card.camera(atStep: step(8)).target })
            #expect(near(card.state(atStep: step(13.9)).center, movedRight))
            // Out of the top: only the vertical moves.
            #expect(near(card.camera(atStep: step(14)).target, movedUp))
            #expect(near(card.state(atStep: step(19.4)).center, movedUp))
        }

        @Test func fixedFocusIsTheSavedPoint() throws {
            // fixed(0.3, 0.7) at 2× fits in the room of the crop, [0.25, 0.75] on each axis; fixed(0.05, 1) does not, and is
            // placed at its nearest corner of that room.
            let regions = [
                block(1, from: 1, to: 9, focus: .fixed(x: 0.3, y: 0.7)), block(2, from: 10, to: 18, focus: .fixed(x: 0.05, y: 1)),
            ]
            let sweeping = trail(from: 0, to: 20) { sweep($0) }
            let moving = try cardPath(cardDocument(regions: regions, smoothing: smoothed), events: sweeping)
            let still = try cardPath(cardDocument(regions: regions))
            let drift = (step(6)..<step(9)).filter { !near(moving.state(atStep: $0).center, SIMD2(0.3, 0.7), 1e-12) }
            #expect(drift.isEmpty, "\(drift.prefix(3)) \(moving.state(atStep: step(6)))")
            let placed = (step(15)..<step(18)).filter { !near(moving.state(atStep: $0).center, SIMD2(0.25, 0.75), 1e-12) }
            #expect(placed.isEmpty, "\(placed.prefix(3)) \(moving.state(atStep: step(15)))")
            // The cursor does not move it, and neither do where the screen is and how big: the card has the screen's
            // proportion, so the same path, bit for bit. (With a window frame, a fixed focus is a point of the window:
            // `withAWindowFrameTheCardIsTheContent`.)
            let elsewhere = try cardPath(
                cardDocument(aspect: .portrait, padding: 0.08, regions: regions, smoothing: smoothed), events: sweeping)
            let all = steps(0, through: step(20))
            let spans = [moving, still, elsewhere].map { $0.span(from: 0, through: output(20)) }
            #expect(all.allSatisfy { bits(spans[0].state(atOutput: $0.output)) == bits(spans[1].state(atOutput: $0.output)) })
            #expect(all.allSatisfy { bits(spans[2].state(atOutput: $0.output)) == bits(spans[1].state(atOutput: $0.output)) })
        }

        @Test func withAWindowFrameTheCardIsTheContent() throws {
            // A 16:9 display in 16:9 with the macOS window frame: the window and the content under its bar, in pixels of
            // the 1920 × 1080 output `StagePoints` places them in. The bar stays still over the content in a card (1c
            // design §14.2), so the card's camera works in the content's fractions.
            let rects = StageLayout.windowRect(contentAspect: 16.0 / 9, padding: 0.08, outputSize: SIMD2(1920, 1080))
            let (window, content) = (rects.window, rects.screen)
            #expect(rects.barHeight / window.height > 0.05)
            /// The point at fractions `f` of the window, in fractions of the content.
            func inContent(_ f: SIMD2<Double>) -> SIMD2<Double> {
                (SIMD2(window.x, window.y) + f * SIMD2(window.width, window.height) - SIMD2(content.x, content.y))
                    / SIMD2(content.width, content.height)
            }
            let take = zoomTake(frame: wide)
            func card(_ regions: [ZoomRegion], events: [InputEvent] = []) throws -> CardZoomPath {
                try cardPath(cardDocument(padding: 0.08, frame: framed, regions: regions), events: events, take: take)
            }

            // The cursor is read in the content: entering a following block with it at (0.45, 0.55) of the content heads
            // there.
            let cursor = SIMD2(0.45, 0.55)
            let entering = try card([block(1, from: 1, to: 3)], events: [pointer(0, global(cursor, of: wide))])
            #expect(near(entering.camera(atStep: step(1)).target, cursor, 1e-12), "\(entering.camera(atStep: step(1)).target)")
            // A fixed focus is 1b's point of the window, taken to the content.
            let fixed = try card([block(1, from: 1, to: 9, focus: .fixed(x: 0.3, y: 0.7))])
            let point = inContent(SIMD2(0.3, 0.7))
            #expect(abs(point.y - 0.7) > 0.01)
            #expect(near(fixed.state(atStep: step(8)).center, point, 1e-12), "\(fixed.state(atStep: step(8)).center) \(point)")

            // A crop at the top, at 2× and 4×: focused on the bar (the window's top edge), and following a cursor that
            // climbs to the content's top row. The crop's top edge never goes above the content's (no strip that is not
            // the screen), and gets to it.
            for depth in [2.0, 4.0] {
                let regions = [
                    block(1, from: 1, to: 5, depth: depth, focus: .fixed(x: 0.5, y: 0)), block(2, from: 6, to: 10, depth: depth),
                ]
                let events = [pointer(0, global(SIMD2(0.5, 0.5), of: wide)), pointer(6.5, global(SIMD2(0.5, 0), of: wide))]
                let path = try card(regions, events: events)
                let span = path.span(from: 0, through: output(11))
                let above = steps(0, through: step(11)).filter { _, τ in
                    let state = span.state(atOutput: τ)
                    return content.y + (state.center.y - 1 / (2 * state.depth)) * content.height < content.y - 1e-9
                }
                #expect(above.isEmpty, "\(depth): \(above.prefix(3).map(\.step))")
                #expect(abs(inContent(SIMD2(0.5, 0)).y) > 0.05)
                for settled in [4.9, 9.9] {
                    let state = path.state(atStep: step(settled))
                    #expect(abs(state.center.y - 1 / (2 * depth)) < 1e-9, "\(depth) at \(settled): \(state)")
                }
            }
        }

        @Test func theCursorNeverLeavesTheCropItHeadsToUnderAWindowFrame() throws {
            // At 4× the central box leaves 0.2 / 4 = 5 % of the content between it and the crop's edge, less than the
            // bar's 5.4 % of the window: read in the window's fractions, the cursor could be out of the crop shown. Read
            // in the content's, it never is: the cursor (without smoothing) climbs from the content's centre to its top
            // row, goes along it and down the left edge, and on every step of the block it is inside the crop the camera
            // heads to.
            func along(_ t: Double) -> SIMD2<Double> {
                switch t {
                case ..<3: SIMD2(0.5, 0.5 - 0.5 * t / 3)
                case ..<7: SIMD2(0.5 - 0.5 * (t - 3) / 4, 0)
                default: SIMD2(0, min((t - 7) / 5, 0.999))
                }
            }
            let events = trail(from: 0, to: 12) { global(along($0), of: wide) }
            let motion = paths(
                cardDocument(padding: 0.08, frame: framed, regions: [block(1, from: 0.5, to: 12, depth: 4)]), events: events,
                take: zoomTake(frame: wide))
            let card = try #require(motion.cardZoom)
            let half = 1.0 / 8
            var out: [String] = []
            for s in step(0.5)..<step(12) {
                guard let sample = motion.cursor.sample(atStep: s) else { continue }
                let cursor = sample.position / SIMD2(1920, 1080)
                let target = card.camera(atStep: s).target
                if abs(cursor.x - target.x) > half + 1e-12 || abs(cursor.y - target.y) > half + 1e-12 {
                    out.append("step \(s): cursor \(cursor), target \(target)")
                }
            }
            #expect(out.isEmpty, "\(out.count): \(out.prefix(3))")
            // It did follow the cursor to the top and the left.
            #expect(near(card.camera(atStep: step(6.9)).target, SIMD2(half, half), 0.06))
        }

        @Test func instantJumpsLikeTheStagePath() throws {
            for focus in [ZoomFocus.fixed(x: 0.3, y: 0.7), .follow] {
                let events = [pointer(0, global(SIMD2(0.6, 0.3)))]
                let motion = paths(cardDocument(regions: [block(1, from: 2, to: 5, focus: focus, instant: true)]), events: events)
                let card = try #require(motion.cardZoom)
                let range = try #require(motion.timeMap.outputRange(ofSource: source(2)..<source(5), take: zoomTakeID))
                let first = StepGrid.firstStep(atOrAfter: range.lowerBound), after = StepGrid.firstStep(atOrAfter: range.upperBound)
                let entered = card.camera(atStep: first)
                #expect(card.state(atStep: first - 1) == cardRest)
                #expect(card.state(atStep: first).logDepth == ln2)
                #expect(entered.center == entered.target && entered.centerVelocity == .zero && entered.logDepthVelocity == 0)
                #expect(near(card.state(atStep: first).center, focus == .follow ? SIMD2(0.6, 0.3) : SIMD2(0.3, 0.7)))
                #expect(card.state(atStep: after - 1).logDepth == ln2)
                #expect(card.state(atStep: after) == cardRest)
                let left = card.camera(atStep: after)
                #expect(left.logDepthVelocity == 0 && left.centerVelocity == .zero)
                // The same blocks and the same spring as the stage's camera: the same depth, step for step.
                let stage = motion.zoom.span(from: 0, through: output(8)), inCard = card.span(from: 0, through: output(8))
                #expect(steps(0, through: step(8)).allSatisfy {
                    inCard.state(atOutput: $0.output).logDepth.bitPattern == stage.state(atOutput: $0.output).logDepth.bitPattern
                })
            }
        }

        @Test func anyCheckpointGivesTheSameBits() throws {
            // A block that follows the smoothed cursor across the checkpoint at 2 s, then a fixed one and an instant one, on a
            // padded stage with the window frame.
            let regions = [
                block(1, from: 0.5, to: 3.5), block(2, from: 4, to: 6, depth: 3, focus: .fixed(x: 0.9, y: 0.1)),
                block(3, from: 6.5, to: 8, depth: 1.5, instant: true),
            ]
            let document = cardDocument(padding: 0.08, frame: framed, regions: regions, smoothing: smoothed)
            let card = try cardPath(document, events: trail(from: 0, to: 10) { sweep($0) })
            for s in [1_234, 0, 1, 599, 600, 601, 1_199, 1_200, 1_201, 2_399, 2_400, 3_000, 3_901, 4_500, 4_801, 6_000, 12_000] {
                #expect(bits(card.camera(atStep: s)) == bits(card.cameraSimulatedFromStart(atStep: s)), "step \(s)")
                #expect(bits(card.state(atStep: s)) == bits(card.stateSimulatedFromStart(atStep: s)), "step \(s)")
            }
            // The cursor did move the camera.
            #expect(card.camera(atStep: 1_234).target != card.camera(atStep: 400).target)
        }

        @Test func aSpanGivesTheStateOfEachInstant() throws {
            // A following block over a cursor that never stops, a fixed one, an instant one, a checkpoint and the output's end.
            let document = cardDocument(
                sequence: [zoomClip(1, from: 0, to: 6)], regions: [
                    block(1, from: 0.5, to: 2), block(2, from: 2, to: 3.5, depth: 3, focus: .fixed(x: 0.8, y: 0.2)),
                    block(3, from: 4, to: 5, depth: 1.5, focus: .fixed(x: 0.3, y: 0.7), instant: true),
                ], smoothing: smoothed)
            let card = try cardPath(document, events: trail(from: 0, to: 6) { sweep($0) })
            let h = TimeMap.frameTime(1, frameRate: 24) / 2
            for centre in [0.0, 0.5, 0.51, 0.999, 1.0, 1.7, 2.0, 3.5, 4.0, 5.0, 5.99, 6, 7] {
                let t = output(centre)
                let span = card.span(from: t - h, through: t + h)
                for τ in Array(stride(from: t - h, through: t + h, by: 1_234_567)) + [t, t - h - 5_000_000, t + h + 1, t + 2 * h, -1] {
                    #expect(bits(span.state(atOutput: τ)) == bits(card.state(atOutput: τ)), "at \(τ)")
                }
            }
            // Frames of every frame rate land on their steps.
            for frameRate in [24, 25, 30, 50, 60] {
                #expect((0..<(5 * frameRate)).allSatisfy { n in
                    card.state(atOutput: TimeMap.frameTime(n, frameRate: frameRate))
                        == card.state(atStep: StepGrid.step(frame: n, frameRate: frameRate))
                })
            }
        }

        @Test func noBlocksOrZoomsHiddenIsRest() throws {
            let regions = [
                block(1, from: 1, to: 3), block(2, from: 3, to: 5, focus: .fixed(x: 0.1, y: 0.9)),
                block(3, from: 6, to: 8, instant: true),
            ]
            let events = trail(from: 0, to: 10) { sweep($0) }
            for document in [cardDocument(regions: regions, show: false, smoothing: smoothed), cardDocument(smoothing: smoothed)] {
                let card = try cardPath(document, events: events)
                let span = card.span(from: 0, through: output(20))
                let moved = steps(0, through: 20 * 600).filter { span.state(atOutput: $0.output) != cardRest }
                #expect(moved.isEmpty, "\(moved.prefix(3).map(\.step))")
                #expect([-1, 0, 7, 12_000, 13_000].allSatisfy { card.state(atStep: $0) == cardRest })
                #expect(cardRest.depth == 1)
            }
        }

        /// A synthetic take of an hour (a pointer that never stops, at 60 Hz, and a click every 5 s, the automatic zoom's
        /// blocks over them) with one split. Run by an agent, with `TOMA_BENCH=1`, in release. In scope here: the card's
        /// camera runs the stage's simulation and does less on each step (nothing to avoid), so it costs no more than the
        /// stage's camera. The cold build of all the paths is printed and recorded, not asserted: design §15's ≤ 30 ms
        /// for an hour is the rebuild after an edit, Task 13's.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
        func rebuildingAnHourOfPathsFitsTheBudget() throws {
            let hour = 3_600.0
            let take = zoomTake(seconds: hour + 1)
            func at(_ t: Double) -> SIMD2<Double> { SIMD2(720 + 600 * cos(0.37 * t) * sin(0.11 * t), 450 + 380 * sin(0.53 * t)) }
            var events = trail(from: 0, to: hour, at)
            for k in 1..<Int(hour / 5) {
                let t = 5 * Double(k), point = at(t)
                events.append(InputEvent(t: source(t), kind: .mouseDown(.left, x: point.x, y: point.y)))
                events.append(InputEvent(t: source(t + 0.08), kind: .mouseUp(.left, x: point.x, y: point.y)))
            }
            events = events.sortedByTime()
            var document = cardDocument(
                sequence: [zoomClip(1, from: 0, to: hour)], smoothing: smoothed, layout: .bubble,
                layouts: [layoutBlock(1, .split, from: 600, to: 1_200)])
            document.zoom.regions = AutoZoomPlanner.plan(take: take, events: events, document: document)
            #expect(document.zoom.regions.count > 600)
            var noSplit = document
            noSplit.camera.layouts = []
            let motion = MotionPaths(take: take, events: events, document: document)
            #expect(motion.cardZoom != nil)

            // The median of 5 builds of each, after one of each to warm up, taking turns so that a change of the load
            // (other agents' tests) reaches them all alike.
            let builds: [() -> Void] = [
                { _ = MotionPaths(take: take, events: events, document: document) },
                { _ = MotionPaths(take: take, events: events, document: noSplit) },
                { _ = CardZoomPath(document: document, timeMap: motion.timeMap, stage: motion.stage, cursor: motion.cursor, take: take) },
                {
                    _ = ZoomCameraPath(
                        document: document, timeMap: motion.timeMap, stage: motion.stage, cursor: motion.cursor, take: take)
                },
                { _ = CursorPath(take: take, events: events, style: document.cursor, timeMap: motion.timeMap) },
            ]
            builds.forEach { $0() }
            let clock = ContinuousClock()
            var times = builds.map { _ in [Duration]() }
            for round in 0..<5 {
                for k in builds.indices {
                    let i = (k + round) % builds.count
                    times[i].append(clock.measure(builds[i]))
                }
            }
            let median = times.map { $0.sorted()[2] }
            func ms(_ duration: Duration) -> String { String(format: "%.1f ms", duration / .milliseconds(1)) }
            print(
                "rebuildingAnHourOfPathsFitsTheBudget: \(document.zoom.regions.count) blocks; median of 5: MotionPaths "
                    + "\(ms(median[0])) with the split, \(ms(median[1])) without; CardZoomPath \(ms(median[2])), ZoomCameraPath "
                    + "\(ms(median[3])), CursorPath \(ms(median[4]))")
            #expect(median[2] / median[3] <= 1.25, "CardZoomPath \(ms(median[2])), ZoomCameraPath \(ms(median[3]))")
        }
    }
}
