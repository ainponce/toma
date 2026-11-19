// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `FrameEvaluator.frame(at:)`, the compositor's counting `encode` and `CursorSprite`.
@testable import Render
import SyntheticCapture
import Testing

// Follow the Cursor in the render (phase 2 design §6.5, plan 2b decision 9 and Task I5, `reframe-1`): the screen fills
// the room inside the padding with a window of its region that follows the cursor, the zoom acts inside it, there is no
// window or device frame, and the cursor, the click effects and the privacy regions stay on the content.

/// A display of 16:9.
private let wide = Rect(x: 0, y: 0, width: 1920, height: 1080)
private let portrait = SIMD2(1080, 1920)
private let padding = 0.04
private let wholeFrame = Rect(x: 0, y: 0, width: 1, height: 1)

/// The room inside the padding of an output of `size`.
private func room(_ size: SIMD2<Int>) -> Rect {
    StageLayout.screenRect(contentAspect: nil, padding: padding, outputSize: SIMD2<Double>(size))
}

/// A take of `seconds` on display 1 of `wide` (or a window of it), without files, with a camera when `camera`.
private func wideTake(seconds: Double = 12, window: Bool = false, area: Rect? = nil, camera: Bool = false) -> TakeRecord {
    var tracks = [displayTrack(
        kind: window ? .window : .display, globalFrame: wide, captureArea: area,
        segments: [segment(start: base, end: base.adding(seconds: seconds))])]
    if camera {
        tracks.append(displayTrack(
            id: cameraID, kind: .camera, globalFrame: nil,
            segments: [segment(track: cameraID, start: base, end: base.adding(seconds: seconds))]))
    }
    return makeTake(tracks: tracks)
}

/// The legacy document of `take` in `aspect` with the padding, the screen following the cursor (or fitted whole), and
/// `change` made to it.
private func reframed(
    _ take: TakeRecord, _ events: [InputEvent], aspect: Aspect = .portrait, reframe: Reframe = .followCursor,
    _ change: (inout EditDocument) -> Void = { _ in }
) -> EditDocument {
    var document = EditDocument.legacy(take: take, events: events)
    document.aspect = aspect
    document.style.padding = padding
    document.style.reframe = reframe
    change(&document)
    return document
}

/// The global point at fractions (`x`, `y`) of the display.
private func across(_ x: Double, _ y: Double = 0.5) -> SIMD2<Double> {
    SIMD2(wide.width * x, wide.height * y)
}

/// The cursor at `x(t)` of the display (and `y`), sampled every 0.1 s from 0 to `seconds`.
private func cursor(seconds: Double = 12, y: Double = 0.5, _ x: (Double) -> Double) -> [InputEvent] {
    (0...Int(seconds * 10)).map { i in
        let t = Double(i) / 10, point = across(x(t), y)
        return InputEvent(t: base.adding(seconds: t), kind: .cursor(x: point.x, y: point.y))
    }
}

private func output(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

/// The window the evaluator's paths show of the view on screen at output time `t` (`ReframePath.part`).
private func part(_ evaluator: FrameEvaluator, at t: Double) throws -> Rect {
    let paths = evaluator.paths
    let source = try #require(evaluator.timeMap.source(atOutput: output(t))?.source)
    let view = try #require(paths.stage.shownScreen(at: source)?.view)
    return try #require(paths.reframe?.part(of: view, atOutput: output(t), stage: paths.stage))
}

/// Where fraction `x` across the region (and `y` down it) is drawn in `room` showing `part` of it; `nil` outside it.
private func drawn(_ x: Double, _ y: Double = 0.5, in room: Rect, showing part: Rect) -> SIMD2<Double>? {
    let u = (x - part.x) / part.width
    guard u >= 0, u < 1 else { return nil }
    return SIMD2(room.x + u * room.width, room.y + y * room.height)
}

private func near(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ tolerance: Double = 1e-9) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
}

private func near(_ a: Rect, _ b: Rect, _ tolerance: Double = 1e-12) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.width - b.width) <= tolerance
        && abs(a.height - b.height) <= tolerance
}

/// `rect` (fractions of a crop) in fractions of its `part`.
private func cut(_ rect: Rect, to part: Rect) -> Rect {
    Rect(
        x: rect.x + part.x * rect.width, y: rect.y + part.y * rect.height, width: part.width * rect.width,
        height: part.height * rect.height)
}

@Test func screenFillsTheRoomShowingAWindow() throws {
    let events = cursor { _ in 0.7 }
    for area in [nil, Rect(x: 160, y: 90, width: 1600, height: 900)] as [Rect?] {
        let take = wideTake(area: area)
        // A block over the middle of the content, for the privacy regions' place.
        let block = PrivacyBlock(
            id: "p-00000001", take: takeID, start: base, end: base.adding(seconds: 12), effect: .blur, strength: 0.6,
            color: RGBA(0, 0, 0, 1), rect: NormalizedRect(x: 0.6, y: 0.4, width: 0.1, height: 0.2), keys: [])
        let document = reframed(take, events) { $0.privacy = PrivacyPlan(blocks: [block]) }
        let evaluator = FrameEvaluator(take: take, events: events, document: document, outputSize: portrait)
        let content = area.map { Rect(x: $0.x / 1920, y: $0.y / 1080, width: $0.width / 1920, height: $0.height / 1080) } ?? wholeFrame
        for t in [0.0, 1, 5.5, 11.9] {
            let frame = evaluator.frame(at: t)
            let screen = try #require(frame.screen)
            let window = try part(evaluator, at: t)
            // The room, whole; a window of the content as tall as it, at the cursor (held to the region).
            #expect(screen.rect == room(portrait), "at \(t)")
            let atCursor = area.map { (0.7 * 1920 - $0.x) / $0.width } ?? 0.7
            #expect(abs(window.x + window.width / 2 - atCursor) < 1e-12 && window.height == 1 && window.y == 0)
            #expect(abs(window.width - room(portrait).width / room(portrait).height / (16.0 / 9)) < 1e-12)
            #expect(near(screen.crop, cut(content, to: window)), "at \(t): \(screen.crop)")
            // Not stretched: what it shows of the frame has the room's shape.
            let shape = screen.crop.width * 1920 / (screen.crop.height * 1080)
            #expect(abs(shape - screen.rect.width / screen.rect.height) < 1e-9)
            // The privacy region on the same content, in fractions of the crop drawn (2c's `layerCrop`).
            let region = try #require(screen.privacy.first?.rect)
            let expected = PrivacyGeometry.inLayerCrop(block.rect, contentCrop: content, layerCrop: screen.crop)
            #expect(near(region, expected), "at \(t)")
            #expect(abs(region.x - (0.6 - window.x) / window.width) < 1e-9)
            #expect(frame.windowFrame == nil && frame.deviceFrame == nil)
        }
    }
}

@Test func cursorIsPlacedInTheWindowAndHiddenOutside() throws {
    let take = wideTake()
    // At the middle for 2 s, then at once near the right edge: the window starts on it, then takes a while to get there.
    let events = cursor { $0 < 2 ? 0.5 : 0.95 }
    let evaluator = FrameEvaluator(take: take, events: events, document: reframed(take, events), outputSize: portrait)
    let room = room(portrait)
    let middle = try #require(evaluator.frame(at: 1).cursor)
    #expect(near(middle.hotspot, SIMD2(room.x + room.width / 2, room.y + room.height / 2), 1e-9))
    // Its size, as fitted: the room's height over the region's.
    #expect(abs(middle.height - 24 * room.height / 1080) < 1e-9)
    // Just after the jump the window has hardly moved: the cursor is outside it, not drawn.
    let window = try part(evaluator, at: 2.05)
    #expect(window.x + window.width < 0.95)
    #expect(evaluator.frame(at: 2.05).cursor == nil)
    // Once the window is there (held to the region's edge), in its place in the window.
    for t in [4.0, 6, 9.5] {
        let window = try part(evaluator, at: t)
        #expect(abs(window.x + window.width - 1) < 1e-4, "at \(t)")
        let hotspot = try #require(evaluator.frame(at: t).cursor?.hotspot)
        #expect(near(hotspot, try #require(drawn(0.95, in: room, showing: window)), 1e-9), "at \(t)")
    }
}

@Test func clickEffectsStayOnTheirPointAsTheWindowMoves() throws {
    let take = wideTake()
    // A press at 0.6 from 1 s to 4 s; from 1.1 s the cursor is near the right edge, and the window goes after it.
    var events = cursor { $0 < 1.1 ? 0.6 : 0.95 }
    let point = across(0.6)
    events += [
        InputEvent(t: base.adding(seconds: 1), kind: .mouseDown(.left, x: point.x, y: point.y)),
        InputEvent(t: base.adding(seconds: 4), kind: .mouseUp(.left, x: across(0.95).x, y: point.y)),
    ]
    events = events.sortedByTime()
    let document = reframed(take, events) { $0.cursor.clickEffect = ClickEffects.circleID }
    let evaluator = FrameEvaluator(take: take, events: events, document: document, outputSize: portrait)
    let room = room(portrait)
    var shown = 0, hidden = 0, last: Double?
    for t in stride(from: 1.0, through: 3.9, by: 1.0 / 60) {
        let window = try part(evaluator, at: t)
        let effects = evaluator.frame(at: t).clickEffects
        guard let place = drawn(0.6, in: room, showing: window) else {
            // The clicked point left the window: nothing of the click.
            #expect(effects.isEmpty, "at \(t)")
            hidden += 1
            continue
        }
        let effect = try #require(effects.first, "at \(t)")
        #expect(effects.count == 1 && near(effect.center, place, 1e-9), "at \(t)")
        // Of the size of the cursor at the click.
        #expect(abs(effect.radius - 0.9 * 24 * room.height / 1080) < 1e-9 || t < 1.12)
        if let last { #expect(effect.center.x <= last + 1e-9) }
        last = effect.center.x
        shown += 1
    }
    // It moved with the content while the window moved, and went with the point out of it.
    #expect(shown > 10 && hidden > 60, "\(shown) shown, \(hidden) hidden")
    let first = try #require(evaluator.frame(at: 1.05).clickEffects.first?.center.x)
    #expect(first - (last ?? first) > 200)
}

@Test func noFrameWhileFollowing() throws {
    let take = wideTake()
    let events = cursor { 0.3 + 0.04 * $0 }
    let frames: [WindowFrame] = [
        .macWindow(appearance: .dark, title: "Window", buttons: true), .device(DeviceFrame(model: .iPhone, finish: .dark)),
        .device(DeviceFrame(model: .macBook, finish: .light)), .device(DeviceFrame(model: .iPad, finish: .light)),
    ]
    for windowFrame in frames {
        func frame(_ reframe: Reframe) -> RenderFrame {
            let document = reframed(take, events, reframe: reframe) {
                $0.style.frame = windowFrame
                $0.style.shadow = 0.5
            }
            return FrameEvaluator(take: take, events: events, document: document, outputSize: portrait).frame(at: 2)
        }
        let following = frame(.followCursor), fitted = frame(.fit)
        #expect(fitted.windowFrame != nil || fitted.deviceFrame != nil, "\(windowFrame)")
        #expect(following.windowFrame == nil && following.settledWindowFrame == nil && following.deviceFrame == nil, "\(windowFrame)")
        let screen = try #require(following.screen)
        #expect(screen.rect == room(portrait) && screen.cornerRadius == 0.012 * 1080, "\(windowFrame)")
        // The shadow is the screen's.
        #expect(following.shadow?.rect == screen.rect && following.shadow?.cornerRadius == screen.cornerRadius)
    }
}

@Test func zoomActsInsideTheReframedScreen() throws {
    let take = wideTake()
    let square = SIMD2(1080, 1080)
    // In 1:1 the window is 0.5625 of the display: the cursor at 0.58 is within the dead zone of the window at 0.5, which
    // stays there, and a following block of 2× goes to it.
    let events = cursor { $0 < 0.3 ? 0.5 : 0.58 }
    let document = reframed(take, events, aspect: .square) {
        $0.zoom.regions = [StageDrawing.zoom(1, from: 0.5, to: 8, depth: 2, focus: .follow)]
    }
    let evaluator = FrameEvaluator(take: take, events: events, document: document, outputSize: square)
    let room = room(square), window = try part(evaluator, at: 5)
    #expect(abs(window.x - (0.5 - 0.5625 / 2)) < 1e-12)
    let frame = evaluator.frame(at: 5)
    let drawnCursor = try #require(frame.cursor), stage = try #require(frame.stage)
    let inWindow = try #require(drawn(0.58, in: room, showing: window))
    #expect(near(drawnCursor.hotspot, inWindow, 1e-9))
    // The zoom's centre is the cursor placed in the window (not where the whole region squeezed in the room has it).
    #expect(stage.depth > 1.999 && near(stage.center, inWindow, 0.01), "\(stage.center) for \(inWindow)")
    #expect(abs(stage.center.x - (room.x + 0.58 * room.width)) > 50)
    // So the cursor is drawn at the middle of the output.
    #expect(near(stage.outputPoint(ofStage: drawnCursor.hotspot, outputSize: square), SIMD2(540, 540), 0.02))
}

@Test func narrowScreenIsDrawnWhole() throws {
    // A window of 16:9 that turns into a tall one of 480 × 1080 at 3 s, narrower than the room (0.444 against 0.542).
    let take = wideTake(window: true)
    let narrow = Rect(x: 100, y: 0, width: 480, height: 1080)
    let events = (cursor { _ in 0.15 } + [
        InputEvent(t: base.adding(seconds: 3), kind: .windowGeometry(track: trackID, frame: narrow, onScreen: true)),
    ]).sortedByTime()
    let document = reframed(take, events) { $0.style.frame = .macWindow(appearance: .light, title: "Tall", buttons: true) }
    let evaluator = FrameEvaluator(take: take, events: events, document: document, outputSize: portrait)
    let before = try #require(evaluator.frame(at: 1).screen)
    #expect(before.rect == room(portrait) && before.crop != wholeFrame)
    let frame = evaluator.frame(at: 4)
    let screen = try #require(frame.screen)
    // Whole, where `fit` places it without a frame: following the cursor there is none.
    #expect(screen.crop == wholeFrame)
    #expect(screen.rect == StageLayout.screenRect(contentAspect: 480.0 / 1080, padding: padding, outputSize: SIMD2<Double>(portrait)))
    #expect(frame.windowFrame == nil && frame.settledWindowFrame == nil)
    // The cursor on it as fitted: 188 pt into the window's 480.
    let hotspot = try #require(frame.cursor?.hotspot)
    #expect(near(hotspot, SIMD2(screen.rect.x + (288.0 - 100) / 480 * screen.rect.width, screen.rect.y + screen.rect.height / 2), 1e-9))
}

@Test func aChangeIntoAWideScreenGlidesIntoItsWindow() throws {
    // A tall window until 3 s, then 16:9, with the geometry's spring: the screen's rect goes from the tall one's to the
    // room, showing a part of the region of its shape about the window's centre, so it never jumps when it settles.
    let take = wideTake(window: true)
    let narrow = Rect(x: 0, y: 0, width: 480, height: 1080)
    let events = (cursor { _ in 0.8 } + [
        InputEvent(t: base, kind: .windowGeometry(track: trackID, frame: narrow, onScreen: true)),
        InputEvent(t: base.adding(seconds: 3), kind: .windowGeometry(track: trackID, frame: wide, onScreen: true)),
    ]).sortedByTime()
    let document = reframed(take, events) { $0.style.geometryTransition = .spring }
    let evaluator = FrameEvaluator(take: take, events: events, document: document, outputSize: portrait)
    #expect(evaluator.frame(at: 2.9).screen?.crop == wholeFrame)
    var previous: Rect?
    var moving = 0
    for t in stride(from: 3.0, through: 5.5, by: 1.0 / 60) {
        let screen = try #require(evaluator.frame(at: t).screen)
        let window = try part(evaluator, at: t)
        // Its shape is the rect's, about the window's centre (at the cursor, 0.8, held to the region).
        let shape = screen.crop.width * 1920 / (screen.crop.height * 1080)
        #expect(abs(shape - screen.rect.width / screen.rect.height) < 1e-9, "at \(t)")
        #expect(abs(screen.crop.x + screen.crop.width / 2 - (window.x + window.width / 2)) < 1e-9, "at \(t)")
        if screen.rect != room(portrait) { moving += 1 }
        if let previous {
            #expect(abs(screen.crop.x - previous.x) < 0.01 && abs(screen.crop.width - previous.width) < 0.01, "at \(t)")
        }
        previous = screen.crop
    }
    #expect(moving > 30)
    #expect(evaluator.frame(at: 5.5).screen?.crop == (try part(evaluator, at: 5.5)))
}

@Test func aChangeOfScreenCrossfadesTheirWindows() throws {
    // Two displays of 16:9 side by side, the plan going to the second at 3 s with the spring: both fill the room, the
    // one being left showing its own window (of the room's shape, at the window's centre), never squeezed.
    let second = Rect(x: 1920, y: 0, width: 1920, height: 1080)
    let take = makeTake(tracks: [
        displayTrack(globalFrame: wide, segments: [segment(start: base, end: base.adding(seconds: 6))]),
        displayTrack(
            id: "display-2", displayID: 2, globalFrame: second,
            segments: [segment(track: "display-2", start: base, end: base.adding(seconds: 6))]),
    ])
    let events = cursor(seconds: 6) { $0 < 3 ? 0.3 : 1.3 }
    let document = reframed(take, events) {
        $0.style.geometryTransition = .spring
        $0.screens.changes = [
            ScreenChange(id: "p-00000001", take: takeID, t: base.adding(seconds: 3), track: "display-2", origin: .user),
        ]
    }
    let evaluator = FrameEvaluator(take: take, events: events, document: document, outputSize: portrait)
    let frame = evaluator.frame(at: 3.1)
    let screen = try #require(frame.screen), previous = try #require(frame.previousScreen)
    #expect(screen.trackID == "display-2" && previous.trackID == trackID && screen.rect == room(portrait))
    #expect(previous.rect == screen.rect)
    let window = try part(evaluator, at: 3.1)
    for layer in [screen, previous] {
        #expect(near(layer.crop, window), "\(layer.trackID)")
    }
}

@Test func theWindowGlidesThroughCuts() throws {
    // Three clips, one at 2×, and a cursor that sweeps the display: frame after frame at 60 fps, the window never moves
    // more than the spring can, at a border of a clip neither, and never leaves the content.
    let take = wideTake(seconds: 20)
    let events = cursor(seconds: 20) { 0.5 + 0.48 * sin(0.9 * $0) }
    let document = reframed(take, events) {
        $0.sequence = [
            Clip(id: "c-00000001", take: takeID, start: base, end: base.adding(seconds: 4), speed: 1),
            Clip(id: "c-00000002", take: takeID, start: base.adding(seconds: 6), end: base.adding(seconds: 12), speed: 2),
            Clip(id: "c-00000003", take: takeID, start: base.adding(seconds: 14), end: base.adding(seconds: 19), speed: 1),
        ]
    }
    let evaluator = FrameEvaluator(take: take, events: events, document: document, outputSize: portrait)
    let width = room(portrait).width / room(portrait).height / (16.0 / 9)
    // A critically damped spring toward targets in [w/2, 1 − w/2] never moves ω (1 − w) per second.
    let most = 2 * Double.pi / ReframePath.spring.response * (1 - width) / 60
    var previous: Double?, largest = 0.0
    for n in 0..<Int(evaluator.duration * 60) {
        let crop = try #require(evaluator.frame(at: Double(n) / 60).screen?.crop)
        #expect(crop.x >= 0 && crop.x + crop.width <= 1 + 1e-12 && abs(crop.width - width) < 1e-12)
        if let previous { largest = max(largest, abs(crop.x - previous)) }
        previous = crop.x
    }
    #expect(largest <= most && largest > most / 30, "\(largest) of \(most)")
}

@Test func aSplitShowsTheWindowInItsCard() throws {
    let take = wideTake(camera: true)
    let events = cursor { 0.3 + 0.05 * $0 }
    let document = reframed(take, events) { $0.camera.layout = CameraLayout(kind: .split) }
    let evaluator = FrameEvaluator(take: take, events: events, document: document, outputSize: portrait)
    let frame = evaluator.frame(at: 3)
    let screen = try #require(frame.screen), window = try part(evaluator, at: 3)
    // The card has the room's shape, and shows the window.
    let roomShape = room(portrait).width / room(portrait).height
    #expect(abs(screen.rect.width / screen.rect.height - roomShape) < 1e-9)
    #expect(near(screen.crop, window) && frame.windowFrame == nil)
    // The cursor is where it is in the window, on the card.
    let hotspot = try #require(frame.cursor?.hotspot)
    let x = 0.3 + 0.05 * 3
    #expect(abs(hotspot.x - (screen.rect.x + (x - window.x) / window.width * screen.rect.width)) < 1e-6)
}

// MARK: - Drawn

/// A take of 6 s on a 16:9 display, with the cursor sweeping it, as video.
private func wideProject(in dir: URL) async throws -> LoadedProject {
    let screen = Rect(x: 0, y: 0, width: 1280, height: 720)
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: screen),
        segments: [VideoSegmentSpec(start: base, seconds: 6, transform: paintingTheBottomRightQuarterGreen)])
    let events = (0..<720).map { i -> InputEvent in
        let t = Double(i) / 120
        return InputEvent(
            t: base.adding(seconds: t), kind: .cursor(x: 640 + 600 * sin(1.3 * t), y: 360 + 300 * sin(0.7 * t)))
    }
    try builder.addEvents(events)
    return try builder.write()
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func previewEqualsExportReframed() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await wideProject(in: dir)
        var document = EditDocument.legacy(for: project)
        document.aspect = .portrait
        document.style.padding = padding
        document.style.reframe = .followCursor
        document.style.shadow = 0.4
        document.style.frame = .macWindow(appearance: .dark, title: "Never drawn", buttons: true)
        // A cut at 2.5 s of the output, a zoom that follows, and both blurs.
        document.sequence = [
            Clip(id: "c-00000001", take: takeID, start: base, end: base.adding(seconds: 2.5), speed: 1),
            Clip(id: "c-00000002", take: takeID, start: base.adding(seconds: 3.2), end: base.adding(seconds: 6), speed: 1),
        ]
        document.zoom.regions = [StageDrawing.zoom(1, from: 1, to: 5, depth: 2, focus: .follow)]
        document.zoom.motionBlur = 1
        document.cursor.motionBlur = 1
        document.cursor.clickEffect = ClickEffects.rippleID
        let size = SIMD2(540, 960)
        let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
        let evaluator = FrameEvaluator(take: project.take, events: project.events, document: document, outputSize: size)
        let times = [0.4, 1.3, 2.45, 2.5, 3.4, 4.6]
        #expect(times.allSatisfy { evaluator.frame(at: $0).screen?.crop != wholeFrame && evaluator.frame(at: $0).windowFrame == nil })
        #expect(times.contains { !evaluator.frame(at: $0).subframes.isEmpty })
        var previous: [UInt8]?
        for t in times {
            let preview = try await offThePool { try renderer.renderBytes(at: t) }
            let export = try await reframeExportedBytes(renderer, at: t)
            #expect(preview == export, "at \(t)")
            #expect(preview != previous, "at \(t)")
            previous = preview
        }
        #expect(renderer.missingVideo.isEmpty)
    }
}

/// `renderer`'s frame at `t` drawn as the export draws it (`render(at:into:completion:)`), as its bytes.
private func reframeExportedBytes(_ renderer: FrameRenderer, at t: Double) async throws -> [UInt8] {
    var created: CVPixelBuffer?
    let attributes = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
    ] as CFDictionary
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, renderer.outputSize.x, renderer.outputSize.y, kCVPixelFormatType_32BGRA, attributes, &created)
    #expect(status == kCVReturnSuccess)
    let target = ReframePixelBuffer(try #require(created))
    let error: (any Error)? = await withCheckedContinuation { continuation in
        renderer.render(at: t, into: target.pixelBuffer) { continuation.resume(returning: $0) }
    }
    if let error { throw error }
    return packedBytes(of: target.pixelBuffer)
}

private final class ReframePixelBuffer: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    init(_ pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
}

// MARK: - Pictures to look at, and what it costs

/// Where `reframeShots` writes its PNG sequences: `TOMA_REFRAME_SHOTS`, a folder. Only on demand.
private let shotsFolder = ProcessInfo.processInfo.environment["TOMA_REFRAME_SHOTS"]

/// A desktop of 1920 × 1080 to look at: ten columns of colour, a grid every 96 px, a dark window in the middle and a
/// white bar at the top, so where the window of the reframe is, and how it moves, shows.
private func desktop(device: any MTLDevice) throws -> any MTLTexture {
    let (width, height) = (1920, 1080)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let column = Double(x / 192) / 10
            var (r, g, b) = (0.55 + 0.4 * sin(6.28 * column), 0.55 + 0.4 * sin(6.28 * column + 2.1), 0.55 + 0.4 * sin(6.28 * column + 4.2))
            if x % 96 < 3 || y % 96 < 3 { (r, g, b) = (0.15, 0.15, 0.18) }
            if y < 40 { (r, g, b) = (0.97, 0.97, 0.97) }
            if x > 760, x < 1160, y > 340, y < 740 { (r, g, b) = (0.12, 0.12, 0.14) }
            let i = (y * width + x) * 4
            (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]) = (UInt8(b * 255), UInt8(g * 255), UInt8(r * 255), 255)
        }
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.shaderRead]
    descriptor.storageMode = .shared
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
    return texture
}

/// Writes BGRA `bytes` of `size` as a PNG at `url`.
private func writePNG(_ bytes: [UInt8], size: SIMD2<Int>, to url: URL) throws {
    let data = CFDataCreate(nil, bytes, bytes.count)!
    let provider = try #require(CGDataProvider(data: data))
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    let image = try #require(CGImage(
        width: size.x, height: size.y, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size.x * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

/// PNG sequences of 9:16 and 1:1 from a wide take at 30 fps: the cursor goes left, right and across, with clicks, a cut
/// and a zoom that follows it, the window moving after it.
@Test(.enabled(if: shotsFolder != nil && (MetalCondition.isAvailable || MetalCondition.isRequired)))
func reframeShots() throws {
    let folder = URL(fileURLWithPath: try #require(shotsFolder))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let device = try #require(MTLCreateSystemDefaultDevice())
    let compositor = try Compositor(device: device)
    let queue = try #require(device.makeCommandQueue())
    let screen = try desktop(device: device), arrow = try CursorSprite.makeTexture(device: device)
    let take = wideTake(seconds: 14)
    func x(_ t: Double) -> Double {
        switch t {
        case ..<1.5: 0.5
        case ..<3: 0.5 - 0.4 * (t - 1.5) / 1.5
        case ..<4: 0.1
        case ..<5: 0.92
        default: 0.5 + 0.42 * sin(1.4 * (t - 5))
        }
    }
    var events = (0...1_680).map { i -> InputEvent in
        let t = Double(i) / 120, point = across(x(t), 0.45 + 0.25 * sin(0.8 * t))
        return InputEvent(t: base.adding(seconds: t), kind: .cursor(x: point.x, y: point.y))
    }
    for t in [2.0, 4.5, 7.2] {
        let point = across(x(t), 0.45 + 0.25 * sin(0.8 * t))
        events.append(InputEvent(t: base.adding(seconds: t), kind: .mouseDown(.left, x: point.x, y: point.y)))
        events.append(InputEvent(t: base.adding(seconds: t + 0.1), kind: .mouseUp(.left, x: point.x, y: point.y)))
    }
    events = events.sortedByTime()
    for (name, aspect, size) in [("portrait", Aspect.portrait, SIMD2(540, 960)), ("square", .square, SIMD2(720, 720))] {
        let document = reframed(take, events, aspect: aspect) {
            $0.style.shadow = 0.5
            $0.style.background = .color(RGBA(0.16, 0.17, 0.22, 1))
            $0.cursor.clickEffect = ClickEffects.rippleID
            $0.cursor.smoothing = .spring(SpringSpec(damping: 1, response: 0.16))
            $0.zoom.regions = [StageDrawing.zoom(1, from: 8, to: 11, depth: 1.8, focus: .follow)]
            $0.sequence = [
                Clip(id: "c-00000001", take: takeID, start: base, end: base.adding(seconds: 6), speed: 1),
                Clip(id: "c-00000002", take: takeID, start: base.adding(seconds: 6.8), end: base.adding(seconds: 13), speed: 1),
            ]
        }
        let evaluator = FrameEvaluator(take: take, events: events, document: document, outputSize: size)
        for n in 0..<Int(evaluator.duration * 30) {
            let frame = evaluator.frame(at: Double(n) / 30)
            let target = try StageDrawing.target(device: device, size: size)
            let commandBuffer = try #require(queue.makeCommandBuffer())
            try compositor.encode(frame, screen: screen, camera: nil, cursor: arrow, into: target, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            try writePNG(
                StageDrawing.bytes(of: target), size: size,
                to: folder.appendingPathComponent(String(format: "\(name)-%04d.png", n)))
        }
    }
}

/// The cost of a frame's evaluation with Follow the Cursor, against the same document fitted: an hour of a 16:9 take in
/// 9:16, the pointer at 60 Hz that never stops, smoothed, 60 clips, a following zoom with both blurs; 3 600 frames at 60
/// fps from the middle, after the paths are built (once per revision). The median of 5 after one to warm up.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
func reframedFramesAreQuick() throws {
    let hour = 3_600.0
    let take = wideTake(seconds: hour + 1)
    let events = (0..<Int(hour * 60)).map { i -> InputEvent in
        let t = Double(i) / 60, point = SIMD2(960 + 900 * cos(0.37 * t) * sin(0.11 * t), 540 + 500 * sin(0.53 * t))
        return InputEvent(t: base.adding(seconds: t), kind: .cursor(x: point.x, y: point.y))
    }
    let clock = ContinuousClock()
    var results: [String] = []
    for reframe in [Reframe.fit, .followCursor] {
        let document = reframed(take, events, reframe: reframe) {
            $0.sequence = (0..<60).map { k in
                Clip(
                    id: String(format: "c-%08x", k + 1), take: takeID, start: base.adding(seconds: 60 * Double(k)),
                    end: base.adding(seconds: 60 * Double(k) + 59.5), speed: 1)
            }
            $0.cursor.smoothing = .spring(SpringSpec(damping: 1, response: 0.16))
            $0.zoom.regions = (0..<60).map { k in
                StageDrawing.zoom(k + 1, from: 60 * Double(k) + 10, to: 60 * Double(k) + 40, depth: 2, focus: .follow)
            }
            $0.zoom.motionBlur = 0.5
            $0.cursor.motionBlur = 0.5
        }
        let built = clock.measure { _ = MotionPaths(take: take, events: events, document: document) }
        let evaluator = FrameEvaluator(take: take, events: events, document: document, outputSize: SIMD2(1080, 1920))
        func evaluate() {
            for n in 0..<3_600 { _ = evaluator.frame(at: 1_800 + Double(n) / 60) }
        }
        evaluate()
        let median = (0..<5).map { _ in clock.measure(evaluate) }.sorted()[2]
        results.append("\(reframe): " + String(
            format: "%.1f µs per frame (paths %.0f ms)", median / .microseconds(1) / 3_600, built / .milliseconds(1)))
    }
    print("reframedFramesAreQuick: " + results.joined(separator: "; "))
}
