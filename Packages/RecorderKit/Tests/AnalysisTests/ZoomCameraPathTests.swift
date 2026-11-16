// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Testing
@testable import Analysis

// The zoom camera's path (design §7.4, §8.3 and §8.6) over a take whose source seconds count from `zoomOrigin`, with a
// display of 1440×900 pt at the origin and one clip over its first 20 s unless a test says otherwise: output seconds are
// then source seconds. Without padding, the screen of a 16:9 stage (16/9 × 1) is 1.6 × 1 at x = 0.0889.

private let zoomOrigin = HostTime(nanoseconds: 9_000_000_000_000)
private let zoomTakeID = "take-001"
private let displayID = "display-1"
private let cameraID = "camera-1"
private let ln2 = log(2.0)
private let medium = SpringSpec(damping: 1, response: 0.70)
private let smoothed = CursorSmoothing.spring(SpringSpec(damping: 1, response: 0.16))

private func source(_ seconds: Double) -> HostTime { zoomOrigin.adding(seconds: seconds) }

/// `seconds` of output, in nanoseconds.
private func output(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

/// The first step at or after `seconds` of output.
private func step(_ seconds: Double) -> Int { StepGrid.firstStep(atOrAfter: output(seconds)) }

private func segment(_ track: String) -> SegmentRecord {
    SegmentRecord(
        index: 1, file: "takes/\(zoomTakeID)/\(track)/seg-0001.mov", startHostTime: zoomOrigin, endHostTime: source(60),
        endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
}

/// A take with one screen track, `display-1`: a display of `frame` (1440×900 pt) or, with `window`, a window there; and
/// a camera track when `camera` is set.
private func zoomTake(frame: Rect = Rect(x: 0, y: 0, width: 1440, height: 900), window: Bool = false, camera: Bool = false)
    -> TakeRecord
{
    let screen = TrackRecord(
        id: displayID, kind: window ? .window : .display,
        source: TrackSource(name: "Screen", displayID: window ? nil : 1, globalFrame: frame, pixelScale: 2),
        segments: [segment(displayID)])
    let cameraTrack = TrackRecord(id: cameraID, kind: .camera, source: TrackSource(name: "Camera"), segments: [segment(cameraID)])
    return TakeRecord(
        id: zoomTakeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        tracks: camera ? [screen, cameraTrack] : [screen])
}

private func zoomClip(_ number: Int, from: Double, to: Double, speed: Double = 1) -> Clip {
    Clip(id: "c-0000000\(number)", take: zoomTakeID, start: source(from), end: source(to), speed: speed)
}

private func block(
    _ number: Int, from: Double, to: Double, depth: Double? = 2, focus: ZoomFocus = .follow, instant: Bool = false
) -> ZoomRegion {
    ZoomRegion(
        id: "z-0000000\(number)", take: zoomTakeID, start: source(from), end: source(to), origin: .user, depth: depth,
        focus: focus, instant: instant)
}

private func zoomDocument(
    aspect: Aspect = .landscape, padding: Double = 0, sequence: [Clip] = [zoomClip(1, from: 0, to: 20)],
    regions: [ZoomRegion] = [], show: Bool = true, smoothing: CursorSmoothing = .off, bubble: CameraStyle? = nil
) -> EditDocument {
    let toma = DefaultStyle.toma
    var style = toma.style
    style.padding = padding
    var cursor = toma.cursor
    cursor.smoothing = smoothing
    cursor.hideWhenIdle = false
    return EditDocument(
        documentVersion: EditDocument.currentVersion, logSequence: 0, aspect: aspect, frameRate: 60, sequence: sequence,
        screens: ScreenPlan(initial: [zoomTakeID: displayID], changes: []), style: style, cursor: cursor,
        zoom: ZoomPlan(show: show, auto: toma.zoomAuto, spring: medium, motionBlur: 0.5, regions: regions, suppressed: []),
        camera: CameraPlan(show: bubble != nil, initial: bubble.map { [zoomTakeID: $0] } ?? [:], changes: []),
        audio: AudioPlan(limiter: true, tracks: [:]))
}

private func paths(_ document: EditDocument, events: [InputEvent] = [], take: TakeRecord = zoomTake()) -> MotionPaths {
    MotionPaths(take: take, events: events, document: document)
}

private func pointer(_ seconds: Double, _ point: SIMD2<Double>) -> InputEvent {
    InputEvent(t: source(seconds), kind: .cursor(x: point.x, y: point.y))
}

/// The global point of the 1440×900 display at the origin shown at stage point `p` of a 16:9 stage without padding.
private func global(_ p: SIMD2<Double>) -> SIMD2<Double> {
    (p - SIMD2(0.8 / 9, 0)) / SIMD2(1.6, 1) * SIMD2(1440, 900)
}

/// Pointer positions every 1/60 s from `from` to `to` seconds, both included, at `along(t)`.
private func trail(from: Double, to: Double, _ along: (Double) -> SIMD2<Double>) -> [InputEvent] {
    let count = Int(((to - from) * 60).rounded())
    return (0...count).map { i in
        let t = from + Double(i) / 60
        return pointer(t, along(t))
    }
}

/// A curve over the whole 1440×900 display, its corners included, and a bit beyond them.
private func sweep(_ t: Double) -> SIMD2<Double> {
    SIMD2(720 + 760 * cos(1.3 * t), 450 + 480 * sin(2.1 * t))
}

private func rest(_ aspect: Aspect = .landscape) -> ZoomCameraState {
    ZoomCameraState(logDepth: 0, center: SIMD2(aspect.ratio / 2, 0.5))
}

/// Every bit of the camera's simulation on a step.
private func bits(_ camera: ZoomCameraPath.Camera) -> [UInt64] {
    let values = [camera.logDepth, camera.logDepthVelocity, camera.center.x, camera.center.y, camera.centerVelocity.x]
    let all = values + [camera.centerVelocity.y, camera.target.x, camera.target.y]
    return all.map(\.bitPattern) + [UInt64(camera.block.map { $0 + 1 } ?? 0)]
}

private func near(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ tolerance: Double = 1e-9) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
}

/// The rect of `track`'s screen shown at output step `s`, as the path reads it.
private func screen(at s: Int, in paths: MotionPaths) -> Rect? {
    paths.timeMap.source(atOutput: StepGrid.outputTime(ofStep: s)).flatMap { paths.stage.screenRect(at: $0.source) }
}

@Test func restIsDepthOneCentered() {
    let events = trail(from: 0, to: 10, sweep)
    for aspect in [Aspect.landscape, .portrait, .square] {
        let zoom = paths(zoomDocument(aspect: aspect, sequence: [zoomClip(1, from: 0, to: 10)]), events: events).zoom
        let moved = (-3...6_003).filter { zoom.state(atStep: $0) != rest(aspect) }
        #expect(moved.isEmpty, "\(aspect): \(moved.prefix(3))")
        var generator = ZoomRandom(seed: 0x7265_7374)
        let τs = (0..<300).map { _ in Int64.random(in: -1_000_000_000...11_000_000_000, using: &generator) }
        #expect(τs.allSatisfy { zoom.state(atOutput: $0) == rest(aspect) })
    }
}

@Test func mediumReaches95PercentIn053s() throws {
    // A block from output 0 at 2×, Medium (1.0 · 0.70 s), focus on the centre so only the depth moves.
    let zoom = paths(zoomDocument(regions: [block(1, from: 0, to: 3, focus: .fixed(x: 0.5, y: 0.5))])).zoom
    let first95 = try #require((0...1_800).first { zoom.state(atStep: $0).logDepth >= 0.95 * ln2 })
    #expect((317...319).contains(first95))
    let first90 = try #require((0...1_800).first { zoom.state(atStep: $0).logDepth >= 0.90 * ln2 })
    #expect(abs(Double(first90) / 600 - 0.43) <= 0.01)
    // It never overshoots.
    #expect((0...1_800).allSatisfy { zoom.state(atStep: $0).logDepth <= ln2 })
}

@Test func cropNeverLeavesTheStageOrTheScreen() {
    var generator = ZoomRandom(seed: 0x6372_6f70)
    // A 16:10 display in 16:9, with and without padding; a 16:9 display in 9:16; a vertical window in 16:9.
    let display = Rect(x: 0, y: 0, width: 1440, height: 900)
    let wide = Rect(x: 0, y: 0, width: 1920, height: 1080)
    let tall = Rect(x: 100, y: 0, width: 500, height: 900)
    let cases: [(name: String, aspect: Aspect, padding: Double, take: TakeRecord, frame: Rect)] = [
        ("16:9", .landscape, 0, zoomTake(frame: display), display),
        ("16:9 padded", .landscape, 0.08, zoomTake(frame: display), display),
        ("9:16 of 16:9", .portrait, 0, zoomTake(frame: wide), wide),
        ("9:16 of 16:9 padded", .portrait, 0.08, zoomTake(frame: wide), wide),
        ("vertical window", .landscape, 0.08, zoomTake(frame: tall, window: true), tall),
    ]
    let corners = [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)]
    for (name, aspect, padding, take, frame) in cases {
        // Ten blocks of 1.3 s: the corners, then focuses at random and some following the cursor, some instant.
        let regions = (0..<10).map { k -> ZoomRegion in
            let depth = Double.random(in: 1.25...4, using: &generator)
            let corner = k < corners.count ? corners[k] : nil
            let focus: ZoomFocus = corner.map { .fixed(x: $0.0, y: $0.1) }
                ?? (Bool.random(using: &generator)
                    ? .follow
                    : .fixed(x: Double.random(in: 0...1, using: &generator), y: Double.random(in: 0...1, using: &generator)))
            return block(k + 1, from: 1.5 * Double(k), to: 1.5 * Double(k) + 1.3, depth: depth, focus: focus, instant: k % 4 == 3)
        }
        // The cursor sweeps the screen, its corners and a bit beyond.
        let events = trail(from: 0, to: 15) { t in
            let p = (sweep(t) - SIMD2(720, 450)) / SIMD2(760, 480)
            return SIMD2(frame.x, frame.y) + SIMD2(frame.width, frame.height) * (p * 0.55 + 0.5)
        }
        let document = zoomDocument(aspect: aspect, padding: padding, regions: regions, smoothing: smoothed)
        let motion = paths(document, events: events, take: take)
        let stage = motion.stage.stageSize
        var bad: [String] = []
        func check(_ state: ZoomCameraState, screen rect: Rect?, at label: String) {
            let crop = stage / state.depth
            let low = state.center - crop / 2, high = state.center + crop / 2
            if low.x < -1e-12 || low.y < -1e-12 || high.x > stage.x + 1e-12 || high.y > stage.y + 1e-12 {
                bad.append("\(label): off the stage \(low) \(high)")
            }
            guard let rect else { return }
            if crop.x <= rect.width, low.x < rect.x - 1e-12 || high.x > rect.x + rect.width + 1e-12 {
                bad.append("\(label): off the screen in x \(low.x) \(high.x) \(rect)")
            }
            if crop.y <= rect.height, low.y < rect.y - 1e-12 || high.y > rect.y + rect.height + 1e-12 {
                bad.append("\(label): off the screen in y \(low.y) \(high.y) \(rect)")
            }
            // Where it does not fit, it covers the whole screen.
            if crop.x > rect.width, low.x > rect.x + 1e-12 || high.x < rect.x + rect.width - 1e-12 {
                bad.append("\(label): part of the screen cut in x \(low.x) \(high.x) \(rect)")
            }
            if crop.y > rect.height, low.y > rect.y + 1e-12 || high.y < rect.y + rect.height - 1e-12 {
                bad.append("\(label): part of the screen cut in y \(low.y) \(high.y) \(rect)")
            }
        }
        for s in 0...(15 * 600) {
            check(motion.zoom.state(atStep: s), screen: screen(at: s, in: motion), at: "step \(s)")
        }
        for _ in 0..<500 {
            let τ = Int64.random(in: 0..<15_000_000_000, using: &generator)
            let rect = motion.timeMap.source(atOutput: τ).flatMap { motion.stage.screenRect(at: $0.source) }
            check(motion.zoom.state(atOutput: τ), screen: rect, at: "τ \(τ)")
        }
        #expect(bad.isEmpty, "\(name): \(bad.prefix(3))")
        // The blocks did zoom.
        #expect((0...(15 * 600)).contains { motion.zoom.state(atStep: $0).logDepth > 0.2 })
    }
}

@Test func followMovesOnlyOutsideTheCentralBox() {
    // Depth 2: the crop is 0.889 × 0.5 and its central box (60 %) 0.533 × 0.3, so 0.267 × 0.15 on each side of the
    // centre. The cursor (without smoothing) is at the stage's centre when the block starts at 1 s.
    let middle = SIMD2(8.0 / 9, 0.5)
    let crop = SIMD2(8.0 / 9, 0.5)
    let half = crop * 0.3
    let inside = middle + SIMD2(half.x - 0.01, -(half.y - 0.01))
    let outRight = SIMD2(middle.x + half.x + 0.05, 0.5)
    let movedRight = SIMD2(middle.x + 0.05 + 0.15 * crop.x, 0.5)
    // Then out of the top of the new box by 0.05.
    let outTop = SIMD2(movedRight.x, 0.5 - half.y - 0.05)
    let movedUp = SIMD2(movedRight.x, 0.5 - 0.05 - 0.15 * crop.y)
    let events = [
        pointer(0, global(middle)), pointer(4, global(inside)), pointer(8, global(outRight)), pointer(14, global(outTop)),
    ]
    let zoom = paths(zoomDocument(regions: [block(1, from: 1, to: 19.5)]), events: events).zoom

    #expect(near(zoom.camera(atStep: step(1)).target, middle))
    // Inside the box: the target does not move at all.
    let held = (step(1)..<step(8)).filter { zoom.camera(atStep: $0).target != zoom.camera(atStep: step(1)).target }
    #expect(held.isEmpty, "\(held.prefix(3))")
    // Out by 0.05 to the right: it moves 0.05 and 15 % of the crop that way, once, and the camera gets there.
    #expect(near(zoom.camera(atStep: step(8)).target, movedRight))
    #expect((step(8)..<step(14)).allSatisfy { zoom.camera(atStep: $0).target == zoom.camera(atStep: step(8)).target })
    #expect(near(zoom.state(atStep: step(13.9)).center, movedRight))
    // Out of the top: only the vertical moves.
    #expect(near(zoom.camera(atStep: step(14)).target, movedUp))
    #expect(near(zoom.state(atStep: step(19.4)).center, movedUp))
}

@Test func fixedFocusIgnoresTheCursor() {
    // fixed(0.3, 0.7) of the 1.6 × 1 screen at x = 0.0889: (0.5689, 0.7), inside the room of a crop of depth 2.
    let regions = [block(1, from: 1, to: 9, focus: .fixed(x: 0.3, y: 0.7))]
    let moving = paths(zoomDocument(regions: regions, smoothing: smoothed), events: trail(from: 0, to: 10, sweep)).zoom
    let still = paths(zoomDocument(regions: regions)).zoom
    let settled = moving.state(atStep: step(5)).center
    #expect(near(settled, SIMD2(0.8 / 9 + 0.3 * 1.6, 0.7)))
    let drift = (step(5)..<step(9)).filter { !near(moving.state(atStep: $0).center, settled, 1e-12) }
    #expect(drift.isEmpty, "\(drift.prefix(3))")
    // Exactly the same path as without a cursor.
    #expect((0...step(10)).allSatisfy { moving.state(atStep: $0) == still.state(atStep: $0) })
}

@Test func instantJumps() throws {
    for focus in [ZoomFocus.fixed(x: 0.3, y: 0.7), .follow] {
        let events = [pointer(0, global(SIMD2(0.5, 0.3)))]
        let motion = paths(zoomDocument(regions: [block(1, from: 2, to: 5, focus: focus, instant: true)]), events: events)
        let range = try #require(motion.timeMap.outputRange(ofSource: source(2)..<source(5), take: zoomTakeID))
        let first = StepGrid.firstStep(atOrAfter: range.lowerBound), after = StepGrid.firstStep(atOrAfter: range.upperBound)
        let entered = motion.zoom.camera(atStep: first)
        #expect(motion.zoom.state(atStep: first - 1).logDepth == 0)
        #expect(motion.zoom.state(atStep: first).logDepth == ln2)
        #expect(entered.center == entered.target && entered.centerVelocity == .zero && entered.logDepthVelocity == 0)
        #expect(motion.zoom.state(atStep: after - 1).logDepth == ln2)
        #expect(motion.zoom.state(atStep: after) == rest())
        let left = motion.zoom.camera(atStep: after)
        #expect(left.logDepthVelocity == 0 && left.centerVelocity == .zero)
    }
}

@Test func showOffIsAlwaysRest() {
    let regions = [
        block(1, from: 1, to: 3), block(2, from: 3, to: 5, focus: .fixed(x: 0.1, y: 0.9)),
        block(3, from: 6, to: 8, instant: true),
    ]
    let zoom = paths(zoomDocument(regions: regions, show: false), events: trail(from: 0, to: 10, sweep)).zoom
    let moved = (0...(20 * 600)).filter { zoom.state(atStep: $0) != rest() }
    #expect(moved.isEmpty, "\(moved.prefix(3))")
}

@Test func cursorUnderTheBubbleCountsAsOutside() {
    // A circle at the bottom centre, 0.40 of the stage's height and 0.032 from its bottom: y 0.568…0.968 in the output,
    // and from 0.552 grown by 8 % of its size about its centre. At depth 2 with the stage's centre as the target, the
    // central box spans output y 0.2…0.8: a cursor at stage y 0.6 (output 0.7) is inside it but under the bubble, one at
    // 0.53 (output 0.56) under the grown bubble only.
    let bubble = CameraStyle(shape: .circle, size: 0.40, anchor: .bottom)
    let top = 1 - 0.032 - 0.40 - 0.40 * ZoomCameraPath.bubbleMargin / 2
    let middle = SIMD2(8.0 / 9, 0.5)
    for under in [0.6, 0.53] {
        let events = [pointer(0, global(middle)), pointer(4, global(SIMD2(middle.x, under)))]
        let regions = [block(1, from: 1, to: 12)]
        let without = paths(zoomDocument(regions: regions), events: events, take: zoomTake(camera: true)).zoom
        let with = paths(zoomDocument(regions: regions, bubble: bubble), events: events, take: zoomTake(camera: true)).zoom
        // Without the camera the cursor is inside the box and nothing moves; with it, nothing moves either while the
        // cursor is at the centre.
        #expect(near(without.camera(atStep: step(4)).target, middle))
        #expect(near(without.state(atStep: step(11)).center, middle))
        #expect(near(with.camera(atStep: step(4) - 1).target, middle))
        // Under it, it counts as out toward the bubble's side, the bottom, by what it takes to clear the grown bubble
        // (its output y less the bubble's top, half of that in the stage at 2×) and 15 % of the crop more: the crop moves
        // down, so the image moves up and the cursor comes out above the bubble, away from it.
        let expected = middle.y + ((under - middle.y) * 2 + 0.5 - top) / 2 + 0.15 * 0.5
        let target = with.camera(atStep: step(4)).target
        #expect(near(target, SIMD2(middle.x, expected)), "under \(under): \(target)")
        let settled = with.state(atStep: step(11))
        #expect(settled.center.y > middle.y && abs(settled.center.x - middle.x) < 1e-12)
        let cursorInOutput = (under - settled.center.y) * settled.depth + 0.5
        #expect(abs(cursorInOutput - (top - 0.15)) < 1e-9)
        // It moves once: from there the cursor is out of the bubble and inside the box.
        #expect((step(4)..<step(12)).allSatisfy { with.camera(atStep: $0).target == target })
    }
}

@Test func aCornerBubbleIsClearedTheShortestWay() {
    // A circle of 0.45 at the bottom right of a 16:9 output, grown by 8 %: x from 1.2778, y from 0.5. The cursor at output
    // (1.35, 0.75), inside the central box, is 0.072 from clearing it to the left and 0.25 upward: the crop moves right.
    let bubble = CameraStyle(shape: .circle, size: 0.45, anchor: .bottomTrailing)
    let left = 16.0 / 9 - 0.032 - 0.45 - 0.45 * ZoomCameraPath.bubbleMargin / 2
    let middle = SIMD2(8.0 / 9, 0.5)
    let under = (SIMD2(1.35, 0.75) - middle) / 2 + middle
    let events = [pointer(0, global(middle)), pointer(4, global(under))]
    let document = zoomDocument(regions: [block(1, from: 1, to: 12)], bubble: bubble)
    let zoom = paths(document, events: events, take: zoomTake(camera: true)).zoom
    let target = zoom.camera(atStep: step(4)).target
    #expect(near(target, SIMD2(middle.x + (1.35 - left) / 2 + 0.15 * 8.0 / 9, middle.y)), "\(target)")
    #expect((step(4)..<step(12)).allSatisfy { zoom.camera(atStep: $0).target == target })
}

@Test func aBubbleTooBigForTheBoxStillUncoversTheCursor() {
    // 9:16 of a 16:9 display, a circle of 0.45 at the middle of the right edge: grown, it covers output x 0.0625…0.5485 of
    // 0.5625. The cursor at the centre is under it; clearing it takes the cursor out of the central box, and the camera
    // settles where the cursor is out from under the bubble, without shaking, and in the frame: `followStep` of the
    // output past the bubble would be off it, so it stops at `frameMargin` from the edge.
    let bubble = CameraStyle(shape: .circle, size: 0.45, anchor: .trailing)
    let display = Rect(x: 0, y: 0, width: 1920, height: 1080)
    let events = [pointer(0, SIMD2(960, 540))]
    let motion = paths(
        zoomDocument(aspect: .portrait, regions: [block(1, from: 1, to: 12)], bubble: bubble), events: events,
        take: zoomTake(frame: display, camera: true))
    let target = motion.zoom.camera(atStep: step(2)).target
    #expect((step(2)..<step(12)).allSatisfy { motion.zoom.camera(atStep: $0).target == target })
    let settled = motion.zoom.state(atStep: step(11))
    let cursor = (0.5625 / 2 - settled.center.x) * settled.depth + 0.5625 / 2
    let bubbleLeft = 0.5625 - 0.032 - 0.45 - 0.45 * ZoomCameraPath.bubbleMargin / 2
    #expect(cursor < bubbleLeft - 1e-6, "\(cursor)")
    #expect(abs(cursor - ZoomCameraPath.frameMargin) < 1e-6, "\(cursor)")
}

@Test func sideBubblesLeaveTheCursorInTheFrame() {
    // A 16:9 display in 9:16, 1:1 and 16:9, a bubble of every size on each side, and the cursor (without smoothing) held
    // on points all over the screen: wherever the camera heads, the cursor is in the output's frame. In 9:16 a grown
    // circle of 0.43 or more at the left or right covers the output but for less than `followStep` of its width.
    let display = Rect(x: 0, y: 0, width: 1920, height: 1080)
    let spots = [0.05, 0.25, 0.47, 0.5, 0.75, 0.95].flatMap { x in [0.1, 0.5, 0.9].map { y in SIMD2(x, y) * SIMD2(1920, 1080) } }
    var bad: [String] = []
    for aspect in [Aspect.portrait, .square, .landscape] {
        for size in [0.10, 0.24, 0.33, 0.40, 0.43, 0.45] {
            for anchor in [CameraAnchor.leading, .trailing, .top, .bottom] {
                let bubble = CameraStyle(shape: .circle, size: size, anchor: anchor)
                let events = spots.enumerated().map { pointer(1 + Double($0.offset), $0.element) }
                let document = zoomDocument(aspect: aspect, regions: [block(1, from: 0.5, to: 20)], bubble: bubble)
                let motion = paths(document, events: events, take: zoomTake(frame: display, camera: true))
                let stage = motion.stage.stageSize
                for (k, spot) in spots.enumerated() {
                    let at = 1 + Double(k)
                    guard let point = motion.stage.stagePoint(global: spot, at: source(at)) else { continue }
                    // Where the camera heads, a few steps after the cursor got there, and where it is 0.95 s later.
                    let target = motion.zoom.camera(atStep: step(at) + 3).target
                    let headed = (point - target) * 2 + stage / 2
                    let settled = motion.zoom.state(atStep: step(at + 0.95))
                    let shown = (point - settled.center) * settled.depth + stage / 2
                    let inFrame = { (q: SIMD2<Double>, tolerance: Double) in
                        q.x >= -tolerance && q.y >= -tolerance && q.x <= stage.x + tolerance && q.y <= stage.y + tolerance
                    }
                    if !inFrame(headed, 1e-12) || !inFrame(shown, 0.01) {
                        bad.append("\(aspect) \(size) \(anchor) at \(spot): heads to \(headed), shown at \(shown)")
                    }
                }
            }
        }
    }
    #expect(bad.isEmpty, "\(bad.count): \(bad.prefix(3))")
}

@Test func anUnderdampedSpringNeverZoomsOutPastTheStage() {
    // `StepGrid.stable` lets a damping from 0 to 2 through: below 1 the camera overshoots on its way back to rest, and
    // its `u` goes below 0, which is drawn as 0, so the crop never gets bigger than the stage.
    for spring in [SpringSpec(damping: 0.5, response: 0.3), SpringSpec(damping: 0, response: 0.3)] {
        var document = zoomDocument(padding: 0.08, regions: [block(1, from: 1, to: 3, focus: .fixed(x: 0.9, y: 0.2))])
        document.zoom.spring = spring
        let motion = paths(document)
        let stage = motion.stage.stageSize
        #expect((step(3)..<step(6)).contains { motion.zoom.camera(atStep: $0).logDepth < -1e-3 }, "\(spring)")
        let bad = (0...(8 * 600)).filter { s in
            let state = motion.zoom.state(atStep: s)
            let crop = stage / state.depth
            let low = state.center - crop / 2, high = state.center + crop / 2
            return state.logDepth < 0 || low.x < -1e-12 || low.y < -1e-12 || high.x > stage.x + 1e-12 || high.y > stage.y + 1e-12
        }
        #expect(bad.isEmpty, "\(spring): \(bad.prefix(3))")
    }
}

@Test func adjacentBlocksPassWithoutZoomingOut() throws {
    // Two blocks that meet at 4 s, each at 2× with its own focus.
    let pegged = paths(
        zoomDocument(regions: [
            block(1, from: 1, to: 4, focus: .fixed(x: 0.3, y: 0.5)), block(2, from: 4, to: 7, focus: .fixed(x: 0.7, y: 0.5)),
        ])
    ).zoom
    let dips = (step(2.5)..<step(7)).filter { pegged.state(atStep: $0).logDepth < ln2 - 0.01 }
    #expect(dips.isEmpty, "\(dips.prefix(3))")
    // The centre goes from one focus to the other.
    #expect(pegged.state(atStep: step(6.9)).center.x > pegged.state(atStep: step(3.9)).center.x + 0.3)

    // Faster than 2×, an end mapped back to the output can be 1 ns short of the next block's start (plan decision 16):
    // at 3×, source [0, 3 s) ends at output 1 s and [3 s + 2 ns, 6 s) starts 1 ns later, the time of step 600. Blocks 1 ns
    // apart touch, so even instant ones never cut out there.
    let fast = paths(
        zoomDocument(
            sequence: [zoomClip(1, from: 0, to: 30, speed: 3)],
            regions: [
                block(1, from: 0, to: 3, instant: true),
                ZoomRegion(
                    id: "z-00000002", take: zoomTakeID, start: HostTime(nanoseconds: source(3).nanoseconds + 2), end: source(6),
                    origin: .user, depth: 2, focus: .follow, instant: true),
            ]))
    let first = try #require(fast.timeMap.outputRange(ofSource: source(0)..<source(3), take: zoomTakeID))
    let second = try #require(
        fast.timeMap.outputRange(ofSource: HostTime(nanoseconds: source(3).nanoseconds + 2)..<source(6), take: zoomTakeID))
    #expect(first.upperBound == 1_000_000_000 && second.lowerBound == 1_000_000_001)
    #expect(StepGrid.outputTime(ofStep: 600) == 1_000_000_000)
    #expect((0..<1_200).allSatisfy { fast.zoom.state(atStep: $0).logDepth == ln2 })
}

@Test func zoomFromAnyCheckpointGivesTheSameBits() {
    // A block that follows the smoothed cursor across the checkpoint at 2 s, with the camera's bubble, then a fixed
    // one and an instant one, on a padded stage.
    let regions = [
        block(1, from: 0.5, to: 3.5), block(2, from: 4, to: 6, depth: 3, focus: .fixed(x: 0.9, y: 0.1)),
        block(3, from: 6.5, to: 8, depth: 1.5, instant: true),
    ]
    let document = zoomDocument(
        padding: 0.08, regions: regions, smoothing: smoothed,
        bubble: CameraStyle(shape: .circle, size: 0.33, anchor: .bottomTrailing))
    let zoom = paths(document, events: trail(from: 0, to: 10, sweep), take: zoomTake(camera: true)).zoom
    for s in [1_234, 0, 1, 599, 600, 601, 1_199, 1_200, 1_201, 2_399, 2_400, 3_000, 3_901, 4_500, 4_801, 6_000, 12_000] {
        #expect(bits(zoom.camera(atStep: s)) == bits(zoom.cameraSimulatedFromStart(atStep: s)), "step \(s)")
        let a = zoom.state(atStep: s), b = zoom.stateSimulatedFromStart(atStep: s)
        #expect([a.logDepth, a.center.x, a.center.y].map(\.bitPattern) == [b.logDepth, b.center.x, b.center.y].map(\.bitPattern))
    }
    // The cursor did move the camera.
    #expect(zoom.camera(atStep: 1_234).target != zoom.camera(atStep: 400).target)
}

@Test func zoomOffTheGridIsBetweenTheTwoSteps() {
    let zoom = paths(zoomDocument(regions: [block(1, from: 1, to: 4, focus: .fixed(x: 0.5, y: 0.55))])).zoom
    // Frames of every frame rate land on their steps.
    for frameRate in [24, 25, 30, 50, 60] {
        #expect((0..<(5 * frameRate)).allSatisfy { n in
            let frame = TimeMap.frameTime(n, frameRate: frameRate)
            return zoom.state(atOutput: frame) == zoom.state(atStep: StepGrid.step(frame: n, frameRate: frameRate))
        })
    }
    // Half way between steps 700 and 701 (1.1675 s), where the stage does not hold the crop: half way between them.
    let a = zoom.state(atStep: 700), b = zoom.state(atStep: 701)
    let between = zoom.state(atOutput: 1_167_500_000)
    #expect(abs(between.logDepth - (a.logDepth + b.logDepth) / 2) < 1e-12)
    #expect(near(between.center, (a.center + b.center) / 2, 1e-12))
    #expect(a.logDepth < between.logDepth && between.logDepth < b.logDepth)
}

@Test func aBlockSplitByACutStaysZoomed() {
    // A block over source 1…5 s with 2…3 s cut: one block of 3 s in the output, zoomed all through the cut.
    let motion = paths(
        zoomDocument(sequence: [zoomClip(1, from: 0, to: 2), zoomClip(2, from: 3, to: 20)], regions: [block(1, from: 1, to: 5)]),
        events: [pointer(0, global(SIMD2(0.8, 0.4)))])
    #expect(motion.timeMap.outputRange(ofSource: source(1)..<source(5), take: zoomTakeID) == output(1)..<output(4))
    #expect((step(1.8)..<step(4)).allSatisfy { motion.zoom.state(atStep: $0).logDepth > ln2 - 0.01 })
    #expect(motion.zoom.state(atStep: step(9)).logDepth < 0.01)
}

@Test func handEditedBlocksStayInsideTheStage() {
    // Depths that are not numbers, below 1, infinite; focuses out of the screen or not numbers; overlapping blocks; a
    // block that ends before it starts; one of another take; springs that would diverge at 600 Hz.
    let regions = [
        block(1, from: 0.5, to: 2, depth: .nan), block(2, from: 1.5, to: 3, depth: 0.25, focus: .fixed(x: .nan, y: 3)),
        block(3, from: 3, to: 4, depth: .infinity, focus: .fixed(x: -.infinity, y: .infinity)), block(4, from: 5, to: 4.5),
        block(5, from: 4.5, to: 6, depth: -2, instant: true),
        ZoomRegion(
            id: "z-00000006", take: "take-002", start: source(6), end: source(8), origin: .user, depth: 3, focus: .follow,
            instant: true),
        block(7, from: 6, to: 9, depth: nil),
    ]
    for spring in [medium, SpringSpec(damping: 100, response: 0), SpringSpec(damping: .nan, response: .nan)] {
        var document = zoomDocument(padding: 0.08, regions: regions)
        document.zoom.spring = spring
        let motion = paths(document, events: trail(from: 0, to: 10, sweep))
        let stage = motion.stage.stageSize
        let bad = (0...(10 * 600)).filter { s in
            let state = motion.zoom.state(atStep: s)
            let crop = stage / state.depth
            let low = state.center - crop / 2, high = state.center + crop / 2
            return !(state.logDepth.isFinite && state.logDepth >= 0 && low.x >= -1e-12 && low.y >= -1e-12)
                || !(high.x <= stage.x + 1e-12 && high.y <= stage.y + 1e-12)
        }
        #expect(bad.isEmpty, "\(spring): \(bad.prefix(3))")
        // A block without a depth zooms to the automatic one (2×, `DefaultStyle.toma`).
        #expect(abs(motion.zoom.state(atStep: step(8.9)).logDepth - ln2) < 0.01, "\(spring)")
    }
}

@Test func motionPathsAreOneRevisionOfTheDocument() {
    let document = zoomDocument(padding: 0.08, regions: [block(1, from: 1, to: 4)], smoothing: smoothed)
    let events = trail(from: 0, to: 6, sweep)
    let motion = paths(document, events: events)
    let timeMap = TimeMap(sequence: document.sequence)
    let stage = StagePoints(take: zoomTake(), events: events, document: document)
    let cursor = CursorPath(take: zoomTake(), events: events, style: document.cursor, timeMap: timeMap)
    let zoom = ZoomCameraPath(document: document, timeMap: timeMap, stage: stage, cursor: cursor, take: zoomTake())
    #expect(motion.timeMap == timeMap)
    #expect(stride(from: 0, through: 3_600, by: 7).allSatisfy { s in
        motion.cursor.sample(atStep: s) == cursor.sample(atStep: s) && motion.zoom.state(atStep: s) == zoom.state(atStep: s)
    })
}

// MARK: - StageCrop

@Test func cropOfDepthOneIsTheStage() {
    for aspect in [Aspect.landscape, .portrait, .square] {
        let stage = SIMD2(aspect.ratio, 1)
        let screen = Rect(x: 0.1, y: 0.1, width: aspect.ratio - 0.2, height: 0.8)
        for center in [SIMD2(0.0, 0), SIMD2(5, -5), stage / 2, stage] {
            #expect(StageCrop.clamp(center: center, depth: 1, stage: stage, screen: screen) == stage / 2)
            #expect(StageCrop.clamp(center: center, depth: 0.5, stage: stage, screen: screen) == stage / 2)
        }
    }
}

@Test func cropCoversTheScreenWhereItDoesNotFit() {
    // Screens of every shape inside stages of the three aspects, depths 1 to 4 and centres anywhere: on each axis, the crop
    // is inside the stage, inside the screen where it fits in it, and over the whole screen where it does not.
    var generator = ZoomRandom(seed: 0x636f_7665)
    var bad: [String] = []
    var covered = 0
    for _ in 0..<20_000 {
        let stage = SIMD2([16.0 / 9, 9.0 / 16, 1][Int.random(in: 0..<3, using: &generator)], 1)
        let size = SIMD2(Double.random(in: 0.05...1, using: &generator), Double.random(in: 0.05...1, using: &generator)) * stage
        let place = SIMD2(Double.random(in: 0...1, using: &generator), Double.random(in: 0...1, using: &generator))
        let origin = place * (stage - size)
        let screen = Rect(x: origin.x, y: origin.y, width: size.x, height: size.y)
        let depth = Double.random(in: 1...4, using: &generator)
        let center = SIMD2(Double.random(in: -1...3, using: &generator), Double.random(in: -1...2, using: &generator))
        let placed = StageCrop.clamp(center: center, depth: depth, stage: stage, screen: screen)
        let half = stage / depth / 2
        let low = placed - half, high = placed + half
        for axis in 0..<2 {
            let (a, b) = (origin[axis], origin[axis] + size[axis])
            guard low[axis] >= -1e-12, high[axis] <= stage[axis] + 1e-12 else {
                bad.append("off the stage: \(placed) \(depth) \(screen)")
                continue
            }
            if 2 * half[axis] <= size[axis] {
                if low[axis] < a - 1e-12 || high[axis] > b + 1e-12 { bad.append("off the screen: \(placed) \(depth) \(screen)") }
            } else {
                covered += 1
                if low[axis] > a + 1e-12 || high[axis] < b - 1e-12 { bad.append("screen cut: \(placed) \(depth) \(screen)") }
            }
        }
    }
    #expect(bad.isEmpty, "\(bad.prefix(3))")
    #expect(covered > 1_000)
}

@Test func cropIsContinuousThroughTheScreensSize() {
    // A screen 1.146 wide in a stage 1.778 wide: the crop has its width at depth 1.551. Going through it, the clamped
    // centre of a focus at the right never jumps, and at that depth it is the screen's centre.
    let stage = SIMD2(16.0 / 9, 1)
    let screen = Rect(x: 0.316, y: 0.142, width: 1.146, height: 0.716)
    let threshold = stage.x / screen.width
    let atThreshold = StageCrop.clamp(center: SIMD2(1.6, 0.5), depth: threshold, stage: stage, screen: screen)
    #expect(abs(atThreshold.x - (screen.x + screen.width / 2)) < 1e-12)
    var previous = StageCrop.clamp(center: SIMD2(1.6, 0.5), depth: 2, stage: stage, screen: screen)
    for k in 1...1_000 {
        let depth = 2 - Double(k) / 1_000
        let next = StageCrop.clamp(center: SIMD2(1.6, 0.5), depth: depth, stage: stage, screen: screen)
        #expect(abs(next.x - previous.x) < 0.002, "depth \(depth)")
        previous = next
    }
}

/// SplitMix64: the same numbers on every run.
private struct ZoomRandom: RandomNumberGenerator {
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

/// Every bit of a placed state.
private func bits(_ state: ZoomCameraState) -> [UInt64] {
    [state.logDepth, state.center.x, state.center.y].map(\.bitPattern)
}

@Test func aSpanGivesTheStateOfEachInstant() {
    // A following block over a cursor that never stops, a fixed one, an instant one, a checkpoint and the output's end.
    let document = zoomDocument(
        sequence: [zoomClip(1, from: 0, to: 6)], regions: [
            block(1, from: 0.5, to: 2), block(2, from: 2, to: 3.5, depth: 3, focus: .fixed(x: 0.8, y: 0.2)),
            block(3, from: 4, to: 5, depth: 1.5, focus: .fixed(x: 0.3, y: 0.7), instant: true),
        ], smoothing: smoothed)
    let path = paths(document, events: trail(from: 0, to: 6, sweep)).zoom
    let h = TimeMap.frameTime(1, frameRate: 24) / 2
    for centre in [0.0, 0.5, 0.51, 0.999, 1.0, 1.7, 2.0, 3.5, 4.0, 5.0, 5.99, 6, 7] {
        let t = output(centre)
        let span = path.span(from: t - h, through: t + h)
        for τ in Array(stride(from: t - h, through: t + h, by: 1_234_567)) + [t, t - h - 5_000_000, t + h + 1, t + 2 * h, -1] {
            #expect(bits(span.state(atOutput: τ)) == bits(path.state(atOutput: τ)), "at \(τ)")
        }
    }
    // Inside the instant block, its target itself, read either way.
    let inside = output(4.5)
    #expect(bits(path.span(from: inside, through: inside).state(atOutput: inside)) == bits(path.state(atOutput: inside)))
    #expect(path.state(atOutput: inside).depth == 1.5)
}
