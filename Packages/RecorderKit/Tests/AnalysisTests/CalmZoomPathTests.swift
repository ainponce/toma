// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Testing
@testable import Analysis

// The calm zoom (phase 3 design §6, plan 3b decisions 3 to 5): `CalmZoomPath`, the focus of the calm blocks, simulated
// like the classic camera, which stays at rest in a calm block. Over the take of `ZoomFixtures` with a display of
// 1920×1080 pt, which fills a 16:9 stage without padding (16/9 × 1): a global point `p` is at stage point `p / 1080`.

/// The take of these tests: a display of 1920×1080 pt, with a camera when `camera` is set.
private func calmTake(camera: Bool = false) -> TakeRecord {
    ZoomFixtures.zoomTake(frame: Rect(x: 0, y: 0, width: 1920, height: 1080), camera: camera)
}

private let stageSize = SIMD2(16.0 / 9, 1)
private let stageCentre = stageSize / 2

/// The global point shown at stage point `p`.
private func global(_ p: SIMD2<Double>) -> SIMD2<Double> { p * 1080 }

/// A curve over the display, inside it.
private func roam(_ t: Double) -> SIMD2<Double> {
    SIMD2(960 + 700 * cos(0.9 * t), 540 + 400 * sin(1.3 * t))
}

/// A block of the user's in `mode` (`nil`: classic).
private func calmBlock(
    _ number: Int, _ mode: ZoomMode?, from: Double, to: Double, depth: Double? = 2, focus: ZoomFocus = .follow,
    instant: Bool = false, loupe: LoupeStyle? = nil
) -> ZoomRegion {
    var region = ZoomFixtures.block(number, from: from, to: to, depth: depth, focus: focus, instant: instant)
    region.mode = mode
    region.loupe = loupe
    return region
}

/// Every bit of a calm state; `nil` for none.
private func calmBits(_ state: CalmZoomState?) -> [UInt64]? {
    guard let state else { return nil }
    let values = [state.amount, state.depth, state.blockDepth, state.center.x, state.center.y, state.loupe.radius]
    let modes = ZoomMode.allCases, shapes = LoupeShape.allCases
    return values.map(\.bitPattern)
        + [UInt64(modes.firstIndex(of: state.mode)!), UInt64(shapes.firstIndex(of: state.loupe.shape)!)]
}

/// The classic camera's crop at output time `τ`: its centre ± the stage over twice its depth.
private func crop(_ zoom: ZoomCameraPath, atOutput τ: Int64) -> Rect {
    let state = zoom.state(atOutput: τ)
    let half = stageSize / state.depth / 2
    return Rect(x: state.center.x - half.x, y: state.center.y - half.y, width: 2 * half.x, height: 2 * half.y)
}

private func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    let d = a - b
    return (d.x * d.x + d.y * d.y).squareRoot()
}

/// The stage's camera on every step of the 20 s of output, from one span (a query from a checkpoint for each would
/// simulate some 300 steps for each).
private func everyStep(_ zoom: ZoomCameraPath) -> [ZoomCameraState] {
    let span = zoom.span(from: 0, through: ZoomFixtures.output(20))
    return (0...(20 * 600)).map { span.state(atOutput: StepGrid.outputTime(ofStep: $0)) }
}

/// The card's camera on every step of the 20 s of output, from one span.
private func everyStep(_ zoom: CardZoomPath) -> [CardZoomState] {
    let span = zoom.span(from: 0, through: ZoomFixtures.output(20))
    return (0...(20 * 600)).map { span.state(atOutput: StepGrid.outputTime(ofStep: $0)) }
}

private func nearRect(_ a: Rect, _ b: Rect, _ tolerance: Double) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.width - b.width) <= tolerance
        && abs(a.height - b.height) <= tolerance
}

extension ZoomFixtures {
    @Suite struct CalmZoomPathTests {
        private static func calmPaths(_ document: EditDocument, events: [InputEvent] = [], camera: Bool = false) -> MotionPaths {
            MotionPaths(take: calmTake(camera: camera), events: events, document: document)
        }

        private static var roaming: [InputEvent] { trail(from: 0, to: 20, roam) }

        @Test func calmBlocksLeaveTheCameraAtRest() throws {
            let split = CameraLayout(kind: .split, split: SplitLayout())
            for focus in [ZoomFocus.fixed(x: 0.3, y: 0.7), .follow] {
                for instant in [false, true] {
                    for layout in [CameraLayout.bubble, split] {
                        let regions = [calmBlock(1, .highlight, from: 1, to: 4, focus: focus, instant: instant)]
                        let motion = Self.calmPaths(zoomDocument(regions: regions, layout: layout), events: Self.roaming)
                        let label = "\(focus) instant \(instant) \(layout.kind)"
                        #expect(motion.calmZoom != nil, "\(label)")
                        let moved = everyStep(motion.zoom).enumerated().filter {
                            $0.element.logDepth != 0 || $0.element.center != stageCentre
                        }
                        #expect(moved.isEmpty, "\(label): \(moved.prefix(3))")
                        #expect(motion.zoom.state(atStep: step(2)) == ZoomCameraState(logDepth: 0, center: stageCentre))
                        let frames = (0...1_200).map { TimeMap.frameTime($0, frameRate: 60) }
                        #expect(frames.allSatisfy { motion.zoom.state(atOutput: $0) == ZoomCameraState(logDepth: 0, center: stageCentre) })
                        #expect(motion.zoom.jumps.isEmpty, "\(label)")
                        if layout.kind == .split {
                            let card = try #require(motion.cardZoom)
                            let rest = CardZoomState(logDepth: 0, center: SIMD2(0.5, 0.5))
                            #expect(everyStep(card).allSatisfy { $0 == rest }, "\(label)")
                            #expect(card.jumps.isEmpty, "\(label)")
                        }
                        // The same block classic does move the camera.
                        var classic = regions
                        classic[0].mode = nil
                        let zoomed = Self.calmPaths(zoomDocument(regions: classic, layout: layout), events: Self.roaming)
                        #expect(zoomed.calmZoom == nil && zoomed.zoom.state(atOutput: output(3.5)).logDepth > 0.5, "\(label)")
                    }
                }
            }
        }

        @Test func settledFocusIsTheClassicCrop() throws {
            // Fixed: 2.5 s into the block the spring has settled; the depth is the same in both, bit for bit (the same
            // spring from rest on the same steps), the classic camera's centre a few 1e-10 from the focus.
            for focus in [ZoomFocus.fixed(x: 0.5, y: 0.5), .fixed(x: 0.45, y: 0.56), .fixed(x: 0.52, y: 0.47)] {
                let calm = Self.calmPaths(zoomDocument(regions: [calmBlock(1, .dim, from: 1, to: 4, focus: focus)]))
                let classic = Self.calmPaths(zoomDocument(regions: [calmBlock(1, nil, from: 1, to: 4, focus: focus)]))
                let state = try #require(calm.calmZoom?.state(atOutput: output(3.5)))
                #expect(state.depth == classic.zoom.state(atOutput: output(3.5)).depth)
                let focused = state.focus(stageSize: calm.stage.stageSize), cropped = crop(classic.zoom, atOutput: output(3.5))
                #expect(nearRect(focused, cropped, 1e-9), "\(focus): \(focused) \(cropped)")
            }
            // Following the cursor: the same targets, so from 3 s after entering the centres are one.
            let events = Self.roaming
            let calm = Self.calmPaths(zoomDocument(regions: [calmBlock(1, .loupe, from: 1, to: 8)]), events: events)
            let classic = Self.calmPaths(zoomDocument(regions: [calmBlock(1, nil, from: 1, to: 8)]), events: events)
            let path = try #require(calm.calmZoom)
            var worst = 0.0
            for n in (4 * 60)..<(8 * 60) {
                let τ = TimeMap.frameTime(n, frameRate: 60)
                let focused = try #require(path.state(atOutput: τ)).focus(stageSize: stageSize), cropped = crop(classic.zoom, atOutput: τ)
                worst = max(worst, abs(focused.x - cropped.x), abs(focused.y - cropped.y), abs(focused.width - cropped.width))
            }
            #expect(worst < 1e-6, "\(worst)")
            // The cursor did move it.
            #expect(path.state(atOutput: output(4))!.center != path.state(atOutput: output(7.5))!.center)
        }

        @Test func theFocusAppearsWhereItLooks() throws {
            let events = [pointer(0, global(SIMD2(1.3, 0.3)))]
            for focus in [ZoomFocus.fixed(x: 0.3, y: 0.7), .follow] {
                let motion = Self.calmPaths(
                    zoomDocument(regions: [calmBlock(1, .loupe, from: 1, to: 4, focus: focus)]), events: events)
                let path = try #require(motion.calmZoom)
                let first = step(1)
                #expect(path.state(atOutput: StepGrid.outputTime(ofStep: first - 1)) == nil)
                let entered = try #require(path.state(atOutput: StepGrid.outputTime(ofStep: first)))
                // Where it looks, placed at the block's depth: for a fixed focus, its point of the screen; following, the
                // cursor's.
                let point = switch focus {
                case let .fixed(x, y): SIMD2(x, y) * stageSize
                case .follow: SIMD2(1.3, 0.3)
                }
                let expected = StageCrop.clamp(
                    center: point, depth: 2, stage: stageSize, screen: Rect(x: 0, y: 0, width: stageSize.x, height: 1))
                // The simulation's target, placed: as the classic camera's on that step.
                let target = path.camera.camera(atStep: first).target
                #expect(near(target, expected, 1e-12), "\(focus): \(target) \(expected)")
                let classic = Self.calmPaths(zoomDocument(regions: [calmBlock(1, nil, from: 1, to: 4, focus: focus)]), events: events)
                #expect(target == classic.zoom.camera(atStep: first).target, "\(focus)")
                #expect(entered.center == target, "\(focus)")
                #expect(entered.depth > 1 && entered.depth < 1.01 && entered.blockDepth == 2, "\(focus)")
                // The depth reaches 2 with the spring, never past it, and the centre does not move.
                let steps = Array(stride(from: first, to: step(4), by: 5))
                let depths = steps.map { path.state(atOutput: StepGrid.outputTime(ofStep: $0))!.depth }
                #expect(zip(depths, depths.dropFirst()).allSatisfy { $0 <= $1 } && depths.last! <= 2)
                #expect(abs(depths.last! - 2) < 1e-6)
                #expect(steps.allSatisfy { path.state(atOutput: StepGrid.outputTime(ofStep: $0))!.center == target })
                // Instant: at 2× from the first step.
                let instant = Self.calmPaths(
                    zoomDocument(regions: [calmBlock(1, .loupe, from: 1, to: 4, focus: focus, instant: true)]), events: events)
                let jumped = try #require(instant.calmZoom?.state(atOutput: StepGrid.outputTime(ofStep: first)))
                #expect(abs(jumped.depth - 2) < 1e-12 && jumped.center == target && jumped.amount == 1, "\(focus)")
            }
        }

        @Test func theFocusHoldsWhileItFades() throws {
            // Following the roaming cursor, so the centre is moving when the block ends.
            let motion = Self.calmPaths(zoomDocument(regions: [calmBlock(1, .dim, from: 1, to: 4)]), events: Self.roaming)
            let path = try #require(motion.calmZoom)
            let end = step(4)
            let last = try #require(path.state(atOutput: StepGrid.outputTime(ofStep: end - 1)))
            #expect(path.camera.camera(atStep: end - 1).centerVelocity != .zero)
            var previous = last
            var faded: Int?
            for s in end...(end + CalmZoomPath.responseSteps) {
                guard let state = path.state(atOutput: StepGrid.outputTime(ofStep: s)) else {
                    faded = s
                    break
                }
                #expect(state.center.x.bitPattern == last.center.x.bitPattern && state.center.y.bitPattern == last.center.y.bitPattern)
                #expect(state.mode == .dim && state.blockDepth == 2)
                #expect(state.depth <= previous.depth && state.amount < previous.amount, "step \(s)")
                previous = state
            }
            let gone = try #require(faded)
            #expect(previous.depth < 1 + 1e-9 && previous.amount < 1e-9)
            #expect(((gone)...(gone + 600)).allSatisfy { path.state(atOutput: StepGrid.outputTime(ofStep: $0)) == nil })
            #expect(path.state(atOutput: output(19)) == nil)
        }

        @Test func amountIsTheSpringsStepResponse() throws {
            let document = zoomDocument(regions: [calmBlock(1, .highlight, from: 1, to: 12, focus: .fixed(x: 0.4, y: 0.4))])
            let path = try #require(Self.calmPaths(document).calmZoom)
            let response = CalmZoomPath.stepResponse(of: document.zoom.spring)
            #expect(response.count == 10 * StepGrid.rate)
            let entry = step(1), exit = step(12)
            #expect(path.amount(atStep: entry - 1) == 0)
            #expect((0..<(exit - entry)).allSatisfy { k in
                path.amount(atStep: entry + k) == (k < response.count ? response[k] : 1)
            })
            // From 10 s on, 1.
            #expect((entry + response.count..<exit).allSatisfy { path.amount(atStep: $0) == 1 })
            // Leaving, 11 s after entering: 1 − the response.
            #expect((0..<(20 * 600 - exit)).allSatisfy { k in path.amount(atStep: exit + k) == 1 - response[k] })
            // Between two steps, mixed linearly.
            let τ = StepGrid.outputTime(ofStep: entry + 30) + 700_000
            let (s, fraction) = StepGrid.position(ofOutput: τ)
            let a = path.amount(atStep: s), b = path.amount(atStep: s + 1)
            #expect(fraction > 0 && path.state(atOutput: τ)?.amount == a + (b - a) * fraction)
            // Of a short block, the two responses: what entering reached, less what leaving took.
            let short = try #require(
                Self.calmPaths(zoomDocument(regions: [calmBlock(1, .highlight, from: 1, to: 1.3)])).calmZoom)
            let shortExit = step(1.3)
            #expect((0..<1_200).allSatisfy { k in
                abs(short.amount(atStep: shortExit + k) - (response[shortExit - entry + k] - response[k])) < 1e-15
            })

            // An instant block jumps from 0 to 1 and back on its edges.
            let instant = try #require(
                Self.calmPaths(zoomDocument(regions: [calmBlock(1, .dim, from: 1, to: 4, instant: true)])).calmZoom)
            #expect(instant.amount(atStep: entry - 1) == 0 && instant.amount(atStep: entry) == 1)
            #expect(instant.amount(atStep: step(4) - 1) == 1 && instant.amount(atStep: step(4)) == 0)
            #expect(instant.state(atOutput: output(4)) == nil)

            // An underdamped spring overshoots, but the amount stays from 0 to 1, over blocks close together too.
            var bouncy = zoomDocument(regions: [
                calmBlock(1, .highlight, from: 1, to: 1.4), calmBlock(2, .dim, from: 1.5, to: 3),
                calmBlock(3, .loupe, from: 3.05, to: 3.2), calmBlock(4, .highlight, from: 3.3, to: 6),
            ])
            bouncy.zoom.spring = SpringSpec(damping: 0.3, response: 0.5)
            #expect(CalmZoomPath.stepResponse(of: bouncy.zoom.spring).max()! > 1.2)
            let bouncing = try #require(Self.calmPaths(bouncy).calmZoom)
            let amounts = (0...(20 * 600)).map { bouncing.amount(atStep: $0) }
            #expect(amounts.allSatisfy { (0...1).contains($0) })
            #expect(amounts.contains(1) && amounts[step(3.1)] > 0)
        }

        @Test func touchingCalmBlocksAreOneRun() throws {
            let first = ZoomFocus.fixed(x: 0.3, y: 0.4), second = ZoomFocus.fixed(x: 0.6, y: 0.55)
            let one = try #require(
                Self.calmPaths(zoomDocument(regions: [calmBlock(1, .highlight, from: 1, to: 5, focus: first)])).calmZoom)
            for secondMode in [ZoomMode.highlight, .loupe] {
                let regions = [
                    calmBlock(1, .highlight, from: 1, to: 3, focus: first),
                    calmBlock(2, secondMode, from: 3, to: 5, focus: second, loupe: LoupeStyle(radius: 0.25, shape: .roundedRect)),
                ]
                let path = try #require(Self.calmPaths(zoomDocument(regions: regions)).calmZoom)
                // The amount of one run: that of one block over both, bit for bit, settled from 3 s.
                #expect((0...(20 * 600)).allSatisfy { path.amount(atStep: $0).bitPattern == one.amount(atStep: $0).bitPattern })
                #expect((step(3)..<step(5)).allSatisfy { path.amount(atStep: $0) > 1 - 1e-6 }, "\(secondMode)")
                #expect(
                    (step(1)..<(step(5) - 1)).allSatisfy { path.amount(atStep: $0) <= path.amount(atStep: $0 + 1) }, "\(secondMode)")
                // The centre goes from one focus to the other without a jump; the mode changes on the border's step.
                let border = step(3)
                var previous = try #require(path.state(atOutput: StepGrid.outputTime(ofStep: step(1))))
                for s in step(1)..<step(5) {
                    let state = try #require(path.state(atOutput: StepGrid.outputTime(ofStep: s)))
                    #expect(distance(state.center, previous.center) <= 0.01, "step \(s)")
                    #expect(state.mode == (s < border ? .highlight : secondMode), "step \(s)")
                    #expect(state.loupe == (s < border ? .default : LoupeStyle(radius: 0.25, shape: .roundedRect)))
                    previous = state
                }
                #expect(distance(previous.center, SIMD2(0.6, 0.55) * stageSize) < 1e-3, "\(secondMode)")
            }
        }

        @Test func aCalmBlockSoonAfterAnotherDoesNotJumpWhereItIsSeen() throws {
            let screen = Rect(x: 0, y: 0, width: stageSize.x, height: 1)
            func target(_ x: Double, _ y: Double) -> SIMD2<Double> {
                StageCrop.clamp(center: SIMD2(x, y) * stageSize, depth: 2, stage: stageSize, screen: screen)
            }
            let a = target(0.25, 0.3), b = target(0.75, 0.7)
            // Far apart: a jump from one to the other would be seen.
            #expect(distance(a, b) > 0.5)
            func regions(gap: Double) -> [ZoomRegion] {
                [
                    calmBlock(1, .highlight, from: 1, to: 3, focus: .fixed(x: 0.25, y: 0.3)),
                    calmBlock(2, .loupe, from: 3 + gap, to: 5 + gap, focus: .fixed(x: 0.75, y: 0.7)),
                ]
            }
            // 0.1 s apart: the first is still seen as the second starts, so its focus goes there with the spring.
            let soon = try #require(Self.calmPaths(zoomDocument(regions: regions(gap: 0.1))).calmZoom)
            let entry = step(3.1)
            #expect(soon.amount(atStep: entry - 1) > 0.5)
            #expect(soon.camera.blocks.map(\.focusJumpsIn) == [true, false])
            var previous = try #require(soon.state(atOutput: StepGrid.outputTime(ofStep: step(1))))
            #expect(previous.center == a)
            var largest = 0.0
            for s in (step(1) + 1)..<step(6) {
                let state = try #require(soon.state(atOutput: StepGrid.outputTime(ofStep: s)), "step \(s)")
                largest = max(largest, distance(state.center, previous.center))
                previous = state
            }
            #expect(largest <= 0.01, "\(largest)")
            #expect(distance(try #require(soon.state(atOutput: output(5))).center, b) < 1e-3)
            // 1 s or more apart, nothing of the first is seen any more: the second's focus appears where it looks, as
            // the first one's does.
            for gap in [1.0, 1.5, 3.0] {
                let later = try #require(Self.calmPaths(zoomDocument(regions: regions(gap: gap))).calmZoom)
                let entry = step(3 + gap)
                #expect(later.amount(atStep: entry - 1) < CalmAmount.unseen, "\(gap)")
                #expect(later.camera.blocks.map(\.focusJumpsIn) == [true, true], "\(gap)")
                let entered = try #require(later.state(atOutput: StepGrid.outputTime(ofStep: entry)))
                #expect(entered.center == b && entered.center == later.camera.camera(atStep: entry).target, "\(gap)")
            }
        }

        @Test func classicToCalmHandsOver() throws {
            let events = Self.roaming
            let regions = [calmBlock(1, nil, from: 1, to: 3), calmBlock(2, .dim, from: 3, to: 5, focus: .fixed(x: 0.7, y: 0.3))]
            let motion = Self.calmPaths(zoomDocument(regions: regions), events: events)
            let alone = Self.calmPaths(zoomDocument(regions: [regions[0]]), events: events)
            // The classic camera goes back to rest from 3 s as on its own.
            #expect(motion.zoom.checkpoints.map(bits) == alone.zoom.checkpoints.map(bits))
            #expect(everyStep(motion.zoom).map(bits) == everyStep(alone.zoom).map(bits))
            #expect(motion.zoom.state(atStep: step(3) - 1).logDepth > ln2 - 0.01 && motion.zoom.state(atStep: step(4.5)).logDepth < 0.01)
            // The focus closes from 3 s, where it looks, without a jump nor a number that is not one.
            let path = try #require(motion.calmZoom)
            #expect(path.state(atOutput: StepGrid.outputTime(ofStep: step(3) - 1)) == nil)
            var previous: CalmZoomState?
            for s in step(3)..<(step(5) + 3_000) {
                guard let state = path.state(atOutput: StepGrid.outputTime(ofStep: s)) else { break }
                let rect = state.focus(stageSize: stageSize)
                #expect([state.amount, state.depth, rect.x, rect.y, rect.width, rect.height].allSatisfy { $0.isFinite }, "step \(s)")
                if let previous {
                    #expect(state.center == previous.center && abs(state.depth - previous.depth) < 0.01, "step \(s)")
                    #expect(abs(state.amount - previous.amount) < 0.01, "step \(s)")
                }
                previous = state
            }
            #expect(previous != nil)
        }

        @Test func automaticBlocksFollowTheSettingsMode() throws {
            var automatic = calmBlock(1, nil, from: 1, to: 4, depth: nil)
            automatic.origin = .auto
            var document = zoomDocument(regions: [automatic])
            document.zoom.auto.mode = .dim
            let calm = Self.calmPaths(document, events: Self.roaming)
            let state = try #require(calm.calmZoom?.state(atOutput: output(3)))
            #expect(state.mode == .dim && abs(state.blockDepth - document.zoom.auto.depth) < 1e-12)
            #expect(everyStep(calm.zoom).allSatisfy { $0.logDepth == 0 })
            document.zoom.auto.mode = .classic
            let classic = Self.calmPaths(document, events: Self.roaming)
            #expect(classic.calmZoom == nil)
            #expect(classic.zoom.state(atOutput: output(3)).logDepth > 0.5)
            // A block's own mode wins over the settings'.
            document.zoom.regions[0].mode = .loupe
            #expect(Self.calmPaths(document).calmZoom?.state(atOutput: output(3))?.mode == .loupe)
        }

        /// The documents of `ZoomCameraPathTests` in kind: following and fixed, instant, of the automatic depth, with
        /// the camera's bubble and layouts, a split, padded, reframed, cut, hand-edited and underdamped; and the zoom of
        /// golden 3's documents over this take (`zoomWithBlur`'s block, `layoutBlocks`' layouts with a zoom in the split's
        /// card). Golden 3's own documents are drawn whole by `make golden-3`, byte for byte: building their packages here
        /// would take minutes.
        private static var classicDocuments: [(document: EditDocument, take: TakeRecord, events: [InputEvent])] {
            let sweep = trail(from: 0, to: 20) { t in SIMD2(720 + 760 * cos(1.3 * t), 450 + 480 * sin(2.1 * t)) }
            let regions = [
                block(1, from: 0.5, to: 3.5), block(2, from: 4, to: 6, depth: 3, focus: .fixed(x: 0.9, y: 0.1)),
                block(3, from: 6.5, to: 8, depth: 1.5, instant: true), block(4, from: 8, to: 10, depth: nil),
            ]
            let bubble = CameraStyle(shape: .circle, size: 0.33, anchor: .bottomTrailing)
            let layouts = [
                LayoutBlock(
                    id: "l-00000001", take: zoomTakeID, start: source(2), end: source(5), kind: .split, instant: false,
                    split: SplitLayout()),
                LayoutBlock(
                    id: "l-00000002", take: zoomTakeID, start: source(9), end: source(11), kind: .screenOnly, instant: false),
            ]
            var reframed = zoomDocument(aspect: .portrait, regions: regions)
            reframed.style.reframe = .followCursor
            var bouncy = zoomDocument(padding: 0.08, regions: regions)
            bouncy.zoom.spring = SpringSpec(damping: 0.5, response: 0.3)
            let handEdited = [
                block(1, from: 0.5, to: 2, depth: .nan), block(2, from: 1.5, to: 3, depth: 0.25, focus: .fixed(x: .nan, y: 3)),
                block(3, from: 3, to: 4, depth: .infinity, focus: .fixed(x: -.infinity, y: .infinity)), block(4, from: 5, to: 4.5),
                block(5, from: 4.5, to: 6, depth: -2, instant: true), block(7, from: 6, to: 9, depth: nil),
            ]
            var zoomWithBlur = zoomDocument(regions: [block(1, from: 0.5, to: 2.5, focus: .fixed(x: 0.5, y: 0.5))])
            zoomWithBlur.zoom.motionBlur = 0.5
            zoomWithBlur.cursor.smoothing = smoothed
            func layoutBlock(_ n: Int, _ from: Double, _ to: Double, _ kind: LayoutKind, instant: Bool = false) -> LayoutBlock {
                LayoutBlock(
                    id: "l-0000000\(n)", take: zoomTakeID, start: source(from), end: source(to), kind: kind, instant: instant,
                    bubble: kind == .bubble
                        ? BubbleLayout(style: CameraStyle(shape: .roundedSquare, size: CameraStyle.large, anchor: .topLeading)) : nil,
                    split: kind == .split ? SplitLayout(side: .end) : nil)
            }
            let layoutBlocks = zoomDocument(
                regions: [block(1, from: 0.6, to: 1.35, depth: 1.6, focus: .fixed(x: 0.3, y: 0.35))], bubble: .default,
                layouts: [
                    layoutBlock(1, 0.4, 1.4, .split), layoutBlock(2, 1.4, 2.0, .bubble), layoutBlock(3, 2.0, 2.6, .cameraOnly, instant: true),
                    layoutBlock(4, 2.6, 3.2, .cameraFull), layoutBlock(5, 3.2, 3.8, .screenOnly),
                ])
            let take = zoomTake(), camera = zoomTake(camera: true)
            return [
                (zoomWithBlur, take, sweep),
                (layoutBlocks, camera, sweep),
                (zoomDocument(regions: regions), take, sweep),
                (zoomDocument(regions: regions, show: false), take, sweep),
                (zoomDocument(padding: 0.08, regions: regions, smoothing: smoothed, bubble: bubble), camera, sweep),
                (zoomDocument(regions: regions, bubble: bubble, layouts: layouts), camera, sweep),
                (zoomDocument(regions: regions, layout: CameraLayout(kind: .split, split: SplitLayout())), camera, sweep),
                (reframed, take, sweep),
                (zoomDocument(sequence: [zoomClip(1, from: 0, to: 2), zoomClip(2, from: 3, to: 20)], regions: regions), take, sweep),
                (zoomDocument(sequence: [zoomClip(1, from: 0, to: 30, speed: 3)], regions: regions), take, sweep),
                (zoomDocument(padding: 0.08, regions: handEdited), take, sweep),
                (bouncy, take, sweep),
                (zoomDocument(), take, sweep),
            ]
        }

        /// `paths`' cameras are those of `ZoomCameraPath` and `CardZoomPath` built on their own from the same inputs, bit for
        /// bit, and there is no calm zoom.
        private static func expectThePhase2Zoom(
            _ paths: MotionPaths, document: EditDocument, take: TakeRecord, cameraReadable: Bool = true, _ label: String
        ) {
            #expect(paths.calmZoom == nil, "\(label)")
            let zoom = ZoomCameraPath(
                document: document, timeMap: paths.timeMap, stage: paths.stage, cursor: paths.cursor, take: take,
                cameraReadable: cameraReadable, reframe: paths.reframe)
            #expect(paths.zoom.checkpoints.map(bits) == zoom.checkpoints.map(bits), "\(label)")
            #expect(paths.zoom.jumps == zoom.jumps, "\(label)")
            let card = CardZoomPath(
                document: document, timeMap: paths.timeMap, stage: paths.stage, cursor: paths.cursor, take: take,
                reframe: paths.reframe)
            #expect(paths.cardZoom?.checkpoints.map(bits) == card?.checkpoints.map(bits), "\(label)")
            let steps = stride(from: 0, through: StepGrid.firstStep(atOrAfter: paths.timeMap.duration), by: 37)
            #expect(steps.allSatisfy { bits(paths.zoom.state(atStep: $0)) == bits(zoom.state(atStep: $0)) }, "\(label)")
        }

        @Test func noCalmBlockNoPath() {
            for (k, item) in Self.classicDocuments.enumerated() {
                let motion = MotionPaths(take: item.take, events: item.events, document: item.document)
                Self.expectThePhase2Zoom(motion, document: item.document, take: item.take, "document \(k)")
                // With the automatic blocks' mode calm, a block of the user's without one is still classic.
                var document = item.document
                document.zoom.auto.mode = .loupe
                #expect(MotionPaths(take: item.take, events: item.events, document: document).calmZoom == nil, "document \(k)")
            }
        }

        @Test func classicBlocksBesideACalmOneMoveAsAlone() {
            let events = Self.roaming
            let classic = calmBlock(1, nil, from: 0.5, to: 2)
            for calm in [calmBlock(2, .loupe, from: 6, to: 8), calmBlock(2, .loupe, from: 6, to: 8, instant: true)] {
                let beside = Self.calmPaths(zoomDocument(regions: [classic, calm]), events: events)
                let alone = Self.calmPaths(zoomDocument(regions: [classic]), events: events)
                #expect(beside.zoom.checkpoints.map(bits) == alone.zoom.checkpoints.map(bits))
                #expect(everyStep(beside.zoom).map(bits) == everyStep(alone.zoom).map(bits))
                #expect(beside.zoom.jumps.isEmpty)
            }
            // The overlaps are settled before the blocks are parted: a classic block that starts inside a calm one starts
            // where that one ends, as it did beside a classic one.
            let overlapped = Self.calmPaths(
                zoomDocument(regions: [calmBlock(1, .highlight, from: 1, to: 3), calmBlock(2, nil, from: 2, to: 5, instant: true)]),
                events: events)
            let trimmed = Self.calmPaths(zoomDocument(regions: [calmBlock(2, nil, from: 3, to: 5, instant: true)]), events: events)
            #expect(overlapped.zoom.checkpoints.map(bits) == trimmed.zoom.checkpoints.map(bits))
            #expect(overlapped.zoom.jumps == trimmed.zoom.jumps && overlapped.zoom.jumps.count == 2)
            #expect(overlapped.calmZoom?.state(atOutput: output(2.5)) != nil && overlapped.calmZoom?.state(atOutput: output(3.2)) != nil)
        }

        @Test func editsRebuildBitForBit() throws {
            let events = Self.roaming
            let take = calmTake(camera: true)
            var document = zoomDocument(
                padding: 0.05,
                regions: [
                    calmBlock(1, .highlight, from: 1, to: 3), calmBlock(2, .dim, from: 3.5, to: 5.5, focus: .fixed(x: 0.8, y: 0.3)),
                    calmBlock(3, nil, from: 6, to: 8), calmBlock(4, .loupe, from: 9, to: 11, instant: true),
                    calmBlock(5, .loupe, from: 11, to: 13, depth: 3),
                ],
                smoothing: smoothed, bubble: CameraStyle(shape: .circle, size: 0.3, anchor: .bottomTrailing))
            var paths = MotionPaths(take: take, events: events, document: document)
            /// `document` changed and its paths rebuilt from those before: every checkpoint of both cameras and, on every
            /// frame at 60 fps (`everyFrame`), the calm zoom and the stage's camera, those of the paths built from nothing.
            func edit(_ label: String, everyFrame: Bool = true, _ change: (inout EditDocument) -> Void) {
                let old = paths
                change(&document)
                paths = MotionPaths(take: take, events: events, document: document, after: old)
                let full = MotionPaths(take: take, events: events, document: document)
                #expect(paths.zoom.checkpoints.map(bits) == full.zoom.checkpoints.map(bits), "\(label)")
                #expect((paths.calmZoom == nil) == (full.calmZoom == nil), "\(label)")
                #expect(
                    paths.calmZoom?.camera.checkpoints.map(bits) == full.calmZoom?.camera.checkpoints.map(bits), "\(label)")
                guard everyFrame else { return }
                let zoom = everyStep(paths.zoom), fullZoom = everyStep(full.zoom)
                let differ = (0...(20 * 60)).filter { n in
                    let τ = TimeMap.frameTime(n, frameRate: 60), s = StepGrid.step(frame: n, frameRate: 60)
                    return calmBits(paths.calmZoom?.state(atOutput: τ)) != calmBits(full.calmZoom?.state(atOutput: τ))
                        || bits(zoom[s]) != bits(fullZoom[s])
                }
                #expect(differ.isEmpty, "\(label): frames \(differ.prefix(3))")
            }
            // Only between calm modes: the stage's camera keeps every checkpoint, simulating nothing.
            let before = paths
            edit("highlight to dim") { $0.zoom.regions[0].mode = .dim }
            #expect(paths.zoom.simulatedSteps == 0)
            #expect(paths.zoom.checkpoints.map(bits) == before.zoom.checkpoints.map(bits))
            #expect(paths.calmZoom?.state(atOutput: output(2))?.mode == .dim)
            edit("the loupe's radius") { $0.zoom.regions[4].loupe = LoupeStyle(radius: 0.3) }
            #expect(paths.zoom.simulatedSteps == 0)
            #expect(paths.calmZoom?.state(atOutput: output(12))?.loupe.radius == 0.3)
            edit("a calm block to classic") { $0.zoom.regions[1].mode = .classic }
            edit("trim one") { $0.zoom.regions[0].end = source(2.4) }
            // A block 0.2 s after another: its focus goes there with the spring; the gap made long, it jumps in.
            edit("a block soon after another") {
                $0.zoom.regions.append(calmBlock(7, .dim, from: 2.6, to: 3.4, focus: .fixed(x: 0.2, y: 0.8)))
            }
            func jumpsIn(at seconds: Double) -> Bool? {
                paths.calmZoom?.camera.blocks.first { $0.steps.lowerBound == step(seconds) }?.focusJumpsIn
            }
            #expect(jumpsIn(at: 2.6) == false)
            edit("the gap made long") { $0.zoom.regions[0].end = source(1.5) }
            #expect(jumpsIn(at: 2.6) == true)
            edit("add one") { $0.zoom.regions.append(calmBlock(6, .highlight, from: 15, to: 17, focus: .fixed(x: 0.2, y: 0.2))) }
            edit("the spring") { $0.zoom.spring = SpringSpec(damping: 0.8, response: 0.5) }
            edit("every calm block classic", everyFrame: false) { document in
                for k in document.zoom.regions.indices { document.zoom.regions[k].mode = nil }
            }
            #expect(paths.calmZoom == nil)
            edit("a calm block again", everyFrame: false) { $0.zoom.regions[2].mode = .highlight }
            #expect(paths.calmZoom != nil)
        }

        @Test func zoomShowOffHasNoCalmPath() {
            let regions = [calmBlock(1, .highlight, from: 1, to: 4), calmBlock(2, .loupe, from: 5, to: 7, instant: true)]
            #expect(Self.calmPaths(zoomDocument(regions: regions)).calmZoom != nil)
            #expect(Self.calmPaths(zoomDocument(regions: regions, show: false)).calmZoom == nil)
            // Nor of another take.
            var other = regions
            for k in other.indices { other[k].take = "take-002" }
            #expect(Self.calmPaths(zoomDocument(regions: other)).calmZoom == nil)
        }
    }
}
