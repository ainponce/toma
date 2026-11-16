// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Testing
@testable import Analysis

// The layouts' timeline (1c design §5.1, §5.3 and §5.5) over a take of 20 s, with a screen and a camera from its first
// instant, whose source seconds count from `layoutOrigin`; one clip over the whole take unless a test says otherwise, so
// output seconds are source seconds. Drawn at 1920×1080 with a 16:9 screen, the stage of Toma's style (padding 0.08,
// corners 0.012) and the take's bubble a Medium circle at the bottom right, measured against the height.

private let layoutOrigin = HostTime(nanoseconds: 7_000_000_000_000)
private let layoutTakeID = "take-001"
private let outputSize = SIMD2(1920.0, 1080.0)
private let wide = 16.0 / 9
/// One step of 600 Hz, in output nanoseconds (rounded).
private let step: Int64 = 1_666_667
private let topLeft = CameraStyle(shape: .roundedSquare, size: CameraStyle.large, anchor: .topLeading)

private func source(_ seconds: Double) -> HostTime { layoutOrigin.adding(seconds: seconds) }

/// `seconds` of output, in nanoseconds.
private func output(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

private func segment(_ track: String, from start: Double) -> SegmentRecord {
    SegmentRecord(
        index: 1, file: "takes/\(layoutTakeID)/\(track)/seg-0001.mov", startHostTime: source(start), endHostTime: source(20),
        endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
}

/// The take: a display and a camera whose first segment starts `cameraStart` seconds in.
private func layoutTake(cameraStart: Double = 0) -> TakeRecord {
    let screen = TrackRecord(
        id: "display-1", kind: .display,
        source: TrackSource(name: "Screen", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 1920, height: 1080), pixelScale: 2),
        segments: [segment("display-1", from: 0)])
    let camera = TrackRecord(
        id: "camera-1", kind: .camera, source: TrackSource(name: "Camera"), segments: [segment("camera-1", from: cameraStart)])
    return TakeRecord(
        id: layoutTakeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: [screen, camera])
}

private func clip(_ number: Int, from: Double, to: Double, speed: Double = 1) -> Clip {
    Clip(id: "c-0000000\(number)", take: layoutTakeID, start: source(from), end: source(to), speed: speed)
}

/// A block of `kind` over source seconds `[from, to)`; a Bubble one gets `bubble`, or the large rounded square at the top
/// left.
private func block(
    _ number: Int, _ kind: LayoutKind, from: Double, to: Double, instant: Bool = false, bubble: CameraStyle? = nil,
    split: SplitLayout? = nil
) -> LayoutBlock {
    LayoutBlock(
        id: "l-0000000\(number)", take: layoutTakeID, start: source(from), end: source(to), kind: kind, instant: instant,
        bubble: (bubble ?? (kind == .bubble ? topLeft : nil)).map(BubbleLayout.init), split: split)
}

private func change(_ number: Int, at seconds: Double, _ style: CameraStyle) -> CameraChange {
    CameraChange(id: "k-0000000\(number)", take: layoutTakeID, t: source(seconds), style: style, origin: .recorded)
}

private func layoutDocument(
    blocks: [LayoutBlock] = [], project: CameraLayout = .bubble, changes: [CameraChange] = [],
    sequence: [Clip] = [clip(1, from: 0, to: 20)], show: Bool = true, spring: SpringSpec = CameraLayoutRules.spring
) -> EditDocument {
    let toma = DefaultStyle.toma
    return EditDocument(
        documentVersion: EditDocument.currentVersion, logSequence: 0, aspect: .landscape, frameRate: 60, sequence: sequence,
        screens: ScreenPlan(initial: [layoutTakeID: "display-1"], changes: []), style: toma.style, cursor: toma.cursor,
        zoom: ZoomPlan(show: true, auto: toma.zoomAuto, spring: toma.zoomSpring, motionBlur: 0.5, regions: [], suppressed: []),
        camera: CameraPlan(
            show: show, initial: [layoutTakeID: .default], changes: changes, layout: project, layouts: blocks, spring: spring),
        audio: AudioPlan(limiter: true, tracks: [:]))
}

/// A document's timeline, with what is live at each instant as the render gives it: the take's bubble presented by
/// `CameraBubble` and the screen's aspect.
private struct Scene {
    let document: EditDocument
    let timeMap: TimeMap
    let timeline: LayoutTimeline
    let bubble: CameraBubble?

    init(_ document: EditDocument, take: TakeRecord = layoutTake(), cameraReadable: Bool = true) {
        self.document = document
        timeMap = TimeMap(sequence: document.sequence)
        timeline = LayoutTimeline(document: document, take: take, timeMap: timeMap, cameraReadable: cameraReadable)
        bubble = CameraBubble(document: document, take: take, timeMap: timeMap)
    }

    /// The bubble the take presents at `τ`.
    func takeBubble(at τ: Int64) -> CameraFrame? {
        let host = timeMap.source(atOutput: τ)?.source ?? layoutOrigin
        return bubble?.frame(atOutput: τ, host: host, output: outputSize)
    }

    func inputs(at τ: Int64) -> LayoutInputs {
        LayoutInputs(
            output: outputSize, padding: document.style.padding, cornerRadius: document.style.cornerRadius, screenAspect: wide,
            takeBubble: takeBubble(at: τ), sizeReference: document.camera.sizeReference)
    }

    func geometry(at τ: Int64) -> LayoutGeometry { timeline.geometry(atOutput: τ, inputs(at: τ)) }

    /// What `kind` shows settled at `τ`, its camera in `bubble` or the take's bubble.
    func destination(_ kind: LayoutKind, at τ: Int64, split: SplitLayout? = nil, bubble: CameraFrame? = nil) -> LayoutGeometry {
        let live = inputs(at: τ)
        return CameraLayoutGeometry.geometry(
            kind: kind, split: split, bubble: bubble ?? live.takeBubble, output: live.output, padding: live.padding,
            cornerRadius: live.cornerRadius, screenAspect: live.screenAspect)
    }
}

/// The numbers of a geometry, in a fixed order: the screen's rect, radius and opacity, then the camera's rect, radius,
/// opacity and the weights of its border and its shadow.
private func numbers(_ g: LayoutGeometry) -> [Double] {
    [
        g.screen.rect.x, g.screen.rect.y, g.screen.rect.width, g.screen.rect.height, g.screen.cornerRadius, g.screen.opacity,
        g.camera.rect.x, g.camera.rect.y, g.camera.rect.width, g.camera.rect.height, g.camera.cornerRadius, g.camera.opacity,
        g.camera.borderWeight, g.camera.shadowWeight,
    ]
}

/// The largest change of a number between `a` and `b`. The place and corners of a part count only where it is seen in
/// both (opacity above 0): one that is not seen can be anywhere, so a part that appears can appear where it goes.
private func largestChange(_ a: LayoutGeometry, _ b: LayoutGeometry) -> Double {
    func change(_ x: Double, _ y: Double) -> Double { abs(x - y) }
    func change(_ r: Rect, _ q: Rect) -> Double {
        max(change(r.x, q.x), change(r.y, q.y), change(r.width, q.width), change(r.height, q.height))
    }
    var largest = max(
        change(a.screen.opacity, b.screen.opacity), change(a.camera.opacity, b.camera.opacity),
        change(a.camera.borderWeight, b.camera.borderWeight), change(a.camera.shadowWeight, b.camera.shadowWeight))
    if a.screen.opacity > 0, b.screen.opacity > 0 {
        largest = max(largest, change(a.screen.rect, b.screen.rect), change(a.screen.cornerRadius, b.screen.cornerRadius))
    }
    if a.camera.opacity > 0, b.camera.opacity > 0 {
        largest = max(largest, change(a.camera.rect, b.camera.rect), change(a.camera.cornerRadius, b.camera.cornerRadius))
    }
    return largest
}

private func centre(_ rect: Rect) -> SIMD2<Double> { SIMD2(rect.x + rect.width / 2, rect.y + rect.height / 2) }

private func near(_ a: SIMD2<Double>, _ b: SIMD2<Double>, within tolerance: Double = 1e-6) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
}

private func nearlySame(_ a: LayoutGeometry, _ b: LayoutGeometry, within tolerance: Double) -> Bool {
    zip(numbers(a), numbers(b)).allSatisfy { abs($0 - $1) <= tolerance }
}

/// SplitMix64: the same numbers on every run.
private struct LayoutRandom: RandomNumberGenerator {
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

@Suite struct LayoutTimelineTests {
    /// 200 documents at random, in 8 runs of 25 that go in parallel, each from its fixed seed.
    @Test(arguments: 0..<8) func noJumps(run: Int) {
        var random = LayoutRandom(seed: 0x1C07_7A11 &+ UInt64(run))
        let styles = CameraShape.allCases.flatMap { shape in
            CameraAnchor.allCases.enumerated().map {
                CameraStyle(shape: shape, size: $0.offset % 2 == 0 ? CameraStyle.small : CameraStyle.large, anchor: $0.element)
            }
        }
        func randomSplit() -> SplitLayout? {
            switch Int.random(in: 0..<3, using: &random) {
            case 0: nil
            case 1: SplitLayout(side: .start)
            default: SplitLayout(side: .end, share: Double.random(in: SplitLayout.shareRange, using: &random))
            }
        }
        // The largest change of a number between two steps of 600 Hz, and the steps whose opacities leave 0…1 or whose
        // screen's opacity is not `screenOpacity(atOutput:)`, over the run's documents.
        var worst = 0.0
        var outOfRange = 0, notTheScreensOpacity = 0
        for _ in 0..<25 {
            let sequence: [Clip]
            let cut = Double.random(in: 4..<12, using: &random)
            switch Int.random(in: 0..<3, using: &random) {
            case 0:
                sequence = [clip(1, from: 0, to: 20)]
            case 1:
                let resume = cut + Double.random(in: 0.5..<4, using: &random)
                sequence = [clip(1, from: 0, to: cut), clip(2, from: resume, to: 20)]
            default:
                let speed = [0.5, 1.5, 2][Int.random(in: 0..<3, using: &random)]
                sequence = [clip(1, from: 0, to: cut), clip(2, from: cut, to: 20, speed: speed)]
            }
            var blocks: [LayoutBlock] = []
            var t = Double.random(in: 0..<2, using: &random)
            while t < 19.5, blocks.count < 6 {
                let end = min(t + Double.random(in: 0.3..<4, using: &random), 20)
                let kind = LayoutKind.allCases[Int.random(in: 0..<5, using: &random)]
                let bubble = kind == .bubble || Bool.random(using: &random) ? styles.randomElement(using: &random) : nil
                blocks.append(block(blocks.count + 1, kind, from: t, to: end, bubble: bubble, split: randomSplit()))
                t = end + (Bool.random(using: &random) ? 0 : Double.random(in: 0..<3, using: &random))
            }
            let changes = (0..<Int.random(in: 0..<4, using: &random)).map {
                change($0 + 1, at: Double.random(in: 0..<20, using: &random), styles.randomElement(using: &random)!)
            }
            let project = CameraLayout(kind: LayoutKind.allCases[Int.random(in: 0..<5, using: &random)], split: randomSplit())
            let scene = Scene(layoutDocument(blocks: blocks, project: project, changes: changes, sequence: sequence))

            let spans = scene.timeline.spans
            #expect(spans.first?.output.lowerBound == 0 && spans.last?.output.upperBound == scene.timeMap.duration)
            #expect(zip(spans, spans.dropFirst()).allSatisfy { $0.output.upperBound == $1.output.lowerBound && !$1.output.isEmpty })
            let lastStep = StepGrid.firstStep(atOrAfter: scene.timeMap.duration) + 60
            var before = scene.geometry(at: 0)
            for s in 1...lastStep {
                let τ = StepGrid.outputTime(ofStep: s)
                let now = scene.geometry(at: τ)
                worst = max(worst, largestChange(before, now))
                if s % 7 == 0, scene.timeline.screenOpacity(atOutput: τ) != now.screen.opacity { notTheScreensOpacity += 1 }
                if !(0...1).contains(now.screen.opacity) || !(0...1).contains(now.camera.opacity) { outOfRange += 1 }
                before = now
            }
        }
        #expect(worst <= 0.02 * outputSize.x)
        #expect(outOfRange == 0 && notTheScreensOpacity == 0)
    }

    @Test func settledAtOneAndAHalfSecondsIsExactlyTheTarget() {
        let split = SplitLayout(side: .start, share: 0.4)
        let scene = Scene(layoutDocument(blocks: [block(1, .split, from: 2, to: 10, split: split)]))
        #expect(scene.geometry(at: output(3.5)) == scene.destination(.split, at: output(3.5), split: split))
        #expect(scene.geometry(at: output(3.5) - 1) != scene.destination(.split, at: output(3.5) - 1, split: split))
        #expect(scene.geometry(at: output(7)) == scene.destination(.split, at: output(7), split: split))
    }

    @Test func burstStartsFromWhatWasShown() {
        let scene = Scene(layoutDocument(blocks: [block(1, .cameraFull, from: 1, to: 1.3), block(2, .split, from: 1.3, to: 10)]))
        let border = output(1.3)
        // Nothing jumps at the second border: it starts from what was shown, not from the first block's destination.
        #expect(nearlySame(scene.geometry(at: border - 1), scene.geometry(at: border), within: 1e-4))
        #expect(scene.geometry(at: border) != scene.destination(.cameraFull, at: border))
        #expect(scene.geometry(at: border).camera.rect.width < outputSize.x - 1)
        // 1.5 s after it, exactly the second block's destination.
        #expect(scene.geometry(at: output(2.8)) == scene.destination(.split, at: output(2.8)))
        #expect(scene.geometry(at: output(2.8) - 1) != scene.destination(.split, at: output(2.8) - 1))
    }

    @Test func instantJumps() {
        let scene = Scene(layoutDocument(blocks: [block(1, .cameraFull, from: 2, to: 4, instant: true)]))
        let (start, end) = (output(2), output(4))
        #expect(scene.geometry(at: start) == scene.destination(.cameraFull, at: start))
        #expect(scene.geometry(at: start - step) == scene.destination(.bubble, at: start - step))
        #expect(scene.geometry(at: end) == scene.destination(.bubble, at: end))
        #expect(scene.geometry(at: end - step) == scene.destination(.cameraFull, at: end - step))
    }

    @Test func instantNextToSmoothStartsFromWhatWasShown() {
        let smooth = block(3, .cameraFull, from: 2.3, to: 8)
        let scene = Scene(layoutDocument(blocks: [
            block(1, .split, from: 1, to: 1.6), block(2, .cameraOnly, from: 1.6, to: 2, instant: true), smooth,
        ]))
        let border = output(1.6)
        // Halfway into the split, the instant block jumps to its destination.
        let before = scene.geometry(at: border - 1)
        #expect(before.camera.rect != scene.destination(.split, at: border - 1).camera.rect)
        #expect(before.camera.rect != scene.destination(.cameraOnly, at: border - 1).camera.rect)
        let jumped = scene.geometry(at: border)
        #expect(jumped.camera == scene.destination(.cameraOnly, at: border).camera)
        #expect(jumped.screen.opacity == 0)
        // It leaves as it came, and the next smooth border starts from there: the same as with that block alone.
        #expect(scene.geometry(at: output(2)) == scene.destination(.bubble, at: output(2)))
        let alone = Scene(layoutDocument(blocks: [smooth]))
        for τ in stride(from: output(2), through: output(4), by: Int(step)) {
            #expect(scene.geometry(at: τ) == alone.geometry(at: τ))
        }
        #expect(scene.geometry(at: output(2.3)) == scene.destination(.bubble, at: output(2.3)))
        #expect(scene.geometry(at: output(2.4)) != scene.destination(.bubble, at: output(2.4)))
    }

    @Test func blockAtZeroIsInPlaceOnTheFirstFrame() {
        let scene = Scene(layoutDocument(blocks: [block(1, .cameraFull, from: 0, to: 5)]))
        #expect(scene.timeline.spans.first?.blockID == "l-00000001")
        #expect(scene.timeline.spans.first?.output.lowerBound == 0)
        #expect(scene.geometry(at: 0) == scene.destination(.cameraFull, at: 0))
        #expect(scene.geometry(at: output(1)) == scene.destination(.cameraFull, at: output(1)))
    }

    @Test func blockToTheEndNeverLeaves() {
        let scene = Scene(layoutDocument(blocks: [block(1, .cameraOnly, from: 10, to: 20)]))
        let end = scene.timeMap.duration
        #expect(scene.timeline.spans.count == 2)
        #expect(scene.timeline.spans.last?.blockID == "l-00000001" && scene.timeline.spans.last?.output.upperBound == end)
        #expect(scene.geometry(at: end - 1) == scene.destination(.cameraOnly, at: end - 1))
        #expect(scene.geometry(at: end) == scene.destination(.cameraOnly, at: end))

        // At 3×, a block made up to the end of the output (plan decision 9: its end goes back to the source as the source
        // of the output's last nanosecond and 1 ns more) maps back 1 ns short of it: it still reaches the end.
        let fast = [clip(1, from: 0, to: 15, speed: 3)]
        let map = TimeMap(sequence: fast)
        let start = map.source(atOutput: output(2))!.source
        let last = HostTime(nanoseconds: map.source(atOutput: map.duration - 1)!.source.nanoseconds + 1)
        #expect(map.outputRange(ofSource: start..<last, take: layoutTakeID)?.upperBound == map.duration - 1)
        let made = LayoutBlock(id: "l-00000002", take: layoutTakeID, start: start, end: last, kind: .cameraFull, instant: false)
        let fastScene = Scene(layoutDocument(blocks: [made], sequence: fast))
        #expect(fastScene.timeline.spans.count == 2)
        #expect(fastScene.timeline.spans.last?.output == output(2)..<map.duration)
        #expect(fastScene.geometry(at: map.duration - 1) == fastScene.destination(.cameraFull, at: map.duration - 1))
    }

    @Test func shortBlockNeverJumps() {
        let scene = Scene(layoutDocument(blocks: [block(1, .cameraFull, from: 5, to: 5.6)]))
        let full = Rect(x: 0, y: 0, width: outputSize.x, height: outputSize.y)
        var before = scene.geometry(at: output(4.9))
        var τ = output(4.9) + step
        while τ < output(7.5) {
            let now = scene.geometry(at: τ)
            #expect(largestChange(before, now) <= 0.02 * outputSize.x)
            if τ >= output(5), τ < output(5.6) {
                #expect(now.camera.rect != full && now.camera.rect.width < outputSize.x)
            }
            before = now
            τ += step
        }
        // It went most of the way.
        #expect(scene.geometry(at: output(5.6) - 1).camera.rect.width > 0.99 * outputSize.x)
    }

    @Test func bordersFollowCutsAndSpeed() {
        // A cut from 5 s to 8 s: a block from 6 s starts at the first instant kept, output 5 s, and ends at 10 s, output 7 s.
        let cut = Scene(layoutDocument(
            blocks: [block(1, .split, from: 6, to: 10)], sequence: [clip(1, from: 0, to: 5), clip(2, from: 8, to: 20)]))
        #expect(cut.timeline.spans.map(\.output) == [0..<output(5), output(5)..<output(7), output(7)..<output(17)])
        #expect(cut.timeline.span(atOutput: output(5)).blockID == "l-00000001")
        #expect(cut.timeline.span(atOutput: output(5) - 1).blockID == nil)
        // At 2× from 5 s on, the same 4 s of source last 2 s.
        let fast = Scene(layoutDocument(
            blocks: [block(1, .split, from: 6, to: 10)], sequence: [clip(1, from: 0, to: 5), clip(2, from: 5, to: 13, speed: 2)]))
        let span = fast.timeline.spans[1]
        #expect(span.blockID == "l-00000001" && span.output == output(5.5)..<output(7.5))
        #expect(fast.geometry(at: output(5.5) - 1) == fast.destination(.bubble, at: output(5.5) - 1))
        #expect(fast.geometry(at: output(7)) == fast.destination(.split, at: output(7)))
    }

    @Test func blockEntirelyInACutIsNotShown() {
        let blocks = [block(1, .cameraFull, from: 6, to: 7.5)]
        let cut = Scene(layoutDocument(blocks: blocks, sequence: [clip(1, from: 0, to: 5), clip(2, from: 8, to: 20)]))
        #expect(cut.timeline.spans.count == 1 && cut.timeline.spans[0].blockID == nil)
        #expect(cut.timeline.isTrivial)
        for τ in stride(from: Int64(0), to: cut.timeMap.duration, by: Int(step) * 7) {
            #expect(cut.geometry(at: τ) == cut.destination(.bubble, at: τ))
        }
        let recovered = Scene(layoutDocument(blocks: blocks))
        #expect(recovered.timeline.spans.map(\.blockID) == [nil, "l-00000001", nil])
        #expect(recovered.timeline.spans[1].output == output(6)..<output(7.5))
        #expect(!recovered.timeline.isTrivial)
    }

    @Test func changesInsideABlockAreHiddenButStillCount() {
        let inside = change(1, at: 3, topLeft)
        let outside = change(2, at: 8, .default)
        let document = layoutDocument(blocks: [block(1, .split, from: 2, to: 4)], changes: [inside, outside])
        let scene = Scene(document)
        #expect(scene.timeline.hiddenChanges(document) == ["k-00000001": "l-00000001"])
        // Leaving the block toward the project's Bubble, the destination is the take's bubble of that instant, the change
        // inside the block included.
        let region = Rect(x: 0, y: 0, width: outputSize.x, height: outputSize.y)
        #expect(scene.takeBubble(at: output(5.5)) == topLeft.frame(in: region))
        #expect(scene.geometry(at: output(5.5)).camera.rect == topLeft.frame(in: region).rect)
        #expect(scene.geometry(at: output(5.5)) == scene.destination(.bubble, at: output(5.5)))
        #expect(scene.geometry(at: output(4.5)).camera.rect != scene.destination(.bubble, at: output(4.5)).camera.rect)
    }

    @Test func recordedSpringUnderWayAtABorderIsContinuous() {
        let scene = Scene(layoutDocument(blocks: [block(1, .cameraFull, from: 2, to: 6)], changes: [change(1, at: 1.9, topLeft)]))
        let border = output(2)
        let region = Rect(x: 0, y: 0, width: outputSize.x, height: outputSize.y)
        let presented = scene.takeBubble(at: border)!
        #expect(presented != topLeft.frame(in: region) && presented != CameraStyle.default.frame(in: region))
        #expect(scene.geometry(at: border).camera.rect == presented.rect)
        #expect(scene.geometry(at: border).camera.cornerRadius == presented.cornerRadius)
        #expect(nearlySame(scene.geometry(at: border - 1), scene.geometry(at: border), within: 1e-4))
        #expect(largestChange(scene.geometry(at: border - step), scene.geometry(at: border + step)) <= 0.02 * outputSize.x)
    }

    @Test func trivialDocumentIsThe1bBubble() {
        let scene = Scene(layoutDocument(changes: [change(1, at: 3, topLeft), change(2, at: 3.4, .default)]))
        #expect(scene.timeline.isTrivial && !scene.timeline.hasSplit)
        #expect(scene.timeline.spans == [
            LayoutSpan(kind: .bubble, instant: false, output: 0..<scene.timeMap.duration),
        ])
        for τ in stride(from: Int64(0), through: output(6), by: Int(step)) {
            #expect(scene.geometry(at: τ).camera.rect == scene.takeBubble(at: τ)!.rect)
            #expect(scene.geometry(at: τ) == scene.destination(.bubble, at: τ))
        }
        #expect(!Scene(layoutDocument(project: CameraLayout(kind: .split))).timeline.isTrivial)
        #expect(!Scene(layoutDocument(blocks: [block(1, .bubble, from: 2, to: 3)])).timeline.isTrivial)
    }

    @Test func cameraOffOrUnreadableIsScreenOnly() {
        let blocks = [block(1, .cameraFull, from: 2, to: 6), block(2, .split, from: 8, to: 9)]
        for (show, readable) in [(false, true), (true, false)] {
            let document = layoutDocument(blocks: blocks, project: CameraLayout(kind: .cameraOnly), show: show)
            let scene = Scene(document, cameraReadable: readable)
            #expect(scene.timeline.spans.map(\.kind) == [.screenOnly, .screenOnly, .screenOnly, .screenOnly, .screenOnly])
            #expect(scene.timeline.span(atOutput: output(3)).blockID == "l-00000001")
            #expect(!scene.timeline.hasSplit && !scene.timeline.isTrivial)
            #expect(scene.document.camera.layouts == blocks && scene.document.camera.layout.kind == .cameraOnly)
            for seconds in [1.0, 2.5, 4.0, 8.5] {
                // A blend of two equal numbers can round 1 ulp away from them.
                let g = scene.geometry(at: output(seconds))
                #expect(g.camera.opacity == 0 && abs(g.screen.opacity - 1) < 1e-15)
                #expect(abs(scene.timeline.screenOpacity(atOutput: output(seconds)) - 1) < 1e-15)
            }
        }
        #expect(Scene(layoutDocument(blocks: blocks)).timeline.hasSplit)
    }

    @Test func screenOpacityIsZeroUnderFullCamera() {
        let scene = Scene(layoutDocument(blocks: [block(1, .cameraFull, from: 2, to: 8)]))
        let timeline = scene.timeline
        #expect(timeline.screenOpacity(atOutput: output(1)) == 1)
        #expect(timeline.screenOpacity(atOutput: output(5)) == 0)
        #expect(timeline.screenOpacity(atOutput: output(10)) == 1)
        let halfway = timeline.screenOpacity(atOutput: output(2.15))
        #expect(halfway > 0 && halfway < 1)
        for seconds in stride(from: 1.9, through: 10, by: 0.05) {
            let τ = output(seconds)
            #expect(timeline.screenOpacity(atOutput: τ) == scene.geometry(at: τ).screen.opacity)
        }
    }

    // MARK: - Beyond the brief's list

    @Test func theSpringIsTheDocuments() {
        // With the design's spring, the bubble's own: `CameraStyleTimeline.progress`, bit for bit, done at 1.5 s.
        let response = LayoutTimeline.StepResponse(CameraLayoutRules.spring)
        #expect(response.settleSeconds == CameraStyleTimeline.settleSeconds)
        for i in -10...2_000 {
            let t = Double(i) / 1000 + 0.000_013 * Double(i % 7)
            #expect(response.progress(seconds: t).bitPattern == CameraStyleTimeline.progress(seconds: t).bitPattern)
        }
        #expect(response.progress(seconds: .nan) == 0)
        // Any other spring is its step response, done once it has decayed as far, without a visible jump there.
        for spring in [
            SpringSpec(damping: 1, response: 0.3), SpringSpec(damping: 0.5, response: 0.5), SpringSpec(damping: 1.6, response: 0.4),
            SpringSpec(damping: 0.95, response: 1), SpringSpec(damping: .nan, response: .nan), SpringSpec(damping: 0.2, response: 0.01),
        ] {
            let p = LayoutTimeline.StepResponse(spring)
            #expect(p.progress(seconds: 0) == 0 && p.progress(seconds: p.settleSeconds) == 1)
            #expect(abs(1 - p.progress(seconds: p.settleSeconds.nextDown)) < 1e-6)
        }
        let critical = LayoutTimeline.StepResponse(SpringSpec(damping: 1, response: 0.3))
        for t in stride(from: 0.01, to: critical.settleSeconds, by: 0.01) {
            let omega = 2 * Double.pi / 0.3
            #expect(abs(critical.progress(seconds: t) - (1 - (1 + omega * t) * exp(-omega * t))) < 1e-12)
        }
        // A slower spring in the document is still moving where the design's has arrived.
        let slow = SpringSpec(damping: 0.95, response: 1)
        let scene = Scene(layoutDocument(blocks: [block(1, .cameraFull, from: 2, to: 10)], spring: slow))
        #expect(LayoutTimeline.StepResponse(slow).settleSeconds == 3)
        #expect(scene.geometry(at: output(3.5)) != scene.destination(.cameraFull, at: output(3.5)))
        #expect(scene.geometry(at: output(5)) == scene.destination(.cameraFull, at: output(5)))
    }

    @Test func whatAppearsOrLeavesStaysInPlace() {
        // Screen only → Split: the camera appears in its card, from 90 % of it, without sliding from the bubble's corner.
        let appearing = Scene(layoutDocument(
            blocks: [block(1, .split, from: 2, to: 10)], project: CameraLayout(kind: .screenOnly)))
        let card = appearing.destination(.split, at: output(3)).camera
        for seconds in stride(from: 2.0, through: 3.6, by: 0.05) {
            let camera = appearing.geometry(at: output(seconds)).camera
            #expect(near(centre(camera.rect), centre(card.rect)))
            #expect(camera.rect.width >= 0.9 * card.rect.width - 1e-6 && camera.rect.width <= card.rect.width * 1.001)
        }
        #expect(appearing.geometry(at: output(2)).camera.opacity == 0)
        // Split → Camera only: the screen fades where its card was, at 90 % at most, while the camera grows.
        let leaving = Scene(layoutDocument(
            blocks: [block(1, .split, from: 0, to: 2), block(2, .cameraOnly, from: 2, to: 10)]))
        let screen = leaving.destination(.split, at: output(1)).screen
        for seconds in stride(from: 2.0, through: 3.6, by: 0.05) {
            let g = leaving.geometry(at: output(seconds))
            #expect(near(centre(g.screen.rect), centre(screen.rect)))
            #expect(g.screen.rect.width <= screen.rect.width * 1.001 && g.screen.rect.width >= 0.9 * screen.rect.width * 0.999)
        }
        let settled = leaving.geometry(at: output(4))
        #expect(settled.camera == leaving.destination(.cameraOnly, at: output(4)).camera && settled.screen.opacity == 0)
        // Bubble → Camera full screen: the bubble grows to the edges while the screen fades under it, in place.
        let growing = Scene(layoutDocument(blocks: [block(1, .cameraFull, from: 2, to: 10)]))
        let stage = growing.destination(.bubble, at: output(1)).screen
        let halfway = growing.geometry(at: output(2.2))
        #expect(near(centre(halfway.screen.rect), centre(stage.rect)) && halfway.camera.rect.width > 300)
    }

    @Test func blocksPlacedAsTheZoomsAre() {
        // At most 1 ns apart they touch; one that starts inside the one before (a document edited by hand) starts where
        // that one ends; one entirely inside the one before is not shown.
        let a = block(1, .split, from: 2, to: 4)
        var b = block(2, .cameraOnly, from: 4, to: 6)
        b.start = HostTime(nanoseconds: b.start.nanoseconds + 1)
        let c = block(3, .cameraFull, from: 5.5, to: 7)
        let d = block(4, .bubble, from: 6, to: 6.5)
        let scene = Scene(layoutDocument(blocks: [c, a, d, b]))
        #expect(scene.timeline.spans.map(\.blockID) == [nil, "l-00000001", "l-00000002", "l-00000003", nil])
        #expect(scene.timeline.spans.map(\.output) == [
            0..<output(2), output(2)..<(output(4) + 1), (output(4) + 1)..<output(6), output(6)..<output(7), output(7)..<output(20),
        ])
        // Blocks of another take, or empty, are not this take's.
        var other = block(5, .cameraFull, from: 10, to: 12)
        other.take = "take-002"
        let empty = block(6, .cameraFull, from: 14, to: 14)
        #expect(Scene(layoutDocument(blocks: [other, empty])).timeline.spans.count == 1)
    }

    @Test func aBubbleBlockWaitsForTheCamerasFirstFrame() {
        // As the take's bubble in 1b: nothing before the camera's first segment.
        let scene = Scene(layoutDocument(blocks: [block(1, .bubble, from: 0, to: 5)]), take: layoutTake(cameraStart: 1))
        #expect(scene.takeBubble(at: output(0.5)) == nil)
        #expect(scene.geometry(at: output(0.5)).camera.opacity == 0)
        let region = Rect(x: 0, y: 0, width: outputSize.x, height: outputSize.y)
        #expect(scene.geometry(at: output(2)).camera.rect == topLeft.frame(in: region, reference: .height).rect)
        #expect(scene.geometry(at: output(2)).camera.opacity == 1)
        #expect(scene.timeline.spans[0].bubbleStyle == topLeft)
    }
}
