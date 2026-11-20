// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreText
import Foundation
import ProjectFormat
import RecorderKitTestSupport
// @testable for `AnnotationScene`, `AnnotationTypography` and `FrameEvaluator.frame(at:)`.
@testable import Render
import Testing

// The annotations' scene (`annotation-1`, phase 3 design §5.1 and §5.5, plan 3a task A5): where each annotation stuck to
// the recording is (on the same pixel of the content whatever the padding, the format, the frame, the reframe or the
// Area), when each is shown (its source range of the take, its output range, the whole video, a clip cut to its file),
// the order of the layers in each group, the steps' numbers and the texts' boxes. The takes here are 4 s of display 1
// without files, as the frames' geometry needs nothing of their video; the golden documents' are written for the legacy
// check alone.

private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)

/// Output nanoseconds of `seconds`.
private func ns(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

/// Stuck to the take's source from `from` to `to` seconds of it.
private func stuck(_ from: Double, _ to: Double, take: String = takeID) -> AnnotationAnchor {
    .content(take: take, start: base.adding(seconds: from), end: base.adding(seconds: to))
}

/// Over the output from `from` to `to` seconds.
private func over(_ from: Double, _ to: Double) -> AnnotationAnchor { .output(start: ns(from), end: ns(to)) }

private func text(_ string: String = "Text", preset: TextPreset = .plain, size: Double = 0.05) -> AnnotationKind {
    .text(TextAnnotation(string: string, preset: preset, size: size))
}

private let square = AnnotationKind.shape(ShapeAnnotation(shape: .rect))

/// Annotation `number` (`a-` and its 8 hex digits), with no entrance nor exit unless given.
private func annotation(
    _ number: Int, _ anchor: AnnotationAnchor, _ kind: AnnotationKind, rect: NormalizedRect = NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.1),
    layer: Int = 0, enter: AnnotationEnter = .none, exit: AnnotationExit = .none
) -> Annotation {
    Annotation(id: String(format: "a-%08x", number), anchor: anchor, layer: layer, kind: kind, rect: rect, enter: enter, exit: exit)
}

/// The legacy document of `take` with `annotations`.
private func document(_ take: TakeRecord, _ events: [InputEvent] = [], _ annotations: [Annotation]) -> EditDocument {
    var document = EditDocument.legacy(take: take, events: events)
    document.annotations = AnnotationPlan(items: annotations)
    return document
}

/// A take of 4 s of display 1 and, with `camera`, a camera.
private func fourSecondTake(camera: Bool = false, globalFrame: Rect = screenFrame, captureArea: Rect? = nil) -> TakeRecord {
    let end = base.adding(seconds: 4)
    var tracks = [displayTrack(globalFrame: globalFrame, captureArea: captureArea, segments: [segment(start: base, end: end)])]
    if camera {
        tracks.append(displayTrack(id: cameraID, kind: .camera, globalFrame: nil, segments: [segment(track: cameraID, start: base, end: end)]))
    }
    return makeTake(tracks: tracks)
}

/// A clip of the take from `from` to `to` seconds of it.
private func clip(_ number: Int, _ from: Double, _ to: Double, content: ClipContent? = nil) -> Clip {
    Clip(
        id: String(format: "c-%08x", number), take: takeID, start: base.adding(seconds: from), end: base.adding(seconds: to),
        speed: 1, content: content)
}

/// Whether `a` and `b` are the same within `tolerance`.
private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

private func close(_ a: Rect, _ b: Rect, _ tolerance: Double = 1e-6) -> Bool {
    close(a.x, b.x, tolerance) && close(a.y, b.y, tolerance) && close(a.width, b.width, tolerance)
        && close(a.height, b.height, tolerance)
}

/// `rect`, in fractions of `layer`'s crop as it is drawn, in the stage's coordinates of `layer.rect`.
private func onTheLayer(_ rect: Rect, _ layer: ScreenLayer) -> Rect {
    Rect(
        x: layer.rect.x + rect.x * layer.rect.width, y: layer.rect.y + rect.y * layer.rect.height,
        width: rect.width * layer.rect.width, height: rect.height * layer.rect.height)
}

// MARK: - The legacy documents

/// The cases of golden 3 as the app opens them (their recorded JSON decoded, so migrated): no annotation, so the scene has
/// none of either group at any of their times, and their frames none. Their takes are written at once, each in its folder.
@Test func noAnnotationsNoLayers() async throws {
    try await withTemporaryDirectory { dir in
        let projects = try await withThrowingTaskGroup(of: (String, LoadedProject).self) { group in
            for golden in GoldenDocuments.golden3Cases {
                let folder = dir.appending(path: golden.name, directoryHint: .isDirectory)
                group.addTask {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    return (golden.name, try await GoldenDocuments.makeProject(golden.name, in: folder))
                }
            }
            return try await group.reduce(into: [String: LoadedProject]()) { $0[$1.0] = $1.1 }
        }
        for golden in GoldenDocuments.golden3Cases {
            let project = try #require(projects[golden.name])
            let made = try GoldenDocuments.makeDocument(golden.name, for: project)
            let document = try EditDocument.decode(try GoldenDocuments.recordedJSON(of: made, for: golden))
            try #require(document.annotations == .legacy, "\(golden.name)")
            let size = GoldenDocuments.outputSize(of: golden, document: document, project: project)
            let timeMap = TimeMap(sequence: document.sequence)
            let scene = AnnotationScene(document: document, take: project.take, events: project.events, timeMap: timeMap, outputSize: size)
            let frames = FrameEvaluator(take: project.take, events: project.events, document: document, outputSize: size)
            for time in golden.times {
                let frame = frames.frame(at: time)
                let τ = min(max(ns(time), 0), timeMap.duration - 1)
                let source = try #require(timeMap.source(atOutput: τ)).source
                #expect(scene.content(atSource: source, output: τ, frame: frame).isEmpty, "\(golden.name) at \(time) s")
                #expect(scene.output(atOutput: τ).isEmpty, "\(golden.name) at \(time) s")
                #expect(frame.contentAnnotations.isEmpty && frame.outputAnnotations.isEmpty, "\(golden.name) at \(time) s")
            }
        }
    }
}

// MARK: - Where

@Test func contentAnnotationFollowsTheContent() throws {
    let take = fourSecondTake()
    let events = cursorEvents(from: base, seconds: 4, across: screenFrame)
    let rect = NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.1)
    let window = WindowFrame.macWindow(appearance: .dark, title: "Toma", buttons: true)
    var cases: [(name: String, take: TakeRecord, document: EditDocument, size: SIMD2<Int>)] = []
    for padding in [0.1, 0.2] {
        for aspect in [Aspect.landscape, .portrait] {
            for frame in [WindowFrame.none, window] {
                var stuckText = document(take, events, [annotation(1, stuck(0, 4), text(), rect: rect)])
                stuckText.style.padding = padding
                stuckText.aspect = aspect
                stuckText.style.frame = frame
                cases.append(("padding \(padding), \(aspect.rawValue), \(frame == .none ? "no frame" : "window")", take, stuckText,
                    StageLayout.outputSize(aspect: aspect, shortSide: 720)))
            }
        }
    }
    // And through a zoom of 2×, which moves the whole stage: the box stays in the stage's coordinates, on the screen's.
    var zoomed = document(take, events, [annotation(1, stuck(0, 4), text(), rect: rect)])
    zoomed.zoom.regions = [StageDrawing.zoom(1, from: 0.5, to: 3.5, depth: 2, focus: .fixed(x: 0.3, y: 0.4))]
    cases.append(("zoomed", take, zoomed, [1280, 720]))
    // And on the screen's card of a split, which the camera's card sits beside.
    let withCamera = fourSecondTake(camera: true)
    var split = document(withCamera, events, [annotation(1, stuck(0, 4), text(), rect: rect)])
    split.camera.layouts = [LayoutBlock(
        id: "l-00000001", take: takeID, start: base, end: base.adding(seconds: 4), kind: .split, instant: true, split: SplitLayout())]
    cases.append(("split", withCamera, split, [1280, 720]))
    for c in cases {
        let scene = FrameEvaluator(take: c.take, events: events, document: c.document, outputSize: c.size)
        for t in [0.5, 2.0] {
            let frame = scene.frame(at: t)
            let screen = try #require(frame.screen, "\(c.name)")
            let layer = try #require(frame.contentAnnotations.first, "\(c.name) at \(t) s")
            #expect(frame.contentAnnotations.count == 1)
            // The whole frame is the content: the rect in fractions of it, carried to the crop drawn and to its rect.
            let crop = screen.crop
            let inCrop = Rect(
                x: (rect.x - crop.x) / crop.width, y: (rect.y - crop.y) / crop.height, width: rect.width / crop.width,
                height: rect.height / crop.height)
            // The text's box starts there and is as wide; its height is its line's.
            let expected = onTheLayer(inCrop, screen)
            #expect(
                close(layer.rect.x, expected.x) && close(layer.rect.y, expected.y) && close(layer.rect.width, expected.width),
                "\(c.name) at \(t) s: \(layer.rect) on \(screen)")
            let space = onTheLayer(
                Rect(x: -crop.x / crop.width, y: -crop.y / crop.height, width: 1 / crop.width, height: 1 / crop.height), screen)
            #expect(close(layer.space, space) && close(layer.unit, space.height), "\(c.name) at \(t) s")
        }
    }
    #expect(FrameEvaluator(take: take, events: events, document: zoomed, outputSize: [1280, 720]).frame(at: 2).stage != nil)
    #expect(FrameEvaluator(take: withCamera, events: events, document: split, outputSize: [1280, 720]).frame(at: 2).isCardMode)
}

@Test func followsTheReframeAndTheArea() throws {
    // A privacy block and a shape stuck to the recording with the same rect cover the same content: in Area mode, through
    // a change of the display's shape that cuts the crop on its way (the spring), and following the cursor in 9:16.
    let hidden = NormalizedRect(x: 0.4, y: 0.3, width: 0.2, height: 0.25)
    func block() -> PrivacyBlock {
        PrivacyBlock(
            id: "p-00000001", take: takeID, start: base, end: base.adding(seconds: 4), effect: .fill, strength: 1,
            color: RGBA(0, 0, 0, 1), rect: hidden, keys: [])
    }
    let area = fourSecondTake(captureArea: Rect(x: 40, y: 20, width: 560, height: 320))
    let reshaped = [InputEvent(
        t: base.adding(seconds: 1.5), kind: .displayGeometry(displayID: 1, frame: Rect(x: 0, y: 0, width: 480, height: 480), scale: 1))]
    var inTheArea = document(area, reshaped, [annotation(1, stuck(0, 4), square, rect: hidden)])
    inTheArea.privacy = PrivacyPlan(blocks: [block()])
    inTheArea.style.geometryTransition = .spring
    let plain = fourSecondTake()
    let moving = cursorEvents(from: base, seconds: 4, across: screenFrame)
    var following = document(plain, moving, [annotation(1, stuck(0, 4), square, rect: hidden)])
    following.privacy = PrivacyPlan(blocks: [block()])
    following.aspect = .portrait
    following.style.reframe = .followCursor
    let cases: [(name: String, take: TakeRecord, events: [InputEvent], document: EditDocument, size: SIMD2<Int>)] = [
        ("Area", area, reshaped, inTheArea, [1920, 1080]),
        ("following the cursor", plain, moving, following, [720, 1280]),
    ]
    for c in cases {
        let scene = FrameEvaluator(take: c.take, events: c.events, document: c.document, outputSize: c.size)
        var crops: Set<[Double]> = []
        for t in [0.5, 1.55, 1.6, 1.8, 2.5, 3.5] {
            let frame = scene.frame(at: t)
            let screen = try #require(frame.screen, "\(c.name) at \(t) s")
            let region = try #require(screen.privacy.first, "\(c.name) at \(t) s").rect
            let layer = try #require(frame.contentAnnotations.first, "\(c.name) at \(t) s")
            #expect(close(layer.rect, onTheLayer(region, screen), 1e-9), "\(c.name) at \(t) s: \(layer.rect)")
            crops.insert([screen.crop.x, screen.crop.y, screen.crop.width, screen.crop.height])
        }
        // The crop drawn moves (a change's cut, the cursor's window), and the annotation with it.
        #expect(crops.count > 1, "\(c.name)")
    }
}

@Test func noScreenNoContentAnnotation() throws {
    // The camera over the whole output (Camera full screen, settled) and a take with only a camera: nothing stuck to the
    // recording; the output's annotations, yes.
    let annotations = [annotation(1, stuck(0, 4), square), annotation(2, .whole, square)]
    let withCamera = fourSecondTake(camera: true)
    var full = document(withCamera, [], annotations)
    full.camera.layouts = [LayoutBlock(
        id: "l-00000001", take: takeID, start: base, end: base.adding(seconds: 4), kind: .cameraFull, instant: true)]
    let cameraOnly = makeTake(tracks: [
        displayTrack(id: cameraID, kind: .camera, globalFrame: nil, segments: [segment(track: cameraID, start: base, end: base.adding(seconds: 4))]),
    ])
    let screenless = document(cameraOnly, [], annotations)
    for (name, take, document) in [("camera full screen", withCamera, full), ("no screen", cameraOnly, screenless)] {
        let scene = FrameEvaluator(take: take, events: [], document: document, outputSize: [1280, 720])
        for t in [1.0, 2.5] {
            let frame = scene.frame(at: t)
            #expect(frame.screen == nil, "\(name) at \(t) s")
            #expect(frame.contentAnnotations.isEmpty, "\(name) at \(t) s")
            #expect(frame.outputAnnotations.map(\.id) == ["a-00000002"], "\(name) at \(t) s")
        }
    }
    #expect(FrameEvaluator(take: withCamera, events: [], document: full, outputSize: [1280, 720]).frame(at: 1).coveredByCamera)
}

// MARK: - When

@Test func shownOnlyInItsSourceRange() throws {
    let take = fourSecondTake()
    // [0, 1) s and [2, 4) s of the take: one annotation over the cut, one inside it, one of another take.
    var cut = document(take, [], [
        annotation(1, stuck(0.5, 3), square), annotation(2, stuck(1.2, 1.8), square), annotation(3, stuck(0, 4, take: "take-002"), square),
    ])
    cut.sequence = [clip(1, 0, 1), clip(2, 2, 4)]
    let scene = FrameEvaluator(take: take, events: [], document: cut, outputSize: [1280, 720])
    func shown(_ t: Double) -> [String] { scene.frame(at: t).contentAnnotations.map(\.id) }
    // Output 0.7 s and 1.5 s show 0.7 s and 2.5 s of the take; 0.3 s and 2.5 s show 0.3 s and 3.5 s.
    #expect(shown(0.7) == ["a-00000001"] && shown(1.5) == ["a-00000001"] && shown(0.99) == ["a-00000001"])
    #expect(shown(0.3).isEmpty && shown(2.5).isEmpty)
    for t in stride(from: 0.0, to: 3.0, by: 0.05) {
        #expect(!shown(t).contains("a-00000002") && !shown(t).contains("a-00000003"), "at \(t) s")
    }

    // A frozen frame at 2 s of the take, inside the annotation's range, that fades in and out: the same layer all along
    // the freeze (output 2 s to 4 s), as at its point; none in one outside the range.
    var frozen = document(take, [], [annotation(1, stuck(1, 3), square, enter: .fade, exit: .fade), annotation(2, stuck(3, 4), square)])
    frozen.sequence = [clip(1, 0, 2), clip(2, 2, 2, content: .freeze(duration: 2_000_000_000)), clip(3, 2, 4)]
    let still = FrameEvaluator(take: take, events: [], document: frozen, outputSize: [1280, 720])
    let layers = [2.0, 2.6, 3.3, 3.99].map { still.frame(at: $0).contentAnnotations }
    #expect(layers[0].map(\.id) == ["a-00000001"] && layers[0].first?.opacity == 1)
    #expect(layers.allSatisfy { $0 == layers[0] }, "\(layers)")

    // A frozen frame put at the end of a run of the take, its point the run's end: past the annotation's output range,
    // but its point inside its source range, so it is on it (plan 3a decision 3).
    var atTheEnd = document(take, [], [annotation(1, stuck(1, 3), square)])
    atTheEnd.sequence = [clip(1, 0, 2.5), clip(2, 2.5, 2.5, content: .freeze(duration: 2_000_000_000))]
    let end = FrameEvaluator(take: take, events: [], document: atTheEnd, outputSize: [1280, 720])
    #expect([2.5, 3.5, 4.4].allSatisfy { end.frame(at: $0).contentAnnotations.map(\.id) == ["a-00000001"] })
}

@Test func outputAndWholeAnchors() throws {
    let take = fourSecondTake()
    let doc = document(take, [], [annotation(1, over(1, 2), square), annotation(2, .whole, square)])
    let timeMap = TimeMap(sequence: doc.sequence)
    let scene = AnnotationScene(document: doc, take: take, events: [], timeMap: timeMap, outputSize: [1280, 720])
    func shown(_ τ: Int64) -> [String] { scene.output(atOutput: τ).map(\.id) }
    #expect(shown(ns(0.9)) == ["a-00000002"] && shown(ns(2)) == ["a-00000002"])
    #expect(shown(ns(1)) == ["a-00000001", "a-00000002"] && shown(ns(1.5)) == ["a-00000001", "a-00000002"])
    #expect(shown(0) == ["a-00000002"] && shown(timeMap.duration - 1) == ["a-00000002"])
    #expect(shown(timeMap.duration).isEmpty)
    // In the output frame's pixels, of its height.
    let layer = try #require(scene.output(atOutput: ns(1.5)).first)
    #expect(layer.space == Rect(x: 0, y: 0, width: 1280, height: 720) && layer.unit == 720)
    #expect(close(layer.rect, Rect(x: 256, y: 216, width: 512, height: 72)))
    // A frame puts the output time's on, over a frozen frame too.
    var frozen = doc
    frozen.sequence = [clip(1, 0, 1), clip(2, 1, 1, content: .freeze(duration: 2_000_000_000)), clip(3, 1, 4)]
    let still = FrameEvaluator(take: take, events: [], document: frozen, outputSize: [1280, 720])
    #expect(still.frame(at: 1.5).outputAnnotations.map(\.id) == ["a-00000001", "a-00000002"])
    #expect(still.frame(at: 2.5).outputAnnotations.map(\.id) == ["a-00000002"])
}

@Test func clipFileTimeAndItsEnd() throws {
    let take = fourSecondTake()
    // 1.5 s of the file, from 0.5 s of it, over the output from 1 s to 4 s: shown from 1 s to 2.5 s only.
    let file = ClipAnnotation(asset: "assets/0123456789abcdef0123456789abcdef.mov", start: ns(0.5), end: ns(2))
    let doc = document(take, [], [
        annotation(1, over(1, 4), .clip(file), enter: .fade, exit: .fade), annotation(2, .whole, .clip(file)),
        annotation(3, stuck(0, 4), .clip(file)),
    ])
    let timeMap = TimeMap(sequence: doc.sequence)
    let scene = AnnotationScene(document: doc, take: take, events: [], timeMap: timeMap, outputSize: [1280, 720])
    func fileTime(_ τ: Int64, _ id: String) -> Int64? {
        for layer in scene.output(atOutput: τ) where layer.id == id {
            if case let .clip(_, fileTime) = layer.content { return fileTime }
        }
        return nil
    }
    #expect(fileTime(ns(2), "a-00000001") == ns(0.5) + ns(1))
    #expect(fileTime(ns(1), "a-00000001") == ns(0.5) && fileTime(ns(2.5) - 1, "a-00000001") == ns(2) - 1)
    #expect(fileTime(ns(2.6), "a-00000001") == nil && fileTime(ns(2.5), "a-00000001") == nil)
    // Its exit is at the end of its file: going out at 2.4 s, not at 3.9 s.
    let leaving = try #require(scene.output(atOutput: ns(2.4)).first { $0.id == "a-00000001" })
    #expect(leaving.opacity < 1)
    // Over the whole video, from 0 s; stuck to the take, never.
    #expect(fileTime(0, "a-00000002") == ns(0.5) && fileTime(ns(1.5), "a-00000002") == nil)
    #expect([0.0, 1, 2, 3].allSatisfy { fileTime(ns($0), "a-00000003") == nil })
}

// MARK: - Order and numbers

@Test func layersAreInLayerOrderWithinTheirGroup() throws {
    let take = fourSecondTake()
    let doc = document(take, [], [
        annotation(1, stuck(0, 4), square, layer: 2), annotation(2, over(0, 4), square, layer: 0),
        annotation(3, stuck(0, 4), square, layer: 1), annotation(4, .whole, square, layer: -1),
        annotation(5, stuck(0, 4), square, layer: 1), annotation(6, over(0, 4), square, layer: 0),
    ])
    let frame = FrameEvaluator(take: take, events: [], document: doc, outputSize: [1280, 720]).frame(at: 1)
    #expect(frame.contentAnnotations.map(\.id) == ["a-00000003", "a-00000005", "a-00000001"])
    #expect(frame.outputAnnotations.map(\.id) == ["a-00000004", "a-00000002", "a-00000006"])
}

@Test func stepNumbersAreSet() throws {
    let take = fourSecondTake()
    let step = AnnotationKind.step(StepAnnotation())
    let rect = NormalizedRect(x: 0.46, y: 0.44, width: 0.04, height: 0.07)
    // By where the output first shows each: 0.5 s (stuck), 1 s, 2 s; the one in the cut has no number and is not shown.
    var doc = document(take, [], [
        annotation(1, over(2, 4), step, rect: rect), annotation(2, stuck(0.5, 4), step, rect: rect),
        annotation(3, over(1, 4), step, rect: rect), annotation(4, stuck(1.2, 1.8), step, rect: rect),
    ])
    doc.sequence = [clip(1, 0, 1), clip(2, 2, 4)]
    let frame = FrameEvaluator(take: take, events: [], document: doc, outputSize: [1280, 720]).frame(at: 2.5)
    func numbers(_ layers: [AnnotationLayer]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: layers.compactMap { layer in
            if case let .step(_, number) = layer.content { return (layer.id, number) }
            return nil
        })
    }
    #expect(numbers(frame.contentAnnotations) == ["a-00000002": 1])
    #expect(numbers(frame.outputAnnotations) == ["a-00000003": 2, "a-00000001": 3])
}

// MARK: - The texts' boxes

@Test func textBoxIsMeasured() throws {
    let take = fourSecondTake()
    let size = SIMD2(1280, 720)
    let words = "Uno dos tres cuatro"
    let plain = TextAnnotation(string: words, preset: .plain, size: 0.05)
    let font = try #require(AnnotationTypography.font(plain, unit: 720, scale: 1))
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: words, attributes: AnnotationTypography.attributes(font: font)))
    let whole = CTLineGetTypographicBounds(line, nil, nil, nil)
    let lineHeight = AnnotationTypography.lineHeight(of: font)
    #expect(lineHeight > 36 && CTFontGetSize(font) == 36)
    // A box 0.7 of the line's width: two lines, of the rect's width.
    let width = 0.7 * whole
    #expect(AnnotationTypography.lines(of: words, font: font, width: width) == ["Uno dos tres", "cuatro"])
    let em = 0.05 * 720.0
    let lowerThird = TextAnnotation(string: words, preset: .lowerThird, size: 0.05)
    let inBox = width + 2 * 0.8 * em
    let doc = document(take, [], [
        annotation(1, over(0, 4), .text(plain), rect: NormalizedRect(x: 0.1, y: 0.2, width: width / 1280, height: 0.5)),
        annotation(2, over(0, 4), .text(lowerThird), rect: NormalizedRect(x: 0.1, y: 0.6, width: inBox / 1280, height: 0.01)),
        annotation(3, over(0, 4), .text(TextAnnotation(string: "Uno\ndos\n", preset: .label, size: 0.05))),
        annotation(4, over(0, 4), .callout(CalloutAnnotation(
            text: TextAnnotation(string: words, preset: .plain, size: 0.05), target: NormalizedPoint(x: 0.3, y: 0.9))),
            rect: NormalizedRect(x: 0.1, y: 0.1, width: (whole + 2 * 0.55 * em) / 1280 + 0.05, height: 0.3)),
    ])
    let layers = AnnotationScene(document: doc, take: take, events: [], timeMap: TimeMap(sequence: doc.sequence), outputSize: size)
        .output(atOutput: ns(1))
    try #require(layers.count == 4)
    #expect(close(layers[0].rect, Rect(x: 128, y: 144, width: width, height: 2 * lineHeight)), "\(layers[0].rect)")
    #expect(close(layers[1].rect, Rect(x: 128, y: 432, width: inBox, height: 2 * lineHeight + 2 * 0.45 * em)), "\(layers[1].rect)")
    // A new line at the end starts an empty one: three lines, in the Label's padding.
    #expect(close(layers[2].rect.height, 3 * lineHeight + 2 * 0.3 * em), "\(layers[2].rect)")
    // A speech bubble's text has the Label's padding: one line; its tail from its bottom edge to its point.
    #expect(close(layers[3].rect.height, lineHeight + 2 * 0.3 * em), "\(layers[3].rect)")
    guard case let .callout(_, tail?) = layers[3].content else { Issue.record("no tail: \(layers[3].content)"); return }
    #expect(tail.tip == SIMD2(384, 648) && close(tail.baseStart.y, layers[3].rect.y + layers[3].rect.height))

    // The same lines at every size it is drawn at: a 4K export breaks the words where the preview does, its box as many
    // lines tall at its size. In a box as wide as `words` at 3 × 36 px, give or take what CoreText's size changes.
    for width in stride(from: 0.4, through: 1.2, by: 0.02) {
        let preview = try #require(AnnotationTypography.lines(of: plain, width: width * whole, unit: 720))
        let export = try #require(AnnotationTypography.lines(of: plain, width: 3 * width * whole, unit: 2160))
        #expect(preview == export, "at \(width) of the line")
        let font4K = try #require(AnnotationTypography.font(plain, unit: 2160, scale: 1))
        let box = AnnotationTypography.box(of: plain, width: 3 * width * whole, unit: 2160)
        #expect(close(box.y, Double(export.count) * AnnotationTypography.lineHeight(of: font4K)), "at \(width) of the line")
    }
}
