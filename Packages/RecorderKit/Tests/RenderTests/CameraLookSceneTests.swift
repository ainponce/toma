// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat
// @testable for `FrameEvaluator.frame(at:)`.
@testable import Render
import Testing

// The camera's picture worked out for each frame (plan 2b task I9, phase 2 design §6.1 to §6.3): its framing, its colour
// and its background on `RenderFrame.camera`, from the document and what the analysis caches hold. Over a take whose
// screen runs 10 s and whose camera has two segments, 1 from 0 to 4 s and 2 from 5 s to 10 s, so output seconds are
// source seconds. Nothing is drawn: only what the evaluator hands the compositor.

private let screen = Rect(x: 0, y: 0, width: 640, height: 360)
private let size = SIMD2(640, 360)
private let segment1 = CameraSegment(take: takeID, track: cameraID, segment: 1)
private let segment2 = CameraSegment(take: takeID, track: cameraID, segment: 2)
private let mask1 = URL(fileURLWithPath: "/caches/masks/\(takeID)/\(cameraID)/seg-0001-100-7-personMask-1.mov")
private let mask2 = URL(fileURLWithPath: "/caches/masks/\(takeID)/\(cameraID)/seg-0002-200-8-personMask-1.mov")

/// The take: a screen over 10 s, and the camera's segments `[from, to)` (seconds), numbered from 1.
private func cameraTake(_ segments: [(from: Double, to: Double)] = [(0, 4), (5, 10)]) -> TakeRecord {
    makeTake(tracks: [
        displayTrack(globalFrame: screen, segments: [segment(start: base, end: base.adding(seconds: 10))]),
        displayTrack(
            id: cameraID, kind: .camera, globalFrame: nil,
            segments: segments.enumerated().map { k, s in
                segment(track: cameraID, index: k + 1, start: base.adding(seconds: s.from), end: base.adding(seconds: s.to))
            }),
    ])
}

/// A block of `kind` over source seconds `[from, to)` of the take.
private func block(_ number: Int, _ kind: LayoutKind, from: Double, to: Double) -> LayoutBlock {
    LayoutBlock(
        id: "l-0000000\(number)", take: takeID, start: base.adding(seconds: from), end: base.adding(seconds: to), kind: kind,
        instant: false, bubble: nil, split: kind == .split ? SplitLayout() : nil)
}

/// The legacy document of `take` with `change` made to it.
private func document(_ take: TakeRecord = cameraTake(), _ change: (inout EditDocument) -> Void = { _ in }) -> EditDocument {
    var document = EditDocument.legacy(take: take, events: [])
    change(&document)
    return document
}

/// The scene of `document` over `take` with `analysis`.
private func scene(
    _ document: EditDocument, take: TakeRecord = cameraTake(), analysis: AnalysisInputs = .none
) -> FrameEvaluator {
    FrameEvaluator(take: take, events: [], document: document, outputSize: size, analysis: analysis)
}

/// The analysis with the masks of `segments` (1 and 2).
private func masks(_ segments: [Int]) -> AnalysisInputs {
    var analysis = AnalysisInputs()
    for s in segments { analysis.personMasks[s == 1 ? segment1 : segment2] = s == 1 ? mask1 : mask2 }
    return analysis
}

/// The camera of `scene`'s frame at `seconds`.
private func camera(_ scene: FrameEvaluator, at seconds: Double) throws -> CameraLayer {
    try #require(scene.frame(at: seconds).camera, "a camera at \(seconds) s")
}

/// Segment 1's face track: a sample every 100 ms of its 4 s, the face at the left for the first second, then at the right.
private func faceTracks() -> [CameraSegment: CameraFaceTrack] {
    let samples = (0..<40).map { i in
        let t = Double(i) / 10
        return CameraFaceSample(
            t: base.adding(seconds: t),
            face: t < 1
                ? NormalizedRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3) : NormalizedRect(x: 0.6, y: 0.4, width: 0.2, height: 0.3))
    }
    return [segment1: CameraFaceTrack(algorithm: CameraFaceTrack.id, frameSize: [1280, 720], samples: samples)]
}

private func framing(_ mode: CameraFramingMode, x: Double = 0.5, y: Double = 0.5, zoom: Double) -> CameraFraming {
    CameraFraming(mode: mode, center: NormalizedPoint(x: x, y: y), zoom: zoom)
}

@Test func legacyCameraHasNoLook() throws {
    // Masks and faces in the caches change nothing while the document asks for neither.
    var analysis = masks([1, 2])
    analysis.faceTracks = faceTracks()
    let styled = document { document in
        document.camera.mirror = true
        document.camera.border = CameraBorder(width: 0.5, color: RGBA(1, 0, 0, 1))
        document.camera.shadow = 0.7
    }
    for doc in [document(), styled] {
        let plain = scene(doc)
        let analysed = scene(doc, analysis: analysis)
        for t in [0.0, 2, 4.5, 7, 9.9] {
            let frame = analysed.frame(at: t)
            let camera = try #require(frame.camera)
            #expect(camera.look == nil && camera.background == nil, "\(t) s")
            #expect(frame == plain.frame(at: t), "\(t) s")
        }
    }
}

@Test func centeredZoomOneIsNoFraming() throws {
    #expect(try camera(scene(document { $0.camera.framing = framing(.center, zoom: 1) }), at: 2).look == nil)
    // A zoom below 1 or not a number is 1.
    #expect(try camera(scene(document { $0.camera.framing = framing(.center, zoom: 0.5) }), at: 2).look == nil)
    #expect(try camera(scene(document { $0.camera.framing = framing(.center, zoom: .nan) }), at: 2).look == nil)
    // Centred is the middle, whatever the document's centre.
    let zoomed = try camera(scene(document { $0.camera.framing = framing(.center, x: 0.2, y: 0.9, zoom: 1.5) }), at: 2)
    #expect(zoomed.look == CameraLookLayer(framing: CameraFramingLayer(center: SIMD2(0.5, 0.5), zoom: 1.5), lut: nil, intensity: 0))
    // Above 2.5, 2.5.
    let far = try camera(scene(document { $0.camera.framing = framing(.center, zoom: 4) }), at: 2)
    #expect(far.look?.framing == CameraFramingLayer(center: SIMD2(0.5, 0.5), zoom: 2.5))
}

@Test func manualFramingIsTheDocuments() throws {
    let manual = scene(document { $0.camera.framing = framing(.manual, x: 0.3, y: 0.6, zoom: 2) })
    for t in [0.0, 2, 7] {
        #expect(try camera(manual, at: t).look == CameraLookLayer(
            framing: CameraFramingLayer(center: SIMD2(0.3, 0.6), zoom: 2), lut: nil, intensity: 0), "\(t) s")
    }
    // At 1×, the crop still moves along the axis the frame is wider than the shape: a framing.
    let wide = try camera(scene(document { $0.camera.framing = framing(.manual, x: 0.3, y: 0.6, zoom: 1) }), at: 2)
    #expect(wide.look?.framing == CameraFramingLayer(center: SIMD2(0.3, 0.6), zoom: 1))
}

@Test func faceFramingFollowsThePath() throws {
    let doc = document { $0.camera.framing = framing(.face, zoom: CameraFraming.faceZoom) }
    let take = cameraTake()
    var analysis = AnalysisInputs()
    analysis.faceTracks = faceTracks()
    let path = try #require(FaceFramingPath(
        document: doc, take: take, timeMap: TimeMap(sequence: doc.sequence), faces: analysis.faceTracks))
    let following = scene(doc, take: take, analysis: analysis)
    var centers: [SIMD2<Double>] = []
    for t in [0.0, 0.5, 1.2, 2, 3.5, 7] {
        let τ = TimeMap.outputNanoseconds(seconds: t)
        let framing = try #require(try camera(following, at: t).look?.framing, "\(t) s")
        #expect(framing.center == path.center(atOutput: τ), "\(t) s")
        #expect(framing.zoom == CameraFraming.faceZoom, "\(t) s")
        centers.append(framing.center)
    }
    // It goes from the face at the left to the face at the right.
    #expect(centers[0].x < 0.25 && centers[4].x > 0.65)
    // A scene of another size follows the same path.
    let resized = following.resized(to: SIMD2(320, 180))
    #expect(try #require(resized.frame(at: 1.2).camera).look?.framing?.center
        == path.center(atOutput: TimeMap.outputNanoseconds(seconds: 1.2)))
}

@Test func faceFramingBeforeTheCacheIsCentered() throws {
    for zoom in [CameraFraming.faceZoom, 2.2] {
        let doc = document { $0.camera.framing = framing(.face, x: 0.1, y: 0.9, zoom: zoom) }
        for t in [0.0, 2, 7] {
            #expect(try camera(scene(doc), at: t).look == CameraLookLayer(
                framing: CameraFramingLayer(center: SIMD2(0.5, 0.5), zoom: zoom), lut: nil, intensity: 0), "\(zoom)× at \(t) s")
        }
    }
}

@Test func looksAndIntensity() throws {
    func look(_ color: CameraColor, framing: CameraFraming = .legacy) throws -> CameraLookLayer? {
        try camera(scene(document {
            $0.camera.look = color
            $0.camera.framing = framing
        }), at: 2).look
    }
    #expect(try look(.natural) == nil)
    #expect(try look(CameraColor(preset: .natural, lut: nil, intensity: 0.4)) == nil)
    #expect(try look(CameraColor(preset: .warm, lut: nil, intensity: 0.5)) == CameraLookLayer(
        framing: nil, lut: .preset(.warm), intensity: 0.5))
    for preset in [CameraColorPreset.cool, .vivid, .soft, .mono] {
        #expect(try look(CameraColor(preset: preset, lut: nil, intensity: 1)) == CameraLookLayer(
            framing: nil, lut: .preset(preset), intensity: 1), "\(preset)")
    }
    let cube = "assets/0123456789abcdef0123456789abcdef.cube"
    #expect(try look(CameraColor(preset: .custom, lut: cube, intensity: 0.8)) == CameraLookLayer(
        framing: nil, lut: .file(cube), intensity: 0.8))
    // Personalised without its `.cube` is natural.
    #expect(try look(CameraColor(preset: .custom, lut: nil, intensity: 1)) == nil)
    #expect(try look(CameraColor(preset: .custom, lut: "", intensity: 1)) == nil)
    // At 0, below or not a number, no LUT; above 1, 1.
    #expect(try look(CameraColor(preset: .warm, lut: nil, intensity: 0)) == nil)
    #expect(try look(CameraColor(preset: .warm, lut: nil, intensity: -0.3)) == nil)
    #expect(try look(CameraColor(preset: .warm, lut: nil, intensity: .nan)) == nil)
    #expect(try look(CameraColor(preset: .vivid, lut: nil, intensity: 1.7))?.intensity == 1)
    // A look and a framing together.
    #expect(try look(CameraColor(preset: .mono, lut: nil, intensity: 0.25), framing: framing(.manual, x: 0.4, y: 0.4, zoom: 1.2))
        == CameraLookLayer(framing: CameraFramingLayer(center: SIMD2(0.4, 0.4), zoom: 1.2), lut: .preset(.mono), intensity: 0.25))
    // The framing without the look.
    #expect(try look(CameraColor(preset: .natural, lut: nil, intensity: 1), framing: framing(.manual, zoom: 2))?.lut == nil)
}

@Test func backgroundWaitsForItsMask() throws {
    for mode in [CameraBackground.blurred, .removed] {
        let doc = document { document in
            document.camera.background = mode
            document.camera.border = CameraBorder(width: 0.5, color: RGBA(1, 1, 1, 1))
            document.camera.shadow = 0.6
        }
        let original = scene(document { document in
            document.camera.border = CameraBorder(width: 0.5, color: RGBA(1, 1, 1, 1))
            document.camera.shadow = 0.6
        })
        let waiting = scene(doc, analysis: masks([1]))
        let layer = try #require(try camera(waiting, at: 2).background, "\(mode)")
        #expect(layer.mode == (mode == .blurred ? .blurred : .removed))
        #expect(layer.mask.file == mask1)
        // Segment 2 without its mask: the original, with its shape, border and shadow.
        #expect(try camera(waiting, at: 7) == camera(original, at: 7), "\(mode)")
        // Nothing in the caches: the original everywhere.
        let none = scene(doc)
        for t in [0.0, 2, 4.5, 7] {
            #expect(try camera(none, at: t) == camera(original, at: t), "\(mode) at \(t) s")
        }
    }
    // Camera full screen without the mask stays covered.
    let full = scene(document { $0.camera.layout = CameraLayout(kind: .cameraFull); $0.camera.background = .removed })
    #expect(full.frame(at: 2).coveredByCamera)
}

@Test func maskTimeIsTheCameraTime() throws {
    let blurred = scene(document { $0.camera.background = .blurred }, analysis: masks([1, 2]))
    for (t, segment, file, start, end) in [
        (2.0, 1, mask1, 0.0, 4.0), (3.99, 1, mask1, 0, 4), (7, 2, mask2, 5, 10), (9.9, 2, mask2, 5, 10),
        // Between the segments the camera holds segment 1's last frame: segment 1's mask, held the same way.
        (4.5, 1, mask1, 0, 4),
    ] {
        let camera = try camera(blurred, at: t)
        let mask = try #require(camera.background?.mask, "\(t) s")
        #expect(mask.time == camera.sourceTime, "\(t) s")
        #expect(mask.file == file && mask.segmentStart == base.adding(seconds: start), "\(t) s, segment \(segment)")
        #expect(mask.segmentEnd == base.adding(seconds: end), "\(t) s, segment \(segment)")
        #expect(mask.readerID == "personMask:\(file.lastPathComponent)", "\(t) s")
    }
    // On the layouts' path, a card before the camera's first frame shows that frame: its mask is read there, not at the
    // frame's own source instant.
    let late = cameraTake([(1, 10)])
    let split = scene(
        document(late) { $0.camera.layout = CameraLayout(kind: .split, split: SplitLayout()); $0.camera.background = .blurred },
        take: late, analysis: masks([1]))
    let early = try camera(split, at: 0.5)
    #expect(early.sourceTime == base.adding(seconds: 1))
    #expect(early.background?.mask.time == base.adding(seconds: 1))
    #expect(early.background?.mask.segmentStart == base.adding(seconds: 1))
}

@Test func removedBubbleHasNoShapeBorderNorShadow() throws {
    func styled(_ document: inout EditDocument) {
        document.camera.border = CameraBorder(width: 0.5, color: RGBA(1, 1, 1, 1))
        document.camera.shadow = 0.6
        document.camera.mirror = true
    }
    // 1b's path, and the layouts' in a Bubble span (a split block from 6 s on).
    for blocks in [[], [block(1, .split, from: 6, to: 10)]] {
        let original = scene(document { styled(&$0); $0.camera.layouts = blocks })
        let removed = scene(document { styled(&$0); $0.camera.layouts = blocks; $0.camera.background = .removed }, analysis: masks([1, 2]))
        for t in [1.0, 3] {
            let before = try camera(original, at: t)
            try #require(before.cornerRadius > 0 && before.border != nil && before.shadow != nil)
            let after = try camera(removed, at: t)
            let layer = try #require(after.background, "\(t) s")
            #expect(layer.mode == .removed && layer.overScene, "\(t) s")
            #expect(after.cornerRadius == 0 && after.border == nil && after.shadow == nil, "\(t) s")
            // In the bubble's rect, mirrored as it was, at its opacity.
            #expect(after.rect == before.rect && after.mirror && after.opacity == before.opacity, "\(t) s")
            #expect(removed.frame(at: t).coveredByCamera == false)
        }
    }
}

@Test func removedCardKeepsShapeAndBorder() throws {
    for kind in [LayoutKind.split, .cameraOnly] {
        func styled(_ document: inout EditDocument) {
            document.camera.layout = CameraLayout(kind: kind, split: kind == .split ? SplitLayout() : nil)
            document.camera.border = CameraBorder(width: 0.5, color: RGBA(1, 1, 1, 1))
            document.camera.shadow = 0.6
        }
        let original = scene(document { styled(&$0) })
        let removed = scene(document { styled(&$0); $0.camera.background = .removed }, analysis: masks([1, 2]))
        for t in [2.0, 7] {
            let before = try camera(original, at: t)
            try #require(before.border != nil && before.shadow != nil, "\(kind)")
            let after = try camera(removed, at: t)
            let layer = try #require(after.background, "\(kind) at \(t) s")
            #expect(layer.mode == .removed && !layer.overScene, "\(kind) at \(t) s")
            #expect(after.shadow == nil, "\(kind) at \(t) s")
            var kept = after
            kept.shadow = before.shadow
            kept.background = nil
            #expect(kept == before, "\(kind) at \(t) s: the card's rect, corners and border")
        }
    }
}

@Test func removedCameraFullScreenIsNotCovered() throws {
    func full(_ document: inout EditDocument) { document.camera.layout = CameraLayout(kind: .cameraFull) }
    let original = scene(document { full(&$0) }).frame(at: 2)
    try #require(original.coveredByCamera)
    let removed = scene(document { full(&$0); $0.camera.background = .removed }, analysis: masks([1, 2])).frame(at: 2)
    #expect(!removed.coveredByCamera)
    // The background is in the frame, under the person; nothing of the screen.
    #expect(removed.background == original.background)
    #expect(removed.gradientStart == original.gradientStart && removed.gradientEnd == original.gradientEnd)
    #expect(removed.screen == nil && removed.screenOpacity == 0)
    let camera = try #require(removed.camera)
    #expect(camera.background?.mode == .removed && camera.background?.overScene == false)
    #expect(camera.rect == original.camera?.rect && camera.cornerRadius == 0)
    // Blurred keeps the camera's whole picture: still covered.
    let blurred = scene(document { full(&$0); $0.camera.background = .blurred }, analysis: masks([1, 2])).frame(at: 2)
    #expect(blurred.coveredByCamera && blurred.camera?.background?.mode == .blurred)
}

@Test func removedLeavingForScreenOnlyKeepsTheLookOfWhereItWas() throws {
    // In a Screen only span the camera seen is the one leaving: a bubble keeps the bubble's, a card the card's.
    func styled(_ document: inout EditDocument) {
        document.camera.border = CameraBorder(width: 0.5, color: RGBA(1, 1, 1, 1))
        document.camera.shadow = 0.6
        document.camera.background = .removed
    }
    let fromBubble = scene(document { styled(&$0); $0.camera.layouts = [block(1, .screenOnly, from: 5, to: 10)] }, analysis: masks([1, 2]))
    let bubble = try camera(fromBubble, at: 5.1)
    #expect(bubble.opacity > 0 && bubble.opacity < 1)
    #expect(bubble.background?.overScene == true && bubble.cornerRadius == 0 && bubble.border == nil)

    let fromCard = scene(
        document { styled(&$0); $0.camera.layouts = [block(1, .split, from: 0, to: 5), block(2, .screenOnly, from: 5, to: 10)] },
        analysis: masks([1, 2]))
    let card = try camera(fromCard, at: 5.1)
    #expect(card.opacity > 0 && card.opacity < 1)
    #expect(card.background?.overScene == false && card.cornerRadius > 0 && card.border != nil && card.shadow == nil)
}

@Test func backgroundWhoseMaskIsNotDecodedIsTheOriginal() throws {
    // The analysis lists the mask, but the renderer could not decode the frame of it (a corrupt file, say): it drops the
    // background (`RenderFrame.droppingCameraBackground()`), and the frame is the Original's, the camera's shape, border
    // and shadow and what it covers among it, in every layout and for both backgrounds.
    let layouts = [
        CameraLayout.bubble, CameraLayout(kind: .split, split: SplitLayout()), CameraLayout(kind: .cameraOnly),
        CameraLayout(kind: .cameraFull),
    ]
    for layout in layouts {
        func styled(_ document: inout EditDocument) {
            document.camera.layout = layout
            document.camera.border = CameraBorder(width: 0.5, color: RGBA(1, 1, 1, 1))
            document.camera.shadow = 0.6
            document.camera.mirror = true
        }
        let original = scene(document { styled(&$0) })
        for mode in [CameraBackground.removed, .blurred] {
            let masked = scene(document { styled(&$0); $0.camera.background = mode }, analysis: masks([1, 2]))
            for t in [2.0, 4.5, 7] {
                let frame = masked.frame(at: t)
                try #require(frame.camera?.background != nil, "\(layout.kind), \(mode) at \(t) s")
                #expect(frame.droppingCameraBackground() == original.frame(at: t), "\(layout.kind), \(mode) at \(t) s")
            }
        }
        // A frame without a background is as it is.
        let plain = original.frame(at: 2)
        #expect(plain.droppingCameraBackground() == plain)
    }
}
