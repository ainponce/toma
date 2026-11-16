// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreGraphics
import ProjectFormat

/// Works out what an output frame shows at an output time: a pure function of the take, its events, the edit
/// document and the output size.
///
/// The output is the document's clips one after the other (`TimeMap`, design §6.6): output time `t` shows the source
/// instant `timeMap.source(atOutput:)` of `t` in nanoseconds, clamped to `[0, D)`; an output of 0 s shows only the
/// background. The legacy document (`EditDocument.legacy`) is one clip at 1× over `TakeTimeline.bounds`, so it shows
/// what phase 0 and 1a show at every time before the end, with the same arithmetic.
///
/// - Background: the document's gradient, colour, wallpaper (`WallpaperPreset`), image or desktop picture
///   (`BackgroundImage`); a wallpaper, an image and the desktop are blurred by σ = `backgroundBlur` × 0.04 × the output
///   width, with `backgroundBlur` clamped to 0...1. The desktop is the photo of the display of `screens.initial`, the
///   first screen shown, as the take started; a window has none. A wallpaper this version does not know, and a desktop
///   without a display, draw the classic gradient (`Background.tomaClassic`), as an image does that is missing or
///   unreadable (`Compositor`).
/// - Screen: the one the stage shows at the source instant (`StagePoints.shownScreen(at:)`: the take's track of
///   `screens.initial`, or of the last `screens.changes` of the take at or before it; it jumps); none without one, or
///   for a track the take does not have. What is shown of it is `ScreenGeometry`; its rect is `StageLayout.screenRect`
///   inside the document's padding, at the output's own size, with the document's corners. With a macOS window frame
///   (`style.frame`), the window is `StageLayout.windowRect` there, with those corners, and the screen fills it under
///   its bar (`WindowFrameLayer`).
/// - Cursor (`cursor.show`, design §7.5): where the cursor path is at the output time (`CursorPath.sample(atOutput:)`
///   of the motion paths: with `smoothing` off, phase 0's rule, the last raw position at or before it moved toward the
///   next one within 50 ms), placed on the screen's rect as it is in the region the screen shows; hidden off that
///   region, while a window is not on screen, and without a usable frame. Its opacity (hiding when idle) and its press
///   (only with smoothing) are the path's too. Its image, at the source instant:
///   - `system`: the last `cursorImage` of the take at or before it; before the first, and when it cannot be read (the
///     renderer says which can, `frame(at:cursorImageIsReadable:)`) or has no usable size, Toma's arrow.
///   - `toma`: Toma's cursor of that `cursorImage`'s `kind`; without a `kind`, the recorded image as in `system`;
///     without images (takes before 1b), the arrow.
///   It is `scale × its height in points × the screen's rect height / the region's height` tall: in `toma`, 24 pt,
///   whatever it is drawn with; in `system`, a recorded image's `size.height` (and the arrow's 24 pt).
/// - Camera (`camera.show`): the camera's bubble (`CameraBubble`, the zoom's rule too): the first camera track with a
///   segment, from the start of its first segment on, at the `CameraStyleTimeline` of the take's `camera.initial` and
///   its `camera.changes` in output time: a change in a cut rules from the first instant kept after it, one before the
///   first clip keeps its time through that clip's mapping (it is under way at output 0, as it always was), and one
///   after the last never rules.
///
/// The motion paths (`MotionPaths`: the screens, the cursor's path) are the document's revision's, given or built.
public struct FrameEvaluator: Sendable {
    public let document: EditDocument
    public let timeMap: TimeMap
    /// Host time at output time 0: the start of the first clip (host time 0 without clips).
    public let timelineStart: HostTime
    /// Output seconds: `timeMap.durationSeconds`.
    public let duration: Double

    private let takeID: String
    private let outputSize: SIMD2<Int>
    private let background: BackgroundLayer
    /// The gradient of a `.gradient` background; the classic one with any other.
    private let gradient: Gradient
    /// Which screen is shown, and the drawn cursor's path.
    private let paths: MotionPaths
    /// The video tracks a frame can show: the screens of `paths.stage`, then the camera when it is shown.
    let videoTrackIDs: [String]
    /// `nil` when no camera is drawn.
    private let bubble: CameraBubble?
    /// The take's `cursorImage` events, in time order.
    private let cursorImages: [RecordedCursor]

    /// `paths`: the document's (`MotionPaths(take:events:document:)`), built here when `nil`.
    public init(
        take: TakeRecord, events: [InputEvent], document: EditDocument, outputSize: SIMD2<Int>, paths: MotionPaths? = nil
    ) {
        let timeMap = TimeMap(sequence: document.sequence)
        self.document = document
        self.timeMap = timeMap
        timelineStart = document.sequence.first?.start ?? HostTime(nanoseconds: 0)
        duration = timeMap.durationSeconds
        takeID = take.id
        self.outputSize = outputSize
        (background, gradient) = Self.background(of: document.style, take: take, outputSize: outputSize, screens: document.screens)
        let paths = paths ?? MotionPaths(take: take, events: events, document: document)
        self.paths = paths
        bubble = CameraBubble(document: document, take: take, timeMap: timeMap)
        videoTrackIDs = paths.stage.screenTrackIDs + [bubble?.trackID].compactMap { $0 }
        cursorImages = events.sortedByTime().compactMap { event in
            guard case let .cursorImage(hash, hotspot, size, kind) = event.kind else { return nil }
            return RecordedCursor(t: event.t, hash: hash, hotspot: hotspot, size: size, kind: kind)
        }
    }

    /// The legacy document of the take (`EditDocument.legacy(take:events:)`) with the gradient, the padding and the
    /// corners of `style`, and its cursor `style.cursorPointHeight` tall: what phase 0 and 1a draw.
    public init(take: TakeRecord, events: [InputEvent], style: StyleV0, outputSize: SIMD2<Int>) {
        func rgba(_ color: SIMD4<Float>) -> RGBA { RGBA(Double(color.x), Double(color.y), Double(color.z), Double(color.w)) }
        var document = EditDocument.legacy(take: take, events: events)
        document.style.background = .gradient(
            start: rgba(style.gradientStart), end: rgba(style.gradientEnd), angle: Double(style.gradientAngleDegrees))
        document.style.padding = style.paddingFraction
        document.style.cornerRadius = style.cornerRadiusFraction
        document.cursor.scale = style.cursorPointHeight / 24
        self.init(take: take, events: events, document: document, outputSize: outputSize)
    }

    /// The frame at `outputTime` with every recorded cursor image taken as readable: for tests, which know. Anything that
    /// draws asks `frame(at:cursorImageIsReadable:)` with the images it can read, or it would draw another image in the
    /// place, the hotspot and the aspect of one it cannot.
    func frame(at outputTime: Double) -> RenderFrame {
        frame(at: outputTime) { _ in true }
    }

    /// The frame at `outputTime`, with the recorded cursor images `cursorImageIsReadable` says can be read (by hash):
    /// Toma's arrow is drawn for one it cannot read (the renderer's, `CursorImages`).
    public func frame(at outputTime: Double, cursorImageIsReadable: (_ hash: String) throws -> Bool) rethrows -> RenderFrame {
        var frame = RenderFrame(
            outputSize: outputSize, gradientStart: gradient.start, gradientEnd: gradient.end, gradientAngleDegrees: gradient.angle,
            background: background)
        let τ = TimeMap.outputNanoseconds(seconds: outputTime)
        guard let shown = timeMap.source(atOutput: τ), document.sequence[shown.clip].take == takeID else { return frame }
        let source = shown.source
        // The output time shown, as `source(atOutput:)` clamps it.
        let output = min(max(τ, 0), timeMap.duration - 1)
        let size = SIMD2(Double(outputSize.x), Double(outputSize.y))
        if case let (trackID, view)? = paths.stage.shownScreen(at: source) {
            let aspect = view.region.map { $0.width / $0.height }, padding = document.style.padding
            let cornerRadius = document.style.cornerRadius * size.x
            let rect: Rect
            switch document.style.frame {
            case .none:
                rect = StageLayout.screenRect(contentAspect: aspect, padding: padding, outputSize: size)
            case let .macWindow(appearance, title, buttons):
                let window = StageLayout.windowRect(contentAspect: aspect, padding: padding, outputSize: size)
                rect = window.screen
                frame.windowFrame = WindowFrameLayer(
                    rect: window.window, barHeight: window.barHeight, appearance: appearance, title: title, buttons: buttons,
                    cornerRadius: cornerRadius)
            }
            frame.screen = ScreenLayer(trackID: trackID, sourceTime: source, rect: rect, cornerRadius: cornerRadius, crop: view.crop)
            if document.cursor.show, view.onScreen, let region = view.region {
                frame.cursor = try cursor(
                    at: output, source: source, in: region, shownIn: rect, cursorImageIsReadable: cursorImageIsReadable)
            }
        }
        frame.camera = camera(at: source, output: output)
        return frame
    }

    /// A gradient as the shader takes it.
    private typealias Gradient = (start: SIMD4<Float>, end: SIMD4<Float>, angle: Float)

    /// What the compositor draws for the background of `style`, and the gradient it draws with `.gradient` (or for an
    /// image it cannot read): that of a gradient, the classic one otherwise. An unknown wallpaper, and the desktop when
    /// the first screen of `screens` is not a display of `take`, are the classic gradient.
    private static func background(
        of style: StageStyle, take: TakeRecord, outputSize: SIMD2<Int>, screens: ScreenPlan
    ) -> (layer: BackgroundLayer, gradient: Gradient) {
        func floats(_ color: RGBA) -> SIMD4<Float> { SIMD4(Float(color.r), Float(color.g), Float(color.b), Float(color.a)) }
        func classic() -> Gradient {
            guard case let .gradient(start, end, angle) = Background.tomaClassic else { preconditionFailure("Toma classic is a gradient") }
            return (floats(start), floats(end), Float(angle))
        }
        let blur = style.backgroundBlur.isNaN ? 0 : min(max(style.backgroundBlur, 0), 1)
        let sigma = blur * 0.04 * Double(outputSize.x)
        func image(_ source: BackgroundImage.Source) -> BackgroundLayer { .image(BackgroundImage(source: source, blurSigma: sigma)) }
        switch style.background {
        case let .gradient(start, end, angle):
            return (.gradient, (floats(start), floats(end), Float(angle)))
        case let .color(color):
            return (.color(floats(color)), classic())
        case let .wallpaper(id):
            return (WallpaperPreset.preset(id: id).map { .wallpaper($0, blurSigma: sigma) } ?? .gradient, classic())
        case let .image(file):
            return (image(.asset(file)), classic())
        case .desktop:
            let display = screens.initial[take.id].flatMap(take.track).flatMap { $0.kind.isScreen ? $0.source.displayID : nil }
            return (display.map { image(.desktop(take: take.id, displayID: $0)) } ?? .gradient, classic())
        }
    }

    /// A `cursorImage` event: from `t` on, macOS showed the image `hash`.
    private struct RecordedCursor: Sendable {
        var t: HostTime
        var hash: String
        var hotspot: SIMD2<Double>
        /// In points.
        var size: SIMD2<Double>
        var kind: CursorKind?
    }

    /// What a cursor is drawn with: its image, its hotspot and aspect, and its height in points.
    private struct Look {
        var image: CursorImageRef
        var hotspot: SIMD2<Double>
        var aspect: Double
        var pointHeight: Double

        /// Toma's cursor of `kind`, 24 pt tall.
        static func toma(_ kind: CursorKind) -> Look {
            Look(image: .toma(kind), hotspot: CursorSprite.hotspot(of: kind), aspect: CursorSprite.aspect(of: kind), pointHeight: 24)
        }
    }

    /// The drawn cursor at output time `τ` (one `source(atOutput:)` shows, at source instant `source`): where the cursor
    /// path is then, placed on `rect` where it is in `region`. `nil` before the path's first position and off `region`.
    private func cursor(
        at τ: Int64, source: HostTime, in region: Rect, shownIn rect: Rect, cursorImageIsReadable: (String) throws -> Bool
    ) rethrows -> CursorLayer? {
        guard let sample = paths.cursor.sample(atOutput: τ) else { return nil }
        let global = CGPoint(x: sample.position.x, y: sample.position.y)
        guard CursorGeometry.contains(global, region) else { return nil }
        let normalized = CursorGeometry.normalized(global, in: region)
        let look = try look(at: source, cursorImageIsReadable: cursorImageIsReadable)
        return CursorLayer(
            hotspot: SIMD2(rect.x, rect.y) + normalized * SIMD2(rect.width, rect.height),
            height: document.cursor.scale * look.pointHeight * rect.height / region.height,
            image: look.image, hotspotFraction: look.hotspot, aspect: look.aspect, opacity: sample.opacity,
            clickScale: sample.clickScale)
    }

    /// What the cursor is drawn with at source instant `source`, by the document's `cursor.style` (see the type's notes).
    private func look(at source: HostTime, cursorImageIsReadable: (String) throws -> Bool) rethrows -> Look {
        // The last image at or before `source`.
        var low = 0, high = cursorImages.count
        while low < high {
            let mid = (low + high) / 2
            if cursorImages[mid].t <= source { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return .toma(.arrow) }
        let recorded = cursorImages[low - 1]
        if document.cursor.style == .toma, let kind = recorded.kind { return .toma(kind) }
        let size = recorded.size
        guard size.x.isFinite, size.y.isFinite, size.x > 0, size.y > 0, recorded.hotspot.x.isFinite,
              recorded.hotspot.y.isFinite, try cursorImageIsReadable(recorded.hash)
        else { return .toma(.arrow) }
        return Look(
            image: .recorded(hash: recorded.hash), hotspot: recorded.hotspot.clamped(lowerBound: .zero, upperBound: .one),
            aspect: size.x / size.y, pointHeight: document.cursor.style == .toma ? 24 : size.y)
    }

    /// The camera at source instant `source` and output time `output`, from the start of its first segment on.
    private func camera(at source: HostTime, output: Int64) -> CameraLayer? {
        guard let bubble, let frame = bubble.frame(
            atOutput: output, host: source, output: SIMD2(Double(outputSize.x), Double(outputSize.y)))
        else { return nil }
        return CameraLayer(trackID: bubble.trackID, sourceTime: source, rect: frame.rect, cornerRadius: frame.cornerRadius)
    }
}
