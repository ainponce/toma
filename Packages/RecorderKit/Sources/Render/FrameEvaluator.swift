// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreGraphics
import ProjectFormat
import simd

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
///   `screens.initial`, or of the last `screens.changes` of the take at or before it); none without one, or for a track
///   the take does not have. What is shown of it is `ScreenGeometry`; its rect is `StageLayout.screenRect` inside the
///   document's padding, at the output's own size, with the document's corners. With a macOS window frame
///   (`style.frame`), the window is `StageLayout.windowRect` there, with those corners but never more than 1.3 times
///   its bar's height (`windowCornerBars`), so they never cut its first button, and the screen fills it under its bar,
///   square there (`WindowFrameLayer`). Around a window the take recorded, the bar does not limit the window's bottom
///   corners, and the screen's top ones under it are as round, the bar behind them: the capture's black corners are
///   covered there too. It is sampled with mipmaps with `style.screenSampling` `mipmapped`.
/// - Screen and geometry changes (`style.geometryTransition`, design §7.6): with `none` the screen, its rect and its
///   window jump at a change, as in phase 0 and 1a. With `spring`, at a change of screen or of the shape where it goes (a
///   `displayGeometry` or `windowGeometry` that changes its region's aspect, mid-take), the rects (screen, window and bar)
///   go from the old ones to the new ones along `GeometryTransitions.progress` of the output time since it
///   (`ScreenTransitions`), and the screen fills the rect it passes through, its crop and region cut to the rect's shape
///   (never past its crop: nothing outside an Area), until it is where it goes. A change of screen crossfades over
///   `GeometryTransitions.crossfade`: the screen being left is `previousScreen`, at the same instant of the source, in the
///   same rect and filling it, under the new one at an opacity from 0 to 1. The cursor and the click effects are on the
///   new screen from the change on, placed on the part of its region shown. Where each screen is shown, the one being
///   left included, is `screenRanges`: the renderer's missing video lists a screen's gaps only there.
/// - Shadow (`style.shadow`, `s` clamped to 0...1, design §7.3): under the screen's rect, or the whole window with a
///   frame, with its (bottom) corners: opacity `0.55·s`, σ `(0.004 + 0.016·s) ×` the output width, `0.010·s ×` the
///   width down. None at 0, and none without a screen.
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
/// - Click effects (`cursor.clickEffect`, `ClickEffects`), with the cursor shown: those of the cursor path's clicks
///   (the `mouseDown`s inside a kept clip, `CursorPath.clicks`), each as it was at its own instant (the source instant
///   its output time shows): on the screen shown then, at its point in the region that screen showed, and of the
///   height of the cursor drawn then, `h`, as a fraction of the screen's rect. A frame draws it on its screen's rect,
///   so it stays on the clicked point however the region moves after it, and keeps its size when the cursor's image
///   changes; none for a click off that region or while its window was not on screen, nor while another screen is
///   shown or the window is not on screen. A click's press ends when no button is down any more
///   (`CursorPath.releases`).
/// - Camera (`camera.show`): the camera's bubble (`CameraBubble`, the zoom's rule too): the first camera track with a
///   segment, from the start of its first segment on, at the `CameraStyleTimeline` of the take's `camera.initial` and
///   its `camera.changes` in output time: a change in a cut rules from the first instant kept after it, one before the
///   first clip keeps its time through that clip's mapping (it is under way at output 0, as it always was), and one
///   after the last never rules.
/// - Zoom camera (design §7.4): the stage is drawn through the zoom camera's path (`ZoomCameraPath.state(atOutput:)`) at
///   the output time, in this output's pixels (`RenderFrame.stage`, `nil` at rest), its centre placed again with
///   `StageCrop` over the screen's rect at this size (the window's with a frame; the stage without a screen): the path
///   places the window at `StagePoints`' 1080 px reference, a few pixels off below it, and this keeps a deep zoom from
///   ever showing a strip of background beside it.
/// - Motion blur (`zoom.motionBlur` and `cursor.motionBlur`, shutters of `σ` frames of the frame rate given, the
///   document's by default, read from 0 to 1; design §7.4 and §7.5): with the camera's shutter, `N_z` is
///   `MotionBlurPlan.sampleCount` of how far the stage's corner that moves most goes in output pixels between the ends of
///   the shutter, `t ± σ_z / 2`; with the cursor's, `N_c` of how far the cursor goes, times the depth at `t`. Every
///   subsample is at an output time (`MotionBlurPlan.sampleTimes`, held to the output), which the paths are in, so none
///   reads what a cut left out; the screen's content, the cursor's image and the click effects are those of `t`.
///   - `N_z > 1`: `N = max(N_z, N_c)` subframes (`RenderFrame.subframes`), the stage of subframe `j` at the `j`-th of `N`
///     times over the camera's shutter and its cursor at the `j`-th of `N` over the cursor's (the cursor of `t` when it
///     does not blur).
///   - Otherwise, `N_c > 1`: the camera is still, so the stage is drawn once and the cursor `N_c` times
///     (`RenderFrame.cursorSamples`), one hidden where there is none.
///   - Otherwise, nothing blurs: one drawing of the frame, as without a blur.
///   The camera and the cursor of the subsamples are read from one simulation of the span of the shutter
///   (`ZoomCameraPath.span(from:through:)`, `CursorPath.span(from:through:)`), not from a checkpoint for each.
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
    /// The output ranges in which each of `paths.stage`'s screens is shown (`ScreenTransitions.shownRanges`): the plan's
    /// screen, and the one being left while a change of screen crossfades. In order and apart.
    var screenRanges: [String: [Range<Int64>]] { transitions.shownRanges }
    /// The take's tracks that recorded a window.
    private let windowTrackIDs: Set<String>
    /// The changes of the screen's shape and of the screen shown, and where each screen is shown.
    private let transitions: ScreenTransitions
    /// `nil` when no camera is drawn.
    private let bubble: CameraBubble?
    /// The take's `cursorImage` events, in time order.
    private let cursorImages: [RecordedCursor]
    /// The output times of the cursor path's clicks, and where each was at its own instant (`nil`: none shown).
    private let clicks: [Int64]
    private let clickPlaces: [ClickPlace?]
    /// A frame's duration in output nanoseconds, which the shutters are fractions of; 0 (no blur) for a frame rate that
    /// is not positive.
    private let frameDuration: Int64
    /// `zoom.motionBlur` and `cursor.motionBlur`, from 0 to 1 (0 if not a number).
    private let zoomShutter: Double
    private let cursorShutter: Double

    /// `paths`: the document's (`MotionPaths(take:events:document:)`), built here when `nil`. `frameRate`: the frames per
    /// second the output is drawn at, whose frame the motion blur's shutters are fractions of; the document's when `nil`.
    public init(
        take: TakeRecord, events: [InputEvent], document: EditDocument, outputSize: SIMD2<Int>, paths: MotionPaths? = nil,
        frameRate: Int? = nil
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
        windowTrackIDs = Set(take.tracks.filter { $0.kind == .window }.map(\.id))
        let style = document.style, stageSize = SIMD2(Double(outputSize.x), Double(outputSize.y))
        transitions = ScreenTransitions(take: take, events: events, document: document, timeMap: timeMap, stage: paths.stage) {
            Self.placement(of: $0, style: style, outputSize: stageSize)
        }
        cursorImages = events.sortedByTime().compactMap { event in
            guard case let .cursorImage(hash, hotspot, size, kind) = event.kind else { return nil }
            return RecordedCursor(t: event.t, hash: hash, hotspot: hotspot, size: size, kind: kind)
        }
        clicks = paths.cursor.clicks.map(\.output)
        clickPlaces = paths.cursor.clicks.map { click in
            ClickPlace(click, take: take.id, sequence: document.sequence, timeMap: timeMap, stage: paths.stage)
        }
        let rate = frameRate ?? document.frameRate
        frameDuration = rate > 0 ? TimeMap.frameTime(1, frameRate: rate) : 0
        func shutter(_ value: Double) -> Double { value.isNaN ? 0 : min(max(value, 0), 1) }
        zoomShutter = shutter(document.zoom.motionBlur)
        cursorShutter = shutter(document.cursor.motionBlur)
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
        // The ends of each shutter, and the paths over them, from which `t` is read too: one simulation for each.
        let zoomEnds = shutterEnds(zoomShutter, at: output)
        let cursorEnds = document.cursor.show ? shutterEnds(cursorShutter, at: output) : [output]
        let zoomSpan = zoomEnds.count > 1 ? paths.zoom.span(from: zoomEnds[0], through: zoomEnds[1]) : nil
        let cursorSpan = cursorEnds.count > 1 ? paths.cursor.span(from: cursorEnds[0], through: cursorEnds[1]) : nil
        /// Where the cursor is placed and what it is drawn with, while it is shown.
        var cursorPlace: CursorPlace?
        if case let (trackID, view)? = paths.stage.shownScreen(at: source) {
            let style = document.style
            let transition = transitions.state(atOutput: output)
            // Where the screen is: where it goes, or on the way there while a change moves it.
            let settled = Self.placement(of: view, style: style, outputSize: size)
            let placement = transition.placement ?? settled
            let rect = placement.screen
            var cornerRadius = style.cornerRadius * size.x
            if case let .macWindow(appearance, title, buttons) = style.frame {
                let top = min(cornerRadius, Self.windowCornerBars * placement.barHeight)
                // A recorded window keeps the style's corners where there are no buttons: the window's bottom ones, and
                // its screen's top ones under the bar.
                let recordedWindow = windowTrackIDs.contains(trackID)
                if !recordedWindow { cornerRadius = top }
                frame.windowFrame = WindowFrameLayer(
                    rect: placement.window, barHeight: placement.barHeight, appearance: appearance, title: title, buttons: buttons,
                    cornerRadius: top, bottomCornerRadius: cornerRadius, screenTopCornerRadius: recordedWindow ? cornerRadius : 0)
            }
            // Out of its own place, each screen fills the rect, cut to its shape.
            let filled = Self.fill(view, settled: settled, into: placement)
            if let previous = transition.previous, let left = transitions.view(of: previous.track, at: source) {
                let leftSettled = Self.placement(of: left, style: style, outputSize: size)
                frame.previousScreen = ScreenLayer(
                    trackID: previous.track, sourceTime: source, rect: rect, cornerRadius: cornerRadius,
                    crop: Self.fill(left, settled: leftSettled, into: placement).view.crop, mipmapped: style.screenSampling == .mipmapped)
            }
            frame.screen = ScreenLayer(
                trackID: trackID, sourceTime: source, rect: rect, cornerRadius: cornerRadius, crop: filled.view.crop,
                mipmapped: style.screenSampling == .mipmapped,
                opacity: frame.previousScreen == nil ? 1 : transition.previous?.opacity ?? 1)
            let shadow = style.shadow.isNaN ? 0 : min(max(style.shadow, 0), 1)
            if shadow > 0 {
                frame.shadow = ShadowLayer(
                    rect: frame.windowFrame?.rect ?? rect, cornerRadius: cornerRadius, opacity: 0.55 * shadow,
                    sigma: (0.004 + 0.016 * shadow) * size.x, offsetY: 0.010 * shadow * size.x)
            }
            if document.cursor.show, view.onScreen, let region = filled.view.region {
                let sample = cursorSpan?.sample(atOutput: output) ?? paths.cursor.sample(atOutput: output)
                // The image is looked up only for a cursor drawn: at `t`, or blurred from somewhere in the shutter.
                if sample.map({ CursorGeometry.contains(CGPoint(x: $0.position.x, y: $0.position.y), region) }) == true
                    || cursorSpan != nil
                {
                    let look = try look(at: source, cursorImageIsReadable: cursorImageIsReadable)
                    let place = CursorPlace(look: look, region: region, rect: rect)
                    frame.cursor = cursorLayer(sample, place)
                    cursorPlace = place
                }
                frame.clickEffects = try ClickEffects.layers(
                    atOutput: output, clicks: clicks, releases: paths.cursor.releases, effect: document.cursor.clickEffect
                ) { index in
                    // As the cursor was drawn at the click, on this frame's rect (on the part of the region it fills).
                    guard let click = clickPlaces[index], click.track == trackID else { return nil }
                    let look = try look(at: click.source, cursorImageIsReadable: cursorImageIsReadable)
                    var point = click.point, regionHeight = click.regionHeight
                    if let part = filled.part {
                        point = (point - SIMD2(part.x, part.y)) / SIMD2(part.width, part.height)
                        regionHeight *= part.height
                        guard point.x >= 0, point.x < 1, point.y >= 0, point.y < 1 else { return nil }
                    }
                    return (
                        SIMD2(rect.x, rect.y) + point * SIMD2(rect.width, rect.height),
                        document.cursor.scale * look.pointHeight * rect.height / regionHeight)
                }
            }
        }
        let screenRect = frame.windowFrame?.rect ?? frame.screen?.rect
        let stage = stageTransform(zoomSpan?.state(atOutput: output) ?? paths.zoom.state(atOutput: output), screen: screenRect)
        frame.stage = stage.depth > 1 ? stage : nil
        if let zoomSpan {
            blur(&frame, at: output, zoom: (zoomSpan, zoomEnds), screen: screenRect, cursor: cursorPlace.flatMap { place in
                cursorSpan.map { (span: $0, ends: cursorEnds, place: place) }
            })
        } else if let cursorPlace, let cursorSpan {
            blur(&frame, at: output, zoom: nil, screen: screenRect, cursor: (cursorSpan, cursorEnds, cursorPlace))
        }
        frame.camera = camera(at: source, output: output)
        return frame
    }

    /// The output times of the ends of a shutter of `shutter` frames about `output`, held to the output; only `output`
    /// without a shutter.
    private func shutterEnds(_ shutter: Double, at output: Int64) -> [Int64] {
        sampleTimes(shutter, count: 2, at: output)
    }

    /// `MotionBlurPlan.sampleTimes` of `count` subsamples of the frame at `output`, held to the output.
    private func sampleTimes(_ shutter: Double, count: Int, at output: Int64) -> [Int64] {
        MotionBlurPlan.sampleTimes(at: output, shutter: shutter, frameDuration: frameDuration, count: count)
            .map { min(max($0, 0), timeMap.duration - 1) }
    }

    /// The zoom camera's `state` (stage units) as the transform of this output's stage: its centre in output pixels,
    /// placed again with `StageCrop` over `screen` (the screen's rect at this size, the window's with a frame; the whole
    /// stage when `nil`). An identity at a depth of 1 or less, or one that is not a number.
    private func stageTransform(_ state: ZoomCameraState, screen: Rect?) -> StageTransform {
        let depth = state.depth
        guard depth > 1, depth.isFinite else { return .identity(outputSize: outputSize) }
        let size = SIMD2<Double>(outputSize)
        let center = state.center / paths.stage.stageSize * size
        let room = screen ?? Rect(x: 0, y: 0, width: size.x, height: size.y)
        return StageTransform(depth: depth, center: StageCrop.clamp(center: center, depth: depth, stage: size, screen: room))
    }

    /// Adds the motion blur of the frame at output time `output` to `frame`, whose `stage` and `cursor` are those of
    /// `output` (see the type's notes): its `subframes`, or its `cursorSamples`, or nothing. `zoom` is the camera over
    /// its shutter, whose ends are `ends`; `cursor`, the cursor over its own and how it is placed (`nil` while the cursor
    /// is not shown or does not blur); `screen`, the rect the camera is placed over.
    private func blur(
        _ frame: inout RenderFrame, at output: Int64, zoom: (span: ZoomCameraPath.Span, ends: [Int64])?, screen: Rect?,
        cursor: (span: CursorPath.Span, ends: [Int64], place: CursorPlace)?
    ) {
        var zoomSamples = 1
        if let zoom {
            zoomSamples = MotionBlurPlan.sampleCount(travelPixels: Self.cornerTravel(
                stageTransform(zoom.span.state(atOutput: zoom.ends[0]), screen: screen),
                stageTransform(zoom.span.state(atOutput: zoom.ends[1]), screen: screen), outputSize: outputSize))
        }
        var cursorSamples = 1
        if let cursor, let a = cursorLayer(cursor.span.sample(atOutput: cursor.ends[0]), cursor.place),
           let b = cursorLayer(cursor.span.sample(atOutput: cursor.ends[1]), cursor.place)
        {
            cursorSamples = MotionBlurPlan.sampleCount(travelPixels: simd_length(b.hotspot - a.hotspot) * (frame.stage?.depth ?? 1))
        }
        if let zoom, zoomSamples > 1 {
            let count = max(zoomSamples, cursorSamples)
            let stageTimes = sampleTimes(zoomShutter, count: count, at: output)
            let cursorTimes = cursorSamples > 1 ? sampleTimes(cursorShutter, count: count, at: output) : nil
            frame.subframes = stageTimes.indices.map { j in
                let stage = stageTransform(zoom.span.state(atOutput: stageTimes[j]), screen: screen)
                guard let cursor, let cursorTimes else { return StageSubframe(stage: stage, cursor: frame.cursor) }
                return StageSubframe(stage: stage, cursor: cursorLayer(cursor.span.sample(atOutput: cursorTimes[j]), cursor.place))
            }
        } else if let cursor, cursorSamples > 1 {
            let layers = sampleTimes(cursorShutter, count: cursorSamples, at: output).map {
                cursorLayer(cursor.span.sample(atOutput: $0), cursor.place)
            }
            guard var hidden = layers.lazy.compactMap({ $0 }).first else { return }
            hidden.opacity = 0
            frame.cursorSamples = layers.map { $0 ?? hidden }
        }
    }

    /// How far, in output pixels, the corner of the stage that moves most goes from `a` to `b`.
    private static func cornerTravel(_ a: StageTransform, _ b: StageTransform, outputSize: SIMD2<Int>) -> Double {
        let size = SIMD2<Double>(outputSize)
        return [SIMD2(0, 0), SIMD2(size.x, 0), SIMD2(0, size.y), size].map { corner in
            simd_length(b.outputPoint(ofStage: corner, outputSize: outputSize) - a.outputPoint(ofStage: corner, outputSize: outputSize))
        }.max() ?? 0
    }

    /// Where the screen of `view` goes, settled, in an output of `outputSize` with `style` (design §7.3): the rect of its
    /// region's aspect inside the padding (`StageLayout.screenRect`); with a macOS window frame, under the bar of the window
    /// around it (`StageLayout.windowRect`).
    private static func placement(of view: ShownScreen, style: StageStyle, outputSize: SIMD2<Double>) -> ScreenPlacement {
        let aspect = view.region.map { $0.width / $0.height }
        switch style.frame {
        case .none:
            let rect = StageLayout.screenRect(contentAspect: aspect, padding: style.padding, outputSize: outputSize)
            return ScreenPlacement(screen: rect, window: rect, barHeight: 0)
        case .macWindow:
            let window = StageLayout.windowRect(contentAspect: aspect, padding: style.padding, outputSize: outputSize)
            return ScreenPlacement(screen: window.screen, window: window.window, barHeight: window.barHeight)
        }
    }

    /// What is shown of `view`, which goes to `settled`, in the rect of `placement`: all of it there; anywhere else (a
    /// change on its way), the part that fills the rect without stretching (`GeometryTransitions.aspectFill`, of its
    /// region's aspect), its crop and its region cut to it, with that `part` as fractions of the region. Never anything
    /// outside its crop, so nothing outside an Area. A view without a region, whose aspect is unknown, is shown whole.
    private static func fill(
        _ view: ShownScreen, settled: ScreenPlacement, into placement: ScreenPlacement
    ) -> (view: ShownScreen, part: Rect?) {
        guard let region = view.region, settled != placement else { return (view, nil) }
        let part = GeometryTransitions.aspectFill(aspect: region.width / region.height, in: placement.screen)
        func cut(_ rect: Rect) -> Rect {
            Rect(
                x: rect.x + part.x * rect.width, y: rect.y + part.y * rect.height, width: part.width * rect.width,
                height: part.height * rect.height)
        }
        return (ShownScreen(crop: cut(view.crop), region: cut(region), onScreen: view.onScreen), part)
    }

    /// The largest corners of a window frame, in heights of its bar. Corners of about 1.37 bars touch the first button's
    /// rim; at 1.3 the rim is 0.03 bars inside them.
    static let windowCornerBars = 1.3

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

    /// How a frame places its cursor: drawn with `look`, at its place on `rect` where it is in `region`.
    private struct CursorPlace {
        var look: Look
        var region: Rect
        var rect: Rect
    }

    /// The drawn cursor where `sample` of the cursor path is (`nil` before the path's first position), placed as
    /// `place` says; `nil` off its region.
    private func cursorLayer(_ sample: CursorSample?, _ place: CursorPlace) -> CursorLayer? {
        guard let sample else { return nil }
        let global = CGPoint(x: sample.position.x, y: sample.position.y)
        guard CursorGeometry.contains(global, place.region) else { return nil }
        let normalized = CursorGeometry.normalized(global, in: place.region)
        let rect = place.rect, look = place.look
        return CursorLayer(
            hotspot: SIMD2(rect.x, rect.y) + normalized * SIMD2(rect.width, rect.height),
            height: document.cursor.scale * look.pointHeight * rect.height / place.region.height,
            image: look.image, hotspotFraction: look.hotspot, aspect: look.aspect, opacity: sample.opacity,
            clickScale: sample.clickScale)
    }

    /// A click as its effect keeps it: what the frame at its output time showed of it, as the cursor is placed there.
    private struct ClickPlace: Sendable {
        /// The screen shown.
        var track: String
        /// Where the click is in the region that screen showed: 0, 0 is its top-left corner, 1, 1 its bottom-right one.
        var point: SIMD2<Double>
        /// That region's height, in points.
        var regionHeight: Double
        /// The source instant shown: the cursor drawn then gives the effect's size.
        var source: HostTime

        /// `nil` when that frame showed no screen of `take`, or the window was not on screen, or the click is off the
        /// region.
        init?(
            _ click: (output: Int64, point: SIMD2<Double>), take: String, sequence: [Clip], timeMap: TimeMap,
            stage: StagePoints
        ) {
            guard let shown = timeMap.source(atOutput: click.output), sequence[shown.clip].take == take,
                  case let (track, view)? = stage.shownScreen(at: shown.source), view.onScreen, let region = view.region
            else { return nil }
            let global = CGPoint(x: click.point.x, y: click.point.y)
            guard CursorGeometry.contains(global, region) else { return nil }
            self.track = track
            point = CursorGeometry.normalized(global, in: region)
            regionHeight = region.height
            source = shown.source
        }
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
