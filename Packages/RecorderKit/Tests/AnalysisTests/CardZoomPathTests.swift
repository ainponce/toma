// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Testing
@testable import Analysis

// The zoom inside the screen's card of a split (1c design §5.4), over a take whose source seconds count from `cardOrigin`,
// with a display of 1440×900 pt at the origin and one clip over its first 20 s unless a test says otherwise: output
// seconds are then source seconds. The project's layout is a split unless a test says otherwise. The card's camera is in
// fractions of what is shown of the screen: its crop is 1/z of it on each axis.

private let cardOrigin = HostTime(nanoseconds: 9_000_000_000_000)
private let cardTakeID = "take-001"
private let screenID = "display-1"
private let ln2 = log(2.0)
private let medium = SpringSpec(damping: 1, response: 0.70)
private let smoothed = CursorSmoothing.spring(SpringSpec(damping: 1, response: 0.16))
private let display = Rect(x: 0, y: 0, width: 1440, height: 900)
private let cardRest = CardZoomState(logDepth: 0, center: SIMD2(0.5, 0.5))

private func source(_ seconds: Double) -> HostTime { cardOrigin.adding(seconds: seconds) }

/// `seconds` of output, in nanoseconds.
private func output(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

/// The first step at or after `seconds` of output.
private func step(_ seconds: Double) -> Int { StepGrid.firstStep(atOrAfter: output(seconds)) }

/// A take with one screen track: a display of `frame` or, with `window`, a window there.
private func cardTake(frame: Rect = display, window: Bool = false, seconds: Double = 60) -> TakeRecord {
    let screen = TrackRecord(
        id: screenID, kind: window ? .window : .display,
        source: TrackSource(name: "Screen", displayID: window ? nil : 1, globalFrame: frame, pixelScale: 2),
        segments: [
            SegmentRecord(
                index: 1, file: "takes/\(cardTakeID)/\(screenID)/seg-0001.mov", startHostTime: cardOrigin,
                endHostTime: source(seconds), endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0),
        ])
    return TakeRecord(
        id: cardTakeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: [screen])
}

private func cardClip(_ number: Int, from: Double, to: Double) -> Clip {
    Clip(id: "c-0000000\(number)", take: cardTakeID, start: source(from), end: source(to), speed: 1)
}

private func block(
    _ number: Int, from: Double, to: Double, depth: Double? = 2, focus: ZoomFocus = .follow, instant: Bool = false
) -> ZoomRegion {
    ZoomRegion(
        id: "z-0000000\(number)", take: cardTakeID, start: source(from), end: source(to), origin: .user, depth: depth,
        focus: focus, instant: instant)
}

/// A camera block of `kind` over source `from` to `to`.
private func layoutBlock(_ number: Int, _ kind: LayoutKind, from: Double, to: Double) -> LayoutBlock {
    LayoutBlock(
        id: "l-0000000\(number)", take: cardTakeID, start: source(from), end: source(to), kind: kind, instant: false,
        bubble: kind == .bubble ? BubbleLayout(style: .default) : nil, split: SplitLayout())
}

private func cardDocument(
    aspect: Aspect = .landscape, padding: Double = 0, frame: WindowFrame = .none,
    sequence: [Clip] = [cardClip(1, from: 0, to: 20)], regions: [ZoomRegion] = [], show: Bool = true,
    smoothing: CursorSmoothing = .off,
    layout: CameraLayout = CameraLayout(kind: .split), layouts: [LayoutBlock] = []
) -> EditDocument {
    let toma = DefaultStyle.toma
    var style = toma.style
    style.padding = padding
    style.frame = frame
    var cursor = toma.cursor
    cursor.smoothing = smoothing
    cursor.hideWhenIdle = false
    return EditDocument(
        documentVersion: EditDocument.currentVersion, logSequence: 0, aspect: aspect, frameRate: 60, sequence: sequence,
        screens: ScreenPlan(initial: [cardTakeID: screenID], changes: []), style: style, cursor: cursor,
        zoom: ZoomPlan(show: show, auto: toma.zoomAuto, spring: medium, motionBlur: 0.5, regions: regions, suppressed: []),
        camera: CameraPlan(show: true, initial: [:], changes: [], layout: layout, layouts: layouts),
        audio: AudioPlan(limiter: true, tracks: [:]))
}

private func paths(_ document: EditDocument, events: [InputEvent] = [], take: TakeRecord = cardTake()) -> MotionPaths {
    MotionPaths(take: take, events: events, document: document)
}

/// The card's path of `document`.
private func cardPath(
    _ document: EditDocument, events: [InputEvent] = [], take: TakeRecord = cardTake(),
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> CardZoomPath {
    try #require(paths(document, events: events, take: take).cardZoom, sourceLocation: sourceLocation)
}

private func pointer(_ seconds: Double, _ point: SIMD2<Double>) -> InputEvent {
    InputEvent(t: source(seconds), kind: .cursor(x: point.x, y: point.y))
}

/// The global point at fractions `f` of the 1440×900 display at the origin.
private func global(_ f: SIMD2<Double>) -> SIMD2<Double> {
    f * SIMD2(1440, 900)
}

/// Pointer positions every 1/60 s from `from` to `to` seconds, both included, at `along(t)`.
private func trail(from: Double, to: Double, _ along: (Double) -> SIMD2<Double>) -> [InputEvent] {
    let count = Int(((to - from) * 60).rounded())
    return (0...count).map { i in
        let t = from + Double(i) / 60
        return pointer(t, along(t))
    }
}

/// A curve over the whole of `frame` (the display unless said otherwise), its corners included, and a bit beyond them.
private func sweep(_ t: Double, over frame: Rect = display) -> SIMD2<Double> {
    let p = SIMD2(cos(1.3 * t), sin(2.1 * t)) * 0.55 + 0.5
    return SIMD2(frame.x, frame.y) + SIMD2(frame.width, frame.height) * p
}

private func near(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ tolerance: Double = 1e-9) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
}

/// Every bit of the camera's simulation on a step.
private func bits(_ camera: CardZoomPath.Camera) -> [UInt64] {
    let values = [camera.logDepth, camera.logDepthVelocity, camera.center.x, camera.center.y, camera.centerVelocity.x]
    let all = values + [camera.centerVelocity.y, camera.target.x, camera.target.y]
    return all.map(\.bitPattern) + [UInt64(camera.block.map { $0 + 1 } ?? 0)]
}

/// Every bit of a placed state.
private func bits(_ state: CardZoomState) -> [UInt64] {
    [state.logDepth, state.center.x, state.center.y].map(\.bitPattern)
}

/// The output time of every step from `first` through `last`.
private func steps(_ first: Int, through last: Int) -> [(step: Int, output: Int64)] {
    (first...last).map { ($0, StepGrid.outputTime(ofStep: $0)) }
}

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
                document: document, timeMap: motion.timeMap, stage: motion.stage, cursor: motion.cursor, take: cardTake())
            #expect(path == nil, "\(kind)")
        }
        // The project's layout a split, or a single block: a path, the one `CardZoomPath` builds.
        let oneBlock = blocks + [layoutBlock(9, .split, from: 17, to: 18)]
        for document in [cardDocument(regions: regions), cardDocument(regions: regions, layout: .bubble, layouts: oneBlock)] {
            let events = trail(from: 0, to: 10) { sweep($0) }
            let motion = paths(document, events: events)
            let card = try #require(motion.cardZoom)
            let built = try #require(CardZoomPath(
                document: document, timeMap: motion.timeMap, stage: motion.stage, cursor: motion.cursor, take: cardTake()))
            #expect(stride(from: 0, through: 6_000, by: 7).allSatisfy { card.state(atStep: $0) == built.state(atStep: $0) })
            #expect(card.state(atStep: step(2.5)).logDepth > 0.5)
        }
    }

    @Test func cropNeverLeavesTheScreen() throws {
        var generator = CardRandom(seed: 0x6361_7264)
        // A 16:10 display in 16:9; a 16:9 display in 9:16, padded, with the macOS window frame; a vertical window in 1:1.
        let wide = Rect(x: 0, y: 0, width: 1920, height: 1080)
        let tall = Rect(x: 100, y: 0, width: 500, height: 900)
        let window = WindowFrame.macWindow(appearance: .dark, title: "Card", buttons: true)
        let cases: [(name: String, aspect: Aspect, padding: Double, frame: WindowFrame, take: TakeRecord, area: Rect)] = [
            ("16:9", .landscape, 0, .none, cardTake(), display),
            ("9:16 of 16:9 with a window frame", .portrait, 0.08, window, cardTake(frame: wide), wide),
            ("1:1 of a vertical window", .square, 0.08, .none, cardTake(frame: tall, window: true), tall),
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
        // The cursor does not move it, and neither do where the screen is and how it is framed: the card has the
        // screen's proportion, so the same path, bit for bit.
        let framed = try cardPath(
            cardDocument(
                aspect: .portrait, padding: 0.08, frame: .macWindow(appearance: .light, title: "Card", buttons: true),
                regions: regions, smoothing: smoothed),
            events: sweeping)
        let all = steps(0, through: step(20))
        let spans = [moving, still, framed].map { $0.span(from: 0, through: output(20)) }
        #expect(all.allSatisfy { bits(spans[0].state(atOutput: $0.output)) == bits(spans[1].state(atOutput: $0.output)) })
        #expect(all.allSatisfy { bits(spans[2].state(atOutput: $0.output)) == bits(spans[1].state(atOutput: $0.output)) })
    }

    @Test func instantJumpsLikeTheStagePath() throws {
        for focus in [ZoomFocus.fixed(x: 0.3, y: 0.7), .follow] {
            let events = [pointer(0, global(SIMD2(0.6, 0.3)))]
            let motion = paths(cardDocument(regions: [block(1, from: 2, to: 5, focus: focus, instant: true)]), events: events)
            let card = try #require(motion.cardZoom)
            let range = try #require(motion.timeMap.outputRange(ofSource: source(2)..<source(5), take: cardTakeID))
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
        let document = cardDocument(
            padding: 0.08, frame: .macWindow(appearance: .dark, title: "Card", buttons: true), regions: regions, smoothing: smoothed)
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
            sequence: [cardClip(1, from: 0, to: 6)], regions: [
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
    /// blocks over them) with one split: building its motion paths, the card's included. Run by an agent, with
    /// `TOMA_BENCH=1`, in release: the M5 Pro's goal of 1c design §15.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
    func rebuildingAnHourOfPathsFitsTheBudget() throws {
        let hour = 3_600.0
        let take = cardTake(seconds: hour + 1)
        var events = trail(from: 0, to: hour) { t in
            SIMD2(720 + 600 * cos(0.37 * t) * sin(0.11 * t), 450 + 380 * sin(0.53 * t))
        }
        for k in 1..<Int(hour / 5) {
            let t = 5 * Double(k)
            let point = SIMD2(720 + 600 * cos(0.37 * t) * sin(0.11 * t), 450 + 380 * sin(0.53 * t))
            events.append(InputEvent(t: source(t), kind: .mouseDown(.left, x: point.x, y: point.y)))
            events.append(InputEvent(t: source(t + 0.08), kind: .mouseUp(.left, x: point.x, y: point.y)))
        }
        events = events.sortedByTime()
        var document = cardDocument(
            sequence: [cardClip(1, from: 0, to: hour)], smoothing: smoothed, layout: .bubble,
            layouts: [layoutBlock(1, .split, from: 600, to: 1_200)])
        document.zoom.regions = AutoZoomPlanner.plan(take: take, events: events, document: document)
        #expect(document.zoom.regions.count > 600)

        func median(_ build: () -> Void) -> Duration {
            build()
            let clock = ContinuousClock()
            return (0..<5).map { _ in clock.measure(build) }.sorted()[2]
        }
        let all = median { _ = MotionPaths(take: take, events: events, document: document) }
        let motion = MotionPaths(take: take, events: events, document: document)
        let card = median {
            _ = CardZoomPath(document: document, timeMap: motion.timeMap, stage: motion.stage, cursor: motion.cursor, take: take)
        }
        let stage = median {
            _ = ZoomCameraPath(document: document, timeMap: motion.timeMap, stage: motion.stage, cursor: motion.cursor, take: take)
        }
        let cursor = median { _ = CursorPath(take: take, events: events, style: document.cursor, timeMap: motion.timeMap) }
        func ms(_ duration: Duration) -> String { String(format: "%.1f ms", duration / .milliseconds(1)) }
        print(
            "rebuildingAnHourOfPathsFitsTheBudget: \(document.zoom.regions.count) blocks; median of 5: MotionPaths \(ms(all)), "
                + "of which CardZoomPath \(ms(card)), ZoomCameraPath \(ms(stage)), CursorPath \(ms(cursor))")
        #expect(motion.cardZoom != nil)
        #expect(all <= .milliseconds(30), "\(ms(all))")
    }
}

/// SplitMix64: the same numbers on every run.
private struct CardRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
