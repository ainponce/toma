// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import ImageIO
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `TitleCardScene`, `TitleCardTextures`, `FrameEvaluator.clipFrame`, `DrawCounts` and the compositor's
// counting `encode`.
@testable import Render
import Testing

/// Title cards (phase 3 design §5.2 and §12, `titleCard-1`, plan 3a decision 10): a card takes the place of steps 1 to 6
/// with its texts in its style over its background, fades for `min(0.3 s, D / 2)` against the frame of the clip next to
/// it held still, cuts without one or against another card, and never shows keys or captions.

private let size = SIMD2(1280, 720)
private let second: Int64 = 1_000_000_000

/// Host time `ns` nanoseconds into the take.
private func at(_ ns: Int64) -> HostTime { HostTime(nanoseconds: base.nanoseconds + UInt64(ns)) }

private func clip(_ number: Int, from: Int64, to: Int64) -> Clip {
    Clip(id: String(format: "c-%08x", number), take: takeID, start: at(from), end: at(to), speed: 1)
}

private func card(_ number: Int, at point: Int64, _ card: TitleCard, seconds: Double = 3) -> Clip {
    Clip(
        id: String(format: "c-%08x", number), take: takeID, start: at(point), end: at(point), speed: 1,
        content: .card(card, duration: Int64(seconds * 1e9)))
}

private func titleCard(
    _ background: TitleCardBackground, style: TitleCardStyle = .centered, title: String = "Capítulo dos",
    subtitle: String = "Lo que sigue"
) -> TitleCard {
    TitleCard(title: title, subtitle: subtitle, style: style, background: background)
}

/// The take of 4 s with the cursor moving over its screen, and its legacy document on `backdrop` with `sequence`: by
/// default `[0, 2 s)`, a card at 2 s of 3 s, and `[2, 4 s)` (the card from 2 s to 5 s of the output's 7 s).
private func cardScene(
    _ content: TitleCard, sequence: [Clip]? = nil, take: TakeRecord = StageDrawing.bareTake(seconds: 4),
    change: (inout EditDocument) -> Void = { _ in }
) -> FrameEvaluator {
    let events = cursorEvents(from: base, seconds: 4, across: Rect(x: 0, y: 0, width: 640, height: 360))
    var document = EditDocument.legacy(take: take, events: events)
    document.style.background = .color(backdrop)
    document.sequence = sequence ?? [
        clip(1, from: 0, to: 2 * second), card(2, at: 2 * second, content), clip(3, from: 2 * second, to: 4 * second),
    ]
    change(&document)
    return FrameEvaluator(take: take, events: events, document: document, outputSize: size, frameRate: 60)
}

/// One colour behind everything, the same under every pixel.
private let backdrop = RGBA(0.25, 0.25, 0.25, 1)

/// The frame the output shows at output time `τ` before its output's annotations, every cursor image readable, drawn
/// still (without the motion blur), as a card holds it.
private func shown(_ scene: FrameEvaluator, _ τ: Int64) -> RenderFrame {
    scene.clipFrame(atOutput: τ, cursorImageIsReadable: { _, _ in true }, blurs: false)
}

/// The frame with the background alone of `scene`, as a clip of another take shows it.
private func backgroundAlone(_ scene: FrameEvaluator) -> RenderFrame {
    var frame = scene.frame(at: 0)
    (frame.screen, frame.cursor, frame.shadow, frame.windowFrame, frame.stage) = (nil, nil, nil, nil, nil)
    (frame.clickEffects, frame.subframes, frame.cursorSamples) = ([], [], [])
    return frame
}

@Test func cardFadesAgainstTheNeighborsHeldFrame() throws {
    let scene = cardScene(titleCard(.stage))
    #expect(scene.timeMap.clipOutputStarts == [0, 2 * second, 5 * second] && scene.timeMap.duration == 7 * second)
    // The frames it fades against: the clip before's last instant, and the clip after's first.
    let before = shown(scene, 2 * second - 1), after = shown(scene, 5 * second)
    #expect(before.screen?.sourceTime == at(2 * second - 1) && before.cursor != nil && before.titleCard == nil)
    #expect(after.screen?.sourceTime == at(2 * second) && after.titleCard == nil)

    // In: at 2.15 s, halfway through its 0.3 s, against the clip before's frame held, its screen's group at 0.5.
    let fadingIn = scene.frame(at: 2.15)
    let layer = try #require(fadingIn.titleCard)
    #expect(layer.opacity == 0.5 && layer.fill == nil && layer.scrim == 0)
    #expect(layer.title == "Capítulo dos" && layer.subtitle == "Lo que sigue" && layer.style == .centered)
    var expected = TitleCardScene.faded(before, keeping: 0.5)
    expected.titleCard = layer
    #expect(fadingIn == expected)
    #expect(fadingIn.screen?.opacity == 0.5 && fadingIn.screenOpacity == 0.5)
    #expect(fadingIn.cursor?.opacity == (before.cursor?.opacity).map { $0 * 0.5 })
    // The same frame, held, all the fade long; at its first instant the clip before's frame as it is.
    for seconds in [2.0, 2.05, 2.25, 2.2999] {
        let frame = scene.frame(at: seconds)
        #expect(frame.screen?.sourceTime == at(2 * second - 1) && frame.titleCard != nil, "\(seconds) s")
    }
    var first = before
    first.titleCard = TitleCardLayer(title: layer.title, subtitle: layer.subtitle, style: .centered, opacity: 0)
    #expect(scene.frame(at: 2) == first)

    // In the middle, the background alone.
    for seconds in [2.3, 3.5, 4.6999] {
        var middle = backgroundAlone(scene)
        middle.titleCard = TitleCardLayer(title: layer.title, subtitle: layer.subtitle, style: .centered, opacity: 1)
        #expect(scene.frame(at: seconds) == middle, "\(seconds) s")
    }

    // Out: at 4.85 s, against the clip after's first frame, of 2 s of the source.
    let fadingOut = scene.frame(at: 4.85)
    #expect(fadingOut.titleCard?.opacity == 0.5)
    var out = TitleCardScene.faded(after, keeping: 0.5)
    out.titleCard = fadingOut.titleCard
    #expect(fadingOut == out && fadingOut.screen?.sourceTime == at(2 * second))
    // And the clips around it are their own.
    #expect(scene.frame(at: 1.9).titleCard == nil && scene.frame(at: 5).titleCard == nil)
}

@Test func backgrounds() throws {
    let color = RGBA(0.1, 0.3, 0.6, 1)
    let stage = cardScene(titleCard(.stage)), filled = cardScene(titleCard(.color(color)))
    let blurred = cardScene(titleCard(.blurredFrame))
    // Stage: in the middle, the background alone; Color: the background under its colour.
    let middle = backgroundAlone(stage)
    var stageMiddle = stage.frame(at: 3.5)
    #expect(stageMiddle.titleCard?.fill == nil && stageMiddle.titleCard?.scrim == 0)
    stageMiddle.titleCard = nil
    #expect(stageMiddle == middle)
    var colorMiddle = filled.frame(at: 3.5)
    #expect(colorMiddle.titleCard?.fill == color && colorMiddle.titleCard?.opacity == 1 && colorMiddle.titleCard?.scrim == 0)
    colorMiddle.titleCard = nil
    #expect(colorMiddle == middle)
    // Color while it fades: Stage's frame under the colour at p.
    let colorIn = filled.frame(at: 2.15)
    var held = TitleCardScene.faded(shown(filled, 2 * second - 1), keeping: 0.5)
    held.titleCard = colorIn.titleCard
    #expect(colorIn == held && colorIn.titleCard?.opacity == 0.5 && colorIn.titleCard?.fill == color)
    // A colour that lets the frame through shows the background alone under it once the card is in: never the
    // neighbor's cursor, camera or clicks.
    let tinted = cardScene(titleCard(.color(RGBA(0.1, 0.3, 0.6, 0.5))))
    for seconds in [2.3, 3.4999, 3.5, 4.6999] {
        var frame = tinted.frame(at: seconds)
        #expect(frame.titleCard?.opacity == 1 && frame.titleCard?.fill?.a == 0.5, "\(seconds) s")
        frame.titleCard = nil
        #expect(frame == middle, "\(seconds) s")
    }

    // Blurred frame: the neighbor's screen sharp under the same screen with a blur over all of its crop, and the veil.
    let neighbor = shown(blurred, 2 * second - 1)
    for (seconds, p, side) in [(3.0, 1.0, neighbor), (2.15, 0.5, neighbor), (4.0, 1.0, shown(blurred, 5 * second))] {
        let frame = blurred.frame(at: seconds)
        let screen = try #require(side.screen)
        #expect(frame.previousScreen == screen, "\(seconds) s")
        let over = try #require(frame.screen)
        #expect(over.trackID == screen.trackID && over.sourceTime == screen.sourceTime && over.rect == screen.rect, "\(seconds) s")
        #expect(over.crop == screen.crop && over.opacity == p, "\(seconds) s")
        #expect(over.privacy == [PrivacyRegion(rect: Rect(x: 0, y: 0, width: 1, height: 1), effect: .blur, strength: 1, color: SIMD4(0, 0, 0, 1))])
        #expect(frame.titleCard?.scrim == 0.35 && frame.titleCard?.opacity == p && frame.titleCard?.fill == nil, "\(seconds) s")
        #expect(frame.cursor == nil && frame.camera == nil && frame.clickEffects.isEmpty && frame.cursorSamples.isEmpty, "\(seconds) s")
        #expect(frame.background == side.background && frame.shadow == side.shadow, "\(seconds) s")
    }
}

@Test func aBlurredCardKeepsThePrivacyOfTheFrameUnderIt() throws {
    let hidden = PrivacyBlock(
        id: "p-00000001", take: takeID, start: base, end: base.adding(seconds: 4), effect: .pixelate, strength: 1,
        color: RGBA(0, 0, 0, 1), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2), keys: [])
    for background in [TitleCardBackground.blurredFrame, .stage, .color(RGBA(0, 0, 0, 0.5))] {
        let scene = cardScene(titleCard(background)) { $0.privacy = PrivacyPlan(blocks: [hidden]) }
        let neighbor = shown(scene, 2 * second - 1)
        let regions = try #require(neighbor.screen?.privacy)
        try #require(regions.count == 1 && regions[0].effect == .pixelate)
        for seconds in [2.0, 2.15, 3.0, 4.85] {
            let frame = scene.frame(at: seconds)
            // Every screen drawn sharp keeps the regions of the frame it came from.
            for screen in [frame.screen, frame.previousScreen].compactMap({ $0 }) {
                let full = screen.privacy.contains { $0.rect == Rect(x: 0, y: 0, width: 1, height: 1) && $0.strength == 1 }
                #expect(full || screen.privacy.count == 1 && screen.privacy[0].effect == .pixelate, "\(background) at \(seconds) s")
            }
        }
    }
}

/// A frame of the stage with everything a card can drop: the screen, the cursor and its samples, a click, the camera,
/// keys and captions.
private func busyFrame() -> RenderFrame {
    let screen = ScreenLayer(trackID: trackID, sourceTime: base, rect: Rect(x: 100, y: 80, width: 640, height: 360), cornerRadius: 8)
    let cursor = CursorLayer(hotspot: [300, 200], height: 24)
    let caption = CaptionLayer(
        lines: ["Hola"], highlight: nil, style: .default, language: "es", fontSize: 40, box: Rect(x: 500, y: 600, width: 200, height: 60))
    return RenderFrame(
        outputSize: size, gradientStart: .zero, gradientEnd: .one, gradientAngleDegrees: 0, screen: screen, cursor: cursor,
        camera: CameraLayer(trackID: cameraID, sourceTime: base, rect: Rect(x: 1000, y: 500, width: 200, height: 200), cornerRadius: 100),
        background: .color(SIMD4(0.25, 0.25, 0.25, 1)),
        clickEffects: [ClickEffectLayer(kind: .ripple, center: [300, 200], radius: 20, thickness: 4, opacity: 0.8)],
        keys: KeyOverlayLayer(), captions: caption, captionsAhead: [caption],
        calmZoom: CalmZoomLayer(mode: .dim, amount: 0.9, focus: Rect(x: 200, y: 150, width: 200, height: 100)),
        contentAnnotations: [AnnotationLayer(
            id: "a-00000001", content: .shape(ShapeAnnotation(shape: .rect)), rect: Rect(x: 0.2, y: 0.2, width: 0.3, height: 0.2),
            space: Rect(x: 100, y: 80, width: 640, height: 360), unit: 360, rotation: 0, opacity: 0.8, scale: 1, drawn: 1)])
}

/// A scene of one card of `background` at 2 s for 3 s between two clips (as `cardScene`'s), for the scene alone.
private func lonelyScene(_ background: TitleCardBackground, sequence: [Clip]? = nil) -> (scene: TitleCardScene, timeMap: TimeMap) {
    let take = StageDrawing.bareTake(seconds: 4)
    var document = EditDocument.legacy(take: take, events: [])
    document.sequence = sequence ?? [
        clip(1, from: 0, to: 2 * second), card(2, at: 2 * second, titleCard(background)), clip(3, from: 2 * second, to: 4 * second),
    ]
    let timeMap = TimeMap(sequence: document.sequence)
    return (TitleCardScene(document: document, timeMap: timeMap, outputSize: size), timeMap)
}

@Test func noCameraCursorKeysOrCaptions() throws {
    let busy = busyFrame()
    let background = RenderFrame(outputSize: size, gradientStart: .zero, gradientEnd: .one, gradientAngleDegrees: 0)
    for kind in [TitleCardBackground.stage, .color(RGBA(0, 0, 0, 1)), .color(RGBA(0, 0, 0, 0.5)), .blurredFrame] {
        let (scene, _) = lonelyScene(kind)
        for offset in [0, 100_000_000, 150_000_000, 1_500_000_000, 2_850_000_000, 3 * second - 1] as [Int64] {
            let frame = scene.frame(clip: 1, offset: offset, background: background) { _ in busy }
            let at = "\(kind) at \(offset)"
            #expect(frame.titleCard != nil, "\(at)")
            #expect(frame.keys == nil && frame.captions == nil, "\(at)")
            // What is made ahead for the frames that come stays with the neighbor's frame.
            #expect(frame.captionsAhead.isEmpty || frame.captionsAhead == busy.captionsAhead, "\(at)")
            switch kind {
            case .blurredFrame:
                #expect(frame.cursor == nil && frame.camera == nil && frame.clickEffects.isEmpty, "\(at)")
                #expect(frame.calmZoom == nil && frame.contentAnnotations.isEmpty, "\(at)")
            case _ where frame.titleCard?.opacity == 1:
                // Stage and Color, once the card is in: the background alone, under an opaque colour or a translucent one.
                #expect(frame == { var alone = background; alone.titleCard = frame.titleCard; return alone }(), "\(at)")
            default:
                break
            }
        }
    }
    // Stage fades the screen's group and the camera together, to nothing at p = 1.
    let (stage, _) = lonelyScene(.stage)
    let fading = stage.frame(clip: 1, offset: 75_000_000, background: background) { _ in busy }
    #expect(fading.titleCard?.opacity == 0.25)
    #expect(fading.screenOpacity == 0.75 && fading.screen?.opacity == 0.75 && fading.cursor?.opacity == 0.75)
    #expect(fading.camera?.opacity == 0.75 && fading.clickEffects.map(\.opacity) == [0.8 * 0.75])
}

@Test func theNeighborsLayersOverTheStageGoWithTheCard() throws {
    let busy = busyFrame()
    let background = RenderFrame(outputSize: size, gradientStart: .zero, gradientEnd: .one, gradientAngleDegrees: 0)
    // Stage and Color fade the calm zoom and the annotations stuck to the recording with the screen's group.
    for kind in [TitleCardBackground.stage, .color(RGBA(0, 0, 0, 0.5))] {
        let (scene, _) = lonelyScene(kind)
        let fading = scene.frame(clip: 1, offset: 75_000_000, background: background) { _ in busy }
        #expect(fading.calmZoom?.amount == 0.9 * 0.75 && fading.calmZoom?.mode == .dim, "\(kind)")
        #expect(fading.contentAnnotations.map(\.opacity) == [0.8 * 0.75], "\(kind)")
        #expect(fading.contentAnnotations.map(\.id) == ["a-00000001"], "\(kind)")
        // At its first instant, the neighbor's as they are.
        let first = scene.frame(clip: 1, offset: 0, background: background) { _ in busy }
        #expect(first.calmZoom == busy.calmZoom && first.contentAnnotations == busy.contentAnnotations, "\(kind)")
        // And none once the card is in.
        let middle = scene.frame(clip: 1, offset: 1_500_000_000, background: background) { _ in busy }
        #expect(middle.calmZoom == nil && middle.contentAnnotations.isEmpty, "\(kind)")
    }
    // The blurred frame has neither, from its first instant: the screen under them is blurred.
    let (blurred, _) = lonelyScene(.blurredFrame)
    for offset in [0, 75_000_000, 1_500_000_000] as [Int64] {
        let frame = blurred.frame(clip: 1, offset: offset, background: background) { _ in busy }
        #expect(frame.calmZoom == nil && frame.contentAnnotations.isEmpty && frame.previousScreen == busy.screen, "\(offset)")
    }
}

@Test func theNeighborIsHeldWithoutItsMotionBlur() throws {
    // The camera zooming in at the card's point and the cursor moving, with both blurs on.
    let scene = cardScene(titleCard(.stage)) { document in
        document.zoom.regions = [StageDrawing.zoom(1, from: 1.6, to: 3.5, depth: 2)]
        document.zoom.motionBlur = 1
        document.cursor.motionBlur = 1
    }
    // The output shows the clip before blurred; the card holds it still, as a frozen frame is.
    let moving = scene.clipFrame(atOutput: 2 * second - 1, cursorImageIsReadable: { _, _ in true })
    #expect(!moving.subframes.isEmpty)
    let still = shown(scene, 2 * second - 1)
    #expect(still.subframes.isEmpty && still.cursorSamples.isEmpty && still.stage.map { $0.depth > 1 } == true)
    for seconds in [2.0, 2.15, 2.2999] {
        let frame = scene.frame(at: seconds)
        var expected = TitleCardScene.faded(still, keeping: 1 - (frame.titleCard?.opacity ?? 0))
        expected.titleCard = frame.titleCard
        #expect(frame == expected && frame.subframes.isEmpty && frame.cursorSamples.isEmpty, "\(seconds) s")
    }
    let out = scene.frame(at: 4.85)
    #expect(out.subframes.isEmpty && out.cursorSamples.isEmpty && out.screen?.sourceTime == at(2 * second))
}

@Test func cardsAheadAreHandedOver() throws {
    let scene = cardScene(titleCard(.stage))
    let layer = TitleCardLayer(title: "Capítulo dos", subtitle: "Lo que sigue", style: .centered)
    // In the second before the card, its texts; never before that, nor in the card or after it.
    for seconds in [1.0001, 1.5, 1.9999] {
        #expect(scene.frame(at: seconds).titleCardsAhead == [layer], "\(seconds) s")
    }
    for seconds in [0.0, 0.5, 0.9999, 2.0, 3.5, 5.0, 6.5] {
        #expect(scene.frame(at: seconds).titleCardsAhead.isEmpty, "\(seconds) s")
    }
    // A document without cards hands none over, anywhere.
    let take = StageDrawing.bareTake(seconds: 4)
    let plain = FrameEvaluator(take: take, events: [], document: EditDocument.legacy(take: take, events: []), outputSize: size)
    for seconds in stride(from: 0.0, to: 4, by: 0.25) {
        #expect(plain.frame(at: seconds).titleCardsAhead.isEmpty, "\(seconds) s")
    }
}

@Test func twoCardsInARowCut() throws {
    let a = titleCard(.blurredFrame, title: "A"), b = titleCard(.stage, title: "B")
    let sequence = [
        clip(1, from: 0, to: 2 * second), card(2, at: 2 * second, a, seconds: 1), card(3, at: 2 * second, b, seconds: 1),
        clip(4, from: 2 * second, to: 4 * second),
    ]
    let scene = cardScene(a, sequence: sequence)
    #expect(scene.timeMap.clipOutputStarts == [0, 2 * second, 3 * second, 4 * second])
    // A fades in against the clip before and B out against the clip after; between them, a cut.
    #expect(scene.frame(at: 2.15).titleCard?.opacity == 0.5 && scene.frame(at: 2.15).titleCard?.title == "A")
    for seconds in [2.5, 2.9, 2.9999] {
        let frame = scene.frame(at: seconds)
        #expect(frame.titleCard?.opacity == 1 && frame.titleCard?.title == "A", "\(seconds) s")
        // Its second half holds the clip before's frame: the card after it is no frame to hold.
        #expect(frame.previousScreen?.sourceTime == at(2 * second - 1), "\(seconds) s")
    }
    for seconds in [3.0, 3.1, 3.5] {
        let frame = scene.frame(at: seconds)
        #expect(frame.titleCard?.opacity == 1 && frame.titleCard?.title == "B" && frame.screen == nil, "\(seconds) s")
    }
    #expect(scene.frame(at: 3.85).titleCard?.opacity == 0.5 && scene.frame(at: 3.85).screen?.sourceTime == at(2 * second))

    // Neither card ever asks for a frame of a card: no recursion, whatever the background.
    for kind in [TitleCardBackground.stage, .color(RGBA(0, 0, 0, 0.5)), .blurredFrame] {
        let both = [
            clip(1, from: 0, to: 2 * second), card(2, at: 2 * second, titleCard(kind), seconds: 1),
            card(3, at: 2 * second, titleCard(kind), seconds: 1), clip(4, from: 2 * second, to: 4 * second),
        ]
        let (scene, timeMap) = lonelyScene(kind, sequence: both)
        let background = RenderFrame(outputSize: size, gradientStart: .zero, gradientEnd: .one, gradientAngleDegrees: 0)
        var asked: [Int64] = []
        for k in [1, 2] {
            for offset in stride(from: Int64(0), to: second, by: 10_000_000) {
                _ = scene.frame(clip: k, offset: offset, background: background) { output in
                    asked.append(output)
                    return busyFrame()
                }
            }
        }
        #expect(!asked.isEmpty, "\(kind)")
        for output in asked {
            #expect(timeMap.contentOffset(atOutput: output) == nil, "\(kind): asked for \(output)")
        }
    }
}

@Test func aCardAtTheStartHasNoFadeIn() throws {
    let start = cardScene(titleCard(.stage), sequence: [card(1, at: 0, titleCard(.stage)), clip(2, from: 0, to: 4 * second)])
    #expect(start.timeMap.clipOutputStarts == [0, 3 * second])
    for seconds in [0, 0.1, 0.2999] {
        let frame = start.frame(at: seconds)
        #expect(frame.titleCard?.opacity == 1 && frame.screen == nil && frame.cursor == nil, "\(seconds) s")
    }
    // It fades out against the clip after it.
    #expect(start.frame(at: 2.85).titleCard?.opacity == 0.5 && start.frame(at: 2.85).screen?.sourceTime == base)
    // At the end, it has no fade out either.
    let end = cardScene(titleCard(.stage), sequence: [clip(1, from: 0, to: 4 * second), card(2, at: 4 * second, titleCard(.stage))])
    #expect(end.timeMap.duration == 7 * second)
    for seconds in [6.75, 6.9, 6.9999, 7] {
        let frame = end.frame(at: seconds)
        #expect(frame.titleCard?.opacity == 1 && frame.screen == nil, "\(seconds) s")
    }
    #expect(end.frame(at: 4.15).titleCard?.opacity == 0.5)
    // A card shorter than 0.6 s fades for half of it.
    let short = cardScene(
        titleCard(.stage),
        sequence: [clip(1, from: 0, to: 2 * second), card(2, at: 2 * second, titleCard(.stage), seconds: 0.4), clip(3, from: 2 * second, to: 4 * second)])
    #expect(short.frame(at: 2.1).titleCard?.opacity == 0.5 && short.frame(at: 2.2).titleCard?.opacity == 1)
    #expect(short.frame(at: 2.3).titleCard?.opacity == 0.5)
}

/// A take of 4 s with a screen and a camera, without files.
private func cameraTake() -> TakeRecord {
    makeTake(tracks: [
        displayTrack(globalFrame: Rect(x: 0, y: 0, width: 640, height: 360), segments: [segment(start: base, end: base.adding(seconds: 4))]),
        displayTrack(
            id: cameraID, kind: .camera, globalFrame: nil,
            segments: [segment(track: cameraID, start: base, end: base.adding(seconds: 4))]),
    ])
}

@Test func blurredFrameWithoutAScreenIsTheStage() throws {
    let take = cameraTake()
    let scene = cardScene(titleCard(.blurredFrame), take: take) { document in
        document.camera.layouts = [LayoutBlock(
            id: "l-00000001", take: takeID, start: base, end: base.adding(seconds: 4), kind: .cameraFull, instant: true)]
    }
    let before = shown(scene, 2 * second - 1)
    try #require(before.coveredByCamera && before.screen == nil)
    let camera = try #require(before.camera)
    // As Stage: the camera fades to the background, without the veil.
    let fading = scene.frame(at: 2.15)
    #expect(fading.titleCard?.scrim == 0 && fading.titleCard?.opacity == 0.5)
    #expect(!fading.coveredByCamera && fading.camera?.opacity == camera.opacity * 0.5 && fading.screen == nil)
    #expect(fading.previousScreen == nil)
    var middle = scene.frame(at: 3.5)
    #expect(middle.titleCard?.scrim == 0 && middle.camera == nil && !middle.coveredByCamera)
    middle.titleCard = nil
    #expect(middle == backgroundAlone(cardScene(titleCard(.stage))))

    // And a card with no clip next to it at all.
    let alone = cardScene(titleCard(.blurredFrame), sequence: [card(1, at: 0, titleCard(.blurredFrame))])
    let frame = alone.frame(at: 1)
    #expect(frame.screen == nil && frame.titleCard?.scrim == 0 && frame.titleCard?.opacity == 1)
}

@Test func cardTextureIsDeterministicAndKept() throws {
    let layer = TitleCardLayer(title: "Capítulo dos", subtitle: "Lo que sigue", style: .centered)
    let first = try #require(try TitleCardTextures.bitmap(of: layer, outputSize: size))
    let again = try #require(try TitleCardTextures.bitmap(of: layer, outputSize: size))
    #expect(first.bytes == again.bytes && first.origin == again.origin && first.size == again.size)
    #expect(first.bytes.contains { $0 != 0 })
    // The block within the output, at most 0.8 of its width plus its margin.
    #expect(first.origin.x >= 0 && first.origin.y >= 0 && first.origin.x + first.size.x <= size.x && first.origin.y + first.size.y <= size.y)
    #expect(Double(first.size.x) <= 0.8 * Double(size.x) + 2 * (0.3 * 0.085 * Double(size.y) + 2) + 2)
    // Nothing to draw without texts.
    #expect(try TitleCardTextures.bitmap(of: TitleCardLayer(title: "", style: .large), outputSize: size) == nil)

    guard MetalCondition.isAvailable || MetalCondition.isRequired else { return }
    let device = try #require(MTLCreateSystemDefaultDevice())
    let textures = TitleCardTextures()
    let texture = try #require(try textures.texture(for: layer, outputSize: size, device: device))
    #expect(texture.origin == first.origin && texture.size == first.size)
    var bytes = [UInt8](repeating: 0, count: first.size.x * first.size.y * 4)
    texture.texture.getBytes(
        &bytes, bytesPerRow: first.size.x * 4, from: MTLRegionMake2D(0, 0, first.size.x, first.size.y), mipmapLevel: 0)
    #expect(bytes == first.bytes)
    // The opacity, the fill and the veil do not draw it again; another text, style, colour or size does.
    var faded = layer
    (faded.opacity, faded.fill, faded.scrim) = (0.3, RGBA(1, 0, 0, 1), 0.35)
    #expect(try textures.texture(for: faded, outputSize: size, device: device)?.texture === texture.texture)
    #expect(textures.drawCount == 1)
    var other = layer
    other.style = .leading
    _ = try textures.texture(for: other, outputSize: size, device: device)
    #expect(textures.drawCount == 2)
    // The last two are kept.
    #expect(try textures.texture(for: layer, outputSize: size, device: device)?.texture === texture.texture)
    #expect(textures.drawCount == 2)
    _ = try textures.texture(for: layer, outputSize: SIMD2(1920, 1080), device: device)
    _ = try textures.texture(for: other, outputSize: size, device: device)
    #expect(textures.drawCount == 4)
    // An empty card has none, and keeps that.
    #expect(try textures.texture(for: TitleCardLayer(title: "", style: .minimal), outputSize: size, device: device) == nil)
}

@Test func aWordIsNeverBroken() throws {
    let tall = SIMD2(1080, 1920)
    func width(_ line: CTLine) -> Double { CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line) }
    // Large at 9:16: "Capítulo" alone nearly fills the line, so the title breaks between its words.
    let large = try #require(TitleCardLayout(TitleCardLayer(title: "Capítulo dos", subtitle: "Lo que sigue", style: .large), outputSize: tall))
    let ranges = large.lines.map { CTLineGetStringRange($0.line) }
    #expect(ranges.map(\.location) == [0, 9, 0] && ranges.map(\.length) == [9, 3, 12], "\(ranges)")
    #expect(large.lines.allSatisfy { width($0.line) <= 0.8 * Double(tall.x) + 0.5 })
    // A word wider than the line: set smaller, whole, on one line within 0.8 W.
    let long = try #require(TitleCardLayout(TitleCardLayer(title: "Electroencefalografistas", style: .large), outputSize: tall))
    #expect(long.lines.count == 1 && CTLineGetStringRange(long.lines[0].line).length == 24)
    #expect(width(long.lines[0].line) <= 0.8 * Double(tall.x) + 0.5 && width(long.lines[0].line) > 0.7 * Double(tall.x))
    // A line the user broke is broken there.
    let broken = try #require(TitleCardLayout(TitleCardLayer(title: "Uno\nDos", style: .minimal), outputSize: size))
    #expect(broken.lines.count == 2 && broken.lines[1].baseline > broken.lines[0].baseline)
}

/// A compositor of the default device with a screen texture and Toma's arrow, drawing a frame into a target of its size.
private struct CardDrawer: @unchecked Sendable {
    let device: any MTLDevice
    let compositor: Compositor
    let queue: any MTLCommandQueue
    let screen: any MTLTexture
    let cursor: any MTLTexture

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        compositor = try Compositor(device: device)
        queue = try #require(device.makeCommandQueue())
        screen = try StageDrawing.screenTexture(device: device)
        cursor = try CursorSprite.makeTexture(device: device)
    }

    func draw(_ frame: RenderFrame) throws -> (bytes: [UInt8], counts: DrawCounts) {
        let target = try StageDrawing.target(device: device, size: frame.outputSize)
        let commandBuffer = try #require(queue.makeCommandBuffer())
        var counts = DrawCounts()
        try compositor.encode(
            frame, screen: screen, previousScreen: screen, camera: screen, cursor: cursor, into: target, commandBuffer: commandBuffer,
            counts: &counts)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        return (StageDrawing.bytes(of: target), counts)
    }
}

/// The smallest rect holding every pixel of `bytes` (BGRA, `size`) that is not `color`; `nil` with none.
private func inkBounds(_ bytes: [UInt8], size: SIMD2<Int>, other color: SIMD4<UInt8>) -> (min: SIMD2<Int>, max: SIMD2<Int>)? {
    var lower = SIMD2(Int.max, Int.max), upper = SIMD2(Int.min, Int.min)
    for y in 0..<size.y {
        for x in 0..<size.x where pixel(bytes, width: size.x, x: x, y: y) != color {
            lower = SIMD2(min(lower.x, x), min(lower.y, y))
            upper = SIMD2(max(upper.x, x), max(upper.y, y))
        }
    }
    return lower.x == .max ? nil : (lower, upper)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func cardFillsTheFrameWithItsText() async throws {
    let drawer = try CardDrawer()
    let fill = RGBA(0.1, 0.2, 0.3, 1)
    var heights: [TitleCardStyle: Int] = [:]
    for style in TitleCardStyle.allCases {
        let frame = cardScene(titleCard(.color(fill), style: style)).frame(at: 3.5)
        let layer = try #require(frame.titleCard)
        let (bytes, counts) = try await offThePool { try drawer.draw(frame) }
        #expect(counts.titleCards == 1 && counts.screens == 0, "\(style): \(counts)")
        // The fill everywhere but the texts: a corner is it.
        let corner = pixel(bytes, width: size.x, x: 0, y: 0)
        #expect(isClose(corner, SIMD4(Float(fill.b) * 255, Float(fill.g) * 255, Float(fill.r) * 255, 255), tolerance: 1), "\(style): \(corner)")
        let region = try #require(TitleCardLayout(layer, outputSize: size))
        let ink = try #require(inkBounds(bytes, size: size, other: corner), "\(style): no text")
        // Every pixel off the fill is inside the region titleCard-1 gives the texts.
        #expect(ink.min.x >= region.origin.x && ink.min.y >= region.origin.y, "\(style)")
        #expect(ink.max.x < region.origin.x + region.size.x && ink.max.y < region.origin.y + region.size.y, "\(style)")
        // The text is white.
        var brightest = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let sum: Int = Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])
            brightest = max(brightest, sum)
        }
        #expect(brightest >= 3 * 250, "\(style)")
        // The block centred up and down, within 0.8 W; centred across, or from 0.1 W to the left.
        let width = Double(size.x), height = Double(size.y)
        let middle = Double(ink.min.y + ink.max.y) / 2
        #expect(abs(middle - height / 2) < 0.06 * height, "\(style): \(ink)")
        #expect(Double(ink.max.x - ink.min.x) <= 0.8 * width, "\(style): \(ink)")
        if style == .leading {
            #expect(Double(ink.min.x) >= 0.1 * width - 1 && Double(ink.min.x) < 0.1 * width + 0.02 * width, "\(style): \(ink)")
        } else {
            #expect(abs(Double(ink.min.x + ink.max.x) / 2 - width / 2) < 0.01 * width, "\(style): \(ink)")
        }
        heights[style] = ink.max.y - ink.min.y
    }
    #expect(heights[.large]! > heights[.centered]! && heights[.centered]! > heights[.minimal]!, "\(heights)")
    #expect(heights[.leading] == heights[.centered], "\(heights)")

    // A long title breaks into lines within 0.8 W.
    let long = cardScene(titleCard(.color(fill), title: "Una placa con un título bastante largo que no entra en una sola línea"))
    let (bytes, _) = try await offThePool { try drawer.draw(long.frame(at: 3.5)) }
    let ink = try #require(inkBounds(bytes, size: size, other: pixel(bytes, width: size.x, x: 0, y: 0)))
    #expect(Double(ink.max.x - ink.min.x) <= 0.8 * Double(size.x) && ink.max.y - ink.min.y > heights[.centered]!, "\(ink)")
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func cardsDrawOnEveryPath() async throws {
    let drawer = try CardDrawer()
    let blurred = cardScene(titleCard(.blurredFrame)), stage = cardScene(titleCard(.stage))
    let zoomed = cardScene(titleCard(.stage)) { document in
        // At 2 s of the source the camera is still moving in.
        document.zoom.regions = [StageDrawing.zoom(1, from: 1.6, to: 3.5, depth: 2)]
        document.zoom.motionBlur = 1
        document.cursor.motionBlur = 1
    }
    // A card's layer over the camera over every pixel: the camera's path, with the card over it (a card's own frames fade
    // the camera, so they never take this path).
    let covered = cardScene(titleCard(.color(RGBA(0.1, 0.3, 0.6, 1))), take: cameraTake()) { document in
        document.camera.layouts = [LayoutBlock(
            id: "l-00000001", take: takeID, start: base, end: base.adding(seconds: 4), kind: .cameraFull, instant: true)]
    }
    var coveredUnderACard = covered.clipFrame(atOutput: 2 * second - 1, cursorImageIsReadable: { _, _ in true })
    coveredUnderACard.titleCard = covered.frame(at: 2.15).titleCard
    #expect(!covered.frame(at: 2.15).coveredByCamera)
    // A card's layer over a frame with the zoom's motion blur: the card itself holds its neighbor still, so this is the
    // blur's pass with a card in it, as a frame of the output never draws one today.
    var zoomedUnderACard = zoomed.clipFrame(atOutput: 2 * second - 1, cursorImageIsReadable: { _, _ in true })
    zoomedUnderACard.titleCard = zoomed.frame(at: 2.15).titleCard
    #expect(zoomed.frame(at: 2.15).subframes.isEmpty)
    let frames: [(String, RenderFrame)] = [
        ("blurred, middle", blurred.frame(at: 3.5)), ("blurred, in", blurred.frame(at: 2.15)),
        ("stage, in", stage.frame(at: 2.15)), ("stage, middle", stage.frame(at: 3.5)),
        ("zoomed, in", zoomedUnderACard), ("covered, in", coveredUnderACard),
    ]
    let drawn = try await offThePool { try frames.map { try drawer.draw($0.1) } }
    for ((name, frame), (bytes, counts)) in zip(frames, drawn) {
        #expect(counts.titleCards == 1 && counts.overlaySteps == 1, "\(name): \(counts)")
        #expect(bytes.count == size.x * size.y * 4, "\(name)")
        _ = frame
    }
    // The blurred frame: the screen twice, once with its blur over all of it.
    #expect(drawn[0].counts.screens == 2 && drawn[0].counts.privacyScreens == 1, "\(drawn[0].counts)")
    // The card is drawn in the motion blur's pass too.
    #expect(!frames[4].1.subframes.isEmpty && drawn[4].counts.accumulations > 0, "\(drawn[4].counts)")
    // The stage at p = 1 is the background and the texts.
    #expect(drawn[3].counts.screens == 0 && drawn[3].counts.cursors == 0)
    #expect(frames[5].1.coveredByCamera && drawn[5].counts.cameras == 1 && drawn[5].counts.backgrounds == 0, "\(drawn[5].counts)")
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func cardTexturesAreDrawnAhead() async throws {
    let drawer = try CardDrawer()
    let textures = drawer.compositor.layers.titleCard.textures
    let scene = cardScene(titleCard(.color(RGBA(0.1, 0.2, 0.3, 1))))
    // A frame in the second before the card draws its texts' texture in the background.
    _ = try await offThePool { try drawer.draw(scene.frame(at: 1.5)) }
    textures.waitUntilDrawnAhead()
    #expect(textures.drawCount == 1 && textures.inlineDrawCount == 0)
    // The card's frames find it made, and the frames before it hand nothing over again.
    let frames = [1.6, 1.9999, 2.0, 2.15, 3.5].map { scene.frame(at: $0) }
    _ = try await offThePool { try frames.map { try drawer.draw($0) } }
    textures.waitUntilDrawnAhead()
    #expect(textures.drawCount == 1 && textures.inlineDrawCount == 0)
    // Without anything ahead (a jump into the card), it is drawn in the frame.
    let other = cardScene(titleCard(.stage, title: "Otro"))
    _ = try await offThePool { try drawer.draw(other.frame(at: 3.5)) }
    #expect(textures.drawCount == 2 && textures.inlineDrawCount == 1)
    // A frame drawn while its card is being drawn ahead waits for it rather than drawing it again.
    let late = cardScene(titleCard(.stage, title: "Tarde"))
    _ = try await offThePool { try drawer.draw(late.frame(at: 1.9)) }
    _ = try await offThePool { try drawer.draw(late.frame(at: 2.15)) }
    textures.waitUntilDrawnAhead()
    #expect(textures.drawCount == 3 && textures.inlineDrawCount == 1)
}

// MARK: - The preview and the export

private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)

/// A take of one 3 s display segment from `base`, with the cursor moving over it the whole time.
private func cardProject(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 3)])
    try builder.addEvents(cursorEvents(from: base, seconds: 3, across: screenFrame))
    return try builder.write()
}

/// `project`'s legacy document with `[0, 1.5 s)`, a card of `background` at 1.5 s for 1.2 s, and `[1.5, 3 s)`.
private func cardDocument(_ project: LoadedProject, _ background: TitleCardBackground, style: TitleCardStyle = .centered) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    let point = 1_500_000_000 as Int64
    document.sequence = [
        clip(1, from: 0, to: point), card(2, at: point, titleCard(background, style: style), seconds: 1.2), clip(3, from: point, to: 3 * second),
    ]
    return document
}

/// `renderer`'s frames at `times`, queued one after the other on the export's path (`render(at:into:completion:)`, each
/// decoded by the prefetchers), as their bytes.
private func exported(_ renderer: FrameRenderer, at times: [Double]) async throws -> [[UInt8]] {
    let size = renderer.outputSize
    var buffers: [CVPixelBuffer] = []
    for _ in times {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, size.x, size.y, kCVPixelFormatType_32BGRA, attributes, &created) == kCVReturnSuccess)
        buffers.append(try #require(created))
    }
    let boxes = buffers.map(PixelBufferHolder.init)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for (time, box) in zip(times, boxes) {
            let done = AsyncThrowingStream<Void, any Error>.makeStream()
            renderer.render(at: time, into: box.buffer) { error in
                if let error { done.continuation.finish(throwing: error) } else { done.continuation.finish() }
            }
            group.addTask { for try await _ in done.stream {} }
        }
        try await group.waitForAll()
    }
    return boxes.map { packedBytes(of: $0.buffer) }
}

private struct PixelBufferHolder: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func previewEqualsExportWithACard() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await cardProject(in: dir)
        // From before the card to after it on the export's grid of 30 fps: the fade in, the middle, the fade out.
        let times = (40...92).map { Double(TimeMap.frameTime($0, frameRate: 30)) / 1e9 }
        for background in [TitleCardBackground.blurredFrame, .stage, .color(RGBA(0.1, 0.3, 0.6, 0.8))] {
            let document = cardDocument(project, background)
            let renderer = try FrameRenderer(project: project, document: document, outputSize: [640, 360], frameRate: 30)
            let preview = PreviewRenderer(renderer: renderer)
            let exported = try await exported(renderer, at: times)
            let previewed = try await offThePool { try times.map { try preview.snapshot(at: $0) } }
            for (time, (export, shown)) in zip(times, zip(exported, previewed)) {
                #expect(export == shown, "\(background) at \(time) s")
            }
            // A video two of a frame's layers show at once (the blurred frame over the same one sharp) is decoded once.
            let keys = renderer.videos(of: try renderer.frame(of: renderer.scene, at: 2.1))
            #expect(keys.count == Set(keys).count && keys.count == (background == .blurredFrame ? 1 : 0), "\(background): \(keys)")
            // The card is drawn: its middle differs from the frames of the take around it, and from its fade.
            let middle = try #require(times.firstIndex { $0 >= 2.1 })
            #expect(exported[middle] != exported[0] && exported[middle] != exported[times.count - 1], "\(background)")
            #expect(renderer.missingVideo.isEmpty)
        }
    }
}

// MARK: - Shots

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

/// Writes the cards in each style and background, in the middle and fading, 16:9 and 9:16, to `TOMA_CARD_SHOTS` as PNG.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_CARD_SHOTS"] != nil && (MetalCondition.isAvailable || MetalCondition.isRequired)))
func titleCardShots() async throws {
    let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TOMA_CARD_SHOTS"]))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try await withTemporaryDirectory { dir in
        let project = try await cardProject(in: dir)
        let shots: [(TitleCardBackground, String)] = [(.stage, "stage"), (.color(RGBA(0.1, 0.12, 0.2, 1)), "color"), (.blurredFrame, "blurred")]
        for (background, name) in shots {
            for style in TitleCardStyle.allCases {
                for outputSize in [SIMD2(1920, 1080), SIMD2(1080, 1920)] {
                    var document = cardDocument(project, background, style: style)
                    document.style.background = .gradient(start: RGBA(0.35, 0.2, 0.6, 1), end: RGBA(0.1, 0.1, 0.25, 1), angle: 135)
                    let renderer = try FrameRenderer(project: project, document: document, outputSize: outputSize, frameRate: 30)
                    for (time, moment) in [(2.1, "middle"), (1.6, "in")] where style == .centered || moment == "middle" {
                        let bytes = try await offThePool { try renderer.renderBytes(at: time) }
                        try writePNG(bytes, size: outputSize, to: folder.appendingPathComponent("\(name)-\(style)-\(outputSize.x)x\(outputSize.y)-\(moment).png"))
                    }
                }
            }
        }
    }
}
