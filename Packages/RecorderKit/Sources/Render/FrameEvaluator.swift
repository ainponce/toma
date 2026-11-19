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
/// background. The legacy document (`EditDocument.legacy`) is one clip at 1× over `TakeTimeline.editableBounds` (with a
/// screen, `bounds`), so it shows what phase 0 and 1a show at every time before the end, with the same arithmetic.
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
/// - Device frame (`style.frame` `.device`, phase 2 design §6.7, `deviceFrame-1`), around the screen fitted whole
///   (`style.reframe` `fit`): the screen goes inside the largest device whose bounds fit inside the padding
///   (`StageLayout.deviceRects(contentAspect:padding:outputSize:model:)`), the zoom keeps to those bounds as to a window,
///   a card holds them whole, and `DeviceFrameScene` puts the device around the screen as either path left it, with the
///   device's screen corners and the shadow cast by its body.
/// - Follow the cursor (`style.reframe` `followCursor`, phase 2 design §6.5, `reframe-1`): never a window or device
///   frame. A view wider than the room inside the padding (`StagePoints.isReframed(_:)`) fills all of it
///   (`StagePoints.room`) with the window of its region the motion paths' `ReframePath` shows at the output time
///   (`part(of:atOutput:stage:)`): its crop and its region are cut to that window, so `ScreenLayer.crop` is what is
///   drawn (the privacy regions are placed in it), the cursor and the click effects are placed in the window by the
///   rules below and hidden outside it, the zoom keeps to the room, and a card takes the room's shape. While a change
///   moves the rect, the part of the rect's shape about the window's centre, which is the window when it gets there. A
///   view no wider than the room is placed whole, as without a frame. The window's motion is not blurred: the content of
///   a frame is that of its time, the cursor's subsamples placed in its window.
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
///   after the last never rules. Each style is measured against `camera.sizeReference` (the output's height, as in 1b,
///   or its shorter side), and the camera is drawn with the document's look: mirrored, with its border and its shadow
///   (`cameraLayer`, 1c design §14.3).
/// - Camera layouts (`camera.layout` and `camera.layouts`, 1c design §5; plan decision 13): a document whose layouts are
///   trivial (`LayoutTimeline.isTrivial`: no block shown and the project's layout Bubble, as every document of 1b) is
///   drawn as these notes say, by 1b's path untouched. Any other one by the layouts' path, from the frame 1b's path makes
///   (`laidOut`): what is shown is `LayoutTimeline.geometry(atOutput:_:)` at the output time, with the aspect of the
///   screen's group as it animates (the whole window, bar included, with a frame) and the bubble as it is presented
///   (measured against `camera.sizeReference`). The timeline is built once for the scene, with the camera readable as
///   the scene is given it (plan decision 40), and blends the layouts at their borders in one composition (§14.2).
///   - The screen's group (the screens, the window frame, the shadow, the cursor and the click effects) is moved and
///     scaled from where 1b's path places it onto the screen's card, with the card's corners (a window's worked out from
///     them by the rule above, `windowCorners`), and fades at the card's opacity as one group
///     (`RenderFrame.screenOpacity`): nothing of it where the card is hidden. The shadow keeps its blur.
///   - The zoom (1c design §5.4) acts over the whole stage in the Bubble and Screen only, as on 1b's path. In the layouts
///     of cards (a split, Camera only, Camera full screen), the background (with the shadow and the window frame) stays
///     still and the zoom acts inside the screen's card (`RenderFrame.card`): the screens, the cursor and the click
///     effects through the card's camera (`MotionPaths.cardZoom`, an identity without a split), its point in focus at
///     the middle of the screen's rect on the card, cut to that rect with its corners. Between the two, by
///     `LayoutTimeline.cardWeight(atOutput:)` (`p`), the background's transform is the stage's zoom and the identity
///     mixed, the content's the stage's zoom and the card's (`StageTransform.mix`), and the cut the screen's rect as the
///     background's transform draws it, so from the stage to a card nothing jumps. The motion blur in a card follows
///     the rules below over the content's transform, the travel of the screen's rect's corners, and the cursor placed on
///     the card; the background is drawn once.
///   - The camera fills its card (`cameraLayer`, with the card's opacity and its border and shadow weights), and is
///     none where the card is hidden. Before the camera's first frame, a card shows that frame (§5.1); the Bubble's is
///     hidden then, as in 1b.
///   - With the camera opaque over the whole output and the screen hidden (Camera full screen settled, §14.4), the frame
///     is the camera alone (`RenderFrame.coveredByCamera`).
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
///   reads what a cut left out; the screen's content, the cursor's image and the click effects are those of `t`. A
///   shutter that crosses a jump of its path (an instant block's edge, `ZoomCameraPath.jumps`; an unsmoothed cursor at a
///   cut, `CursorPath.jumps`) is held to the side of `t` (`MotionBlurPlan.sampleTimes(at:shutter:frameDuration:count:jumps:)`),
///   so a frame is never the images of both sides.
///   - `N_z > 1`: `N = max(N_z, N_c)` subframes (`RenderFrame.subframes`), the stage of subframe `j` at the `j`-th of `N`
///     times over the camera's shutter and its cursor at the `j`-th of `N` over the cursor's (the cursor of `t` when it
///     does not blur).
///   - Otherwise, `N_c > 1`: the camera is still, so the stage is drawn once and the cursor `N_c` times
///     (`RenderFrame.cursorSamples`), one hidden where there is none.
///   - Otherwise, nothing blurs: one drawing of the frame, as without a blur.
///   The camera and the cursor of the subsamples are read from one simulation of the span of the shutter
///   (`ZoomCameraPath.span(from:through:)`, `CursorPath.span(from:through:)`), not from a checkpoint for each.
///
/// - Phase 2's layers (phase 2 design §11 and §12): each is worked out by its own scene, in its own file
///   (`FrameEvaluator+<Layer>.swift`), built once with the scene (those of the size again by `resized(to:)`), and put onto
///   a frame of the take last (`finishLayers`), on 1b's path and on the layouts': privacy on the screens, the camera's
///   sync, framing, colour and background, the device frame, the keys and the captions. With the legacy values each is
///   `nil` or empty and changes nothing of the frame.
///
/// The motion paths (`MotionPaths`: the screens, the cursor's path) are the document's revision's, given or built.
public struct FrameEvaluator: Sendable {
    public let document: EditDocument
    public let timeMap: TimeMap
    /// Host time at output time 0: the start of the first clip (host time 0 without clips).
    public let timelineStart: HostTime
    /// Output seconds: `timeMap.durationSeconds`.
    public let duration: Double

    /// The size of the frames, in pixels.
    public private(set) var outputSize: SIMD2<Int>
    /// The frames per second the output is drawn at: the motion blur's frame, and the grid a frame `n` is on.
    public let frameRate: Int
    /// What the frames read of the project's analysis caches (phase 2 design §10): `.none` in phase 1.
    public let analysis: AnalysisInputs

    private let take: TakeRecord
    private let events: [InputEvent]
    private var takeID: String { take.id }
    private var background: BackgroundLayer
    /// The gradient of a `.gradient` background; the classic one with any other.
    private var gradient: Gradient
    /// Which screen is shown, and the drawn cursor's path: the motion paths of the document's revision, which a scene of
    /// a later revision that keeps them (`MotionPaths.areThePaths(of:)`) can be made with.
    public let paths: MotionPaths
    /// The video tracks a frame can show: the screens of `paths.stage`, then the camera when it is shown.
    let videoTrackIDs: [String]
    /// The output ranges in which each of `paths.stage`'s screens is shown (`ScreenTransitions.shownRanges`): the plan's
    /// screen, and the one being left while a change of screen crossfades. In order and apart.
    var screenRanges: [String: [Range<Int64>]] { transitions.shownRanges }
    /// The take's tracks that recorded a window.
    private let windowTrackIDs: Set<String>
    /// The changes of the screen's shape and of the screen shown, and where each screen is shown.
    private var transitions: ScreenTransitions
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
    /// Which layout rules at each output instant, and what is shown as they change: built once for the scene.
    private let layouts: LayoutTimeline
    /// Phase 2's layers (`finishLayers`): those that depend on the output's size are made again by `resized(to:)`.
    private let privacy: PrivacyScene
    private let cameraSync: CameraSyncScene
    /// Internal for tests: it sees the scene's `layouts`.
    let cameraLook: CameraLookScene
    private var deviceFrame: DeviceFrameScene
    private var keys: KeyOverlayScene
    private var captions: CaptionScene

    /// The two ways a frame is drawn (plan decision 13).
    enum Path {
        /// 1b's, untouched: a document whose layouts are trivial.
        case legacy
        /// The camera layouts' (`laidOut`).
        case layouts
    }

    /// For tests: the path every frame takes; when `nil`, 1b's for a document whose layouts are trivial
    /// (`LayoutTimeline.isTrivial`) and the layouts' for any other.
    var forcedPath: Path?

    /// `paths`: the document's (`MotionPaths(take:events:document:cameraReadable:)`), built here when `nil`. `frameRate`:
    /// the frames per second the output is drawn at, whose frame the motion blur's shutters are fractions of; the
    /// document's when `nil`.
    /// `cameraReadable`: some camera track of the take has a segment that can be read (plan decision 40, which the renderer
    /// finds in the package); without one, or without a camera track with a segment, the layouts that need the camera are
    /// shown as Screen only. `analysis`: what the frames read of the analysis caches (phase 2 design §10).
    public init(
        take: TakeRecord, events: [InputEvent], document: EditDocument, outputSize: SIMD2<Int>, paths: MotionPaths? = nil,
        frameRate: Int? = nil, cameraReadable: Bool = true, analysis: AnalysisInputs = .none
    ) {
        let timeMap = TimeMap(sequence: document.sequence)
        self.document = document
        self.timeMap = timeMap
        timelineStart = document.sequence.first?.start ?? HostTime(nanoseconds: 0)
        duration = timeMap.durationSeconds
        self.take = take
        self.events = events
        self.outputSize = outputSize
        (background, gradient) = Self.background(of: document.style, take: take, outputSize: outputSize, screens: document.screens)
        let paths = paths ?? MotionPaths(take: take, events: events, document: document, cameraReadable: cameraReadable)
        self.paths = paths
        bubble = CameraBubble(document: document, take: take, timeMap: timeMap)
        videoTrackIDs = paths.stage.screenTrackIDs + [bubble?.trackID].compactMap { $0 }
        windowTrackIDs = Set(take.tracks.filter { $0.kind == .window }.map(\.id))
        transitions = Self.transitions(take: take, events: events, document: document, timeMap: timeMap, paths: paths, outputSize: outputSize)
        cursorImages = events.sortedByTime().compactMap { event in
            guard case let .cursorImage(hash, hotspot, size, kind) = event.kind else { return nil }
            return RecordedCursor(t: event.t, hash: hash, hotspot: hotspot, size: size, kind: kind)
        }
        clicks = paths.cursor.clicks.map(\.output)
        clickPlaces = paths.cursor.clicks.map { click in
            ClickPlace(click, take: take.id, sequence: document.sequence, timeMap: timeMap, stage: paths.stage)
        }
        let rate = frameRate ?? document.frameRate
        self.frameRate = rate
        frameDuration = rate > 0 ? TimeMap.frameTime(1, frameRate: rate) : 0
        func shutter(_ value: Double) -> Double { value.isNaN ? 0 : min(max(value, 0), 1) }
        zoomShutter = shutter(document.zoom.motionBlur)
        cursorShutter = shutter(document.cursor.motionBlur)
        layouts = LayoutTimeline(document: document, take: take, timeMap: timeMap, cameraReadable: cameraReadable && bubble != nil)
        self.analysis = analysis
        privacy = PrivacyScene(document: document, take: take, events: events)
        cameraSync = CameraSyncScene(document: document, take: take)
        cameraLook = CameraLookScene(document: document, take: take, analysis: analysis, layouts: layouts)
        deviceFrame = DeviceFrameScene(document: document, outputSize: outputSize)
        keys = KeyOverlayScene(document: document, take: take.id, events: events, timeMap: timeMap, outputSize: outputSize)
        captions = CaptionScene(document: document, timeMap: timeMap, outputSize: outputSize)
    }

    /// The same document, motion paths, frames per second and analysis drawn at `outputSize`: only what depends on the
    /// size (the background's blur, where the screens go and how a change moves them, the device frame, the keys and the
    /// captions) is worked out again, so it is cheap; the paths, which are in output time and stage units, are shared.
    public func resized(to outputSize: SIMD2<Int>) -> FrameEvaluator {
        guard outputSize != self.outputSize else { return self }
        var resized = self
        resized.outputSize = outputSize
        (resized.background, resized.gradient) = Self.background(
            of: document.style, take: take, outputSize: outputSize, screens: document.screens)
        resized.transitions = Self.transitions(
            take: take, events: events, document: document, timeMap: timeMap, paths: paths, outputSize: outputSize)
        resized.deviceFrame = DeviceFrameScene(document: document, outputSize: outputSize)
        resized.keys = KeyOverlayScene(document: document, take: take.id, events: events, timeMap: timeMap, outputSize: outputSize)
        resized.captions = CaptionScene(document: document, timeMap: timeMap, outputSize: outputSize)
        return resized
    }

    /// The changes of the screen's shape and of the screen shown, placed in an output of `outputSize`.
    private static func transitions(
        take: TakeRecord, events: [InputEvent], document: EditDocument, timeMap: TimeMap, paths: MotionPaths,
        outputSize: SIMD2<Int>
    ) -> ScreenTransitions {
        let style = document.style, stageSize = SIMD2(Double(outputSize.x), Double(outputSize.y))
        return ScreenTransitions(take: take, events: events, document: document, timeMap: timeMap, stage: paths.stage) {
            Self.placement(of: $0, style: style, outputSize: stageSize, stage: paths.stage)
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
        // The ends of each shutter, and the paths over them, from which `t` is read too: one simulation for each.
        let zoomEnds = shutterEnds(zoomShutter, at: output, jumps: paths.zoom.jumps)
        let cursorEnds = document.cursor.show ? shutterEnds(cursorShutter, at: output, jumps: paths.cursor.jumps) : [output]
        let zoomSpan = zoomEnds.count > 1 ? paths.zoom.span(from: zoomEnds[0], through: zoomEnds[1]) : nil
        let cursorSpan = cursorEnds.count > 1 ? paths.cursor.span(from: cursorEnds[0], through: cursorEnds[1]) : nil
        /// Where the cursor is placed and what it is drawn with, while it is shown.
        var cursorPlace: CursorPlace?
        if case let (trackID, view)? = paths.stage.shownScreen(at: source) {
            let style = document.style
            let transition = transitions.state(atOutput: output)
            // Where the screen is: where it goes, or on the way there while a change moves it.
            let settled = Self.placement(of: view, style: style, outputSize: size, stage: paths.stage)
            let placement = transition.placement ?? settled
            let rect = placement.screen
            let styleCorners = style.cornerRadius * size.x
            var cornerRadius = styleCorners
            // Following the cursor there is no window frame (phase 2 design §6.5).
            if case let .macWindow(appearance, title, buttons) = style.frame, style.reframe == .fit {
                // A recorded window keeps the style's corners where there are no buttons: the window's bottom ones, and
                // its screen's top ones under the bar.
                let recordedWindow = windowTrackIDs.contains(trackID)
                func window(_ placement: ScreenPlacement) -> (layer: WindowFrameLayer, cornerRadius: Double) {
                    let (top, bottom) = Self.windowCorners(styleCorners, barHeight: placement.barHeight, recordedWindow: recordedWindow)
                    return (WindowFrameLayer(
                        rect: placement.window, barHeight: placement.barHeight, appearance: appearance, title: title, buttons: buttons,
                        cornerRadius: top, bottomCornerRadius: bottom, screenTopCornerRadius: recordedWindow ? bottom : 0), bottom)
                }
                let moving = window(placement)
                frame.windowFrame = moving.layer
                cornerRadius = moving.cornerRadius
                // Its title is drawn from where it goes while it moves.
                if placement != settled { frame.settledWindowFrame = window(settled).layer }
            }
            // Out of its own place, each screen fills the rect, cut to its shape; reframed, about its window.
            let filled = Self.fill(view, settled: settled, into: placement, window: reframedPart(of: view, atOutput: output))
            if let previous = transition.previous, let left = transitions.view(of: previous.track, at: source) {
                let leftSettled = Self.placement(of: left, style: style, outputSize: size, stage: paths.stage)
                let leftFilled = Self.fill(
                    left, settled: leftSettled, into: placement, window: reframedPart(of: left, atOutput: output))
                frame.previousScreen = ScreenLayer(
                    trackID: previous.track, sourceTime: source, rect: rect, cornerRadius: cornerRadius,
                    crop: leftFilled.view.crop, mipmapped: style.screenSampling == .mipmapped)
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
        // What the zoom keeps to: the screen, or the window or the device around it.
        let screenRect = frame.windowFrame?.rect ?? frame.screen.map { deviceFrame.bounds(around: $0.rect) ?? $0.rect }
        let stage = stageTransform(zoomSpan?.state(atOutput: output) ?? paths.zoom.state(atOutput: output), screen: screenRect)
        frame.stage = stage.depth > 1 ? stage : nil
        if let zoomSpan {
            blur(&frame, at: output, zoom: (zoomSpan, zoomEnds), screen: screenRect, cursor: cursorPlace.flatMap { place in
                cursorSpan.map { (span: $0, ends: cursorEnds, place: place) }
            })
        } else if let cursorPlace, let cursorSpan {
            blur(&frame, at: output, zoom: nil, screen: screenRect, cursor: (cursorSpan, cursorEnds, cursorPlace))
        }
        guard (forcedPath ?? (layouts.isTrivial ? .legacy : .layouts)) == .layouts else {
            frame.camera = camera(at: source, output: output)
            finishLayers(&frame, source: source, output: output)
            return frame
        }
        let motion = Motion(
            zoomEnds: zoomEnds, zoomSpan: zoomSpan,
            cursor: cursorPlace.flatMap { place in cursorSpan.map { (span: $0, ends: cursorEnds, place: place) } })
        var laid = laidOut(frame, source: source, output: output, motion: motion)
        finishLayers(&laid, source: source, output: output)
        return laid
    }

    /// Puts phase 2's layers (phase 2 design §11) onto `frame`, a frame of the take at output time `output` showing source
    /// instant `source`, as either path left it, in this order: privacy on the screen and on the one being left; the
    /// camera's frame taken at its sync (`CameraSyncScene`), then its framing, colour and background, which may change the
    /// camera's shape and whether the frame is covered by it (`CameraLookScene`, over the whole frame); the device frame
    /// around the screen, which may change the screens' corners and the shadow (`DeviceFrameScene`, over the whole frame);
    /// the keys; the captions. With the legacy values each is `nil` or empty, and `frame` is as it was.
    private func finishLayers(_ frame: inout RenderFrame, source: HostTime, output: Int64) {
        if var screen = frame.screen {
            privacy.apply(to: &screen, atSource: source)
            frame.screen = screen
        }
        if var previous = frame.previousScreen {
            privacy.apply(to: &previous, atSource: source)
            frame.previousScreen = previous
        }
        if var camera = frame.camera {
            camera.sourceTime = cameraSync.cameraTime(atSource: camera.sourceTime)
            frame.camera = camera
        }
        cameraLook.apply(to: &frame, atSource: source, output: output)
        deviceFrame.apply(to: &frame)
        frame.keys = keys.layer(atOutput: output)
        frame.captions = captions.layer(atOutput: output)
        frame.captionsAhead = captions.layersAhead(atOutput: output)
    }

    /// What 1b's path read of the paths for the motion blur of a frame, which the card's reads again: the ends of the zoom
    /// camera's shutter (only `t` without one) and the camera over them; the cursor over its own shutter and how it is
    /// placed (`nil` while it is not drawn or does not blur).
    private struct Motion {
        var zoomEnds: [Int64]
        var zoomSpan: ZoomCameraPath.Span?
        var cursor: (span: CursorPath.Span, ends: [Int64], place: CursorPlace)?
    }

    /// `frame`, which 1b's path made for output time `output` showing source instant `source` (the screen's group where
    /// the Bubble layout has it, the zoom over the whole stage, no camera), laid out by the camera layouts (see the type's
    /// notes), with what that path read for its blur, `motion`.
    private func laidOut(_ frame: RenderFrame, source: HostTime, output: Int64, motion: Motion) -> RenderFrame {
        var frame = frame
        let size = SIMD2(Double(outputSize.x), Double(outputSize.y))
        let reference = document.camera.sizeReference
        // Where 1b's path placed the screen's group, unzoomed: the whole window or device with a frame.
        let placed = frame.windowFrame?.rect ?? frame.screen.map { deviceFrame.bounds(around: $0.rect) ?? $0.rect }
        let aspect = placed.flatMap { $0.width > 0 && $0.height > 0 ? $0.width / $0.height : nil }
        let geometry = layouts.geometry(atOutput: output, LayoutInputs(
            output: size, padding: document.style.padding, cornerRadius: document.style.cornerRadius, screenAspect: aspect,
            takeBubble: bubble?.frame(atOutput: output, host: source, output: size, reference: reference), sizeReference: reference))

        // From the stage to a card (1c design §5.4): the background goes to rest, and the zoom into the screen's card.
        let weight = layouts.cardWeight(atOutput: output)
        let stage = frame.stage ?? .identity(outputSize: outputSize)
        if weight > 0 {
            frame.backgroundTransform = .mix(stage, .identity(outputSize: outputSize), weight)
            frame.stage = nil
        }

        let card = geometry.screen
        frame.screenOpacity = card.opacity
        if card.opacity > 0, let placed, placed.width > 0 {
            let placing = Placing(from: placed, onto: card)
            place(&frame, placing)
            if let background = frame.backgroundTransform {
                inTheCard(
                    &frame, at: output, weight: weight, stage: stage, background: background, placed: placed, placing: placing,
                    motion: motion)
            }
        } else {
            // Nothing of the screen's group is seen.
            (frame.screen, frame.previousScreen, frame.windowFrame, frame.settledWindowFrame) = (nil, nil, nil, nil)
            (frame.shadow, frame.cursor, frame.clickEffects, frame.cursorSamples, frame.subframes) = (nil, nil, [], [], [])
        }

        // The camera in its card: before its first frame, that frame (1c design §5.1). The Bubble's card is hidden then.
        frame.camera = nil
        let camera = geometry.camera
        if camera.opacity > 0, let bubble {
            frame.camera = Self.cameraLayer(
                trackID: bubble.trackID, sourceTime: max(source, bubble.start),
                frame: CameraFrame(rect: camera.rect, cornerRadius: camera.cornerRadius), opacity: camera.opacity,
                borderWeight: camera.borderWeight, shadowWeight: camera.shadowWeight, look: document.camera, output: size)
        }
        if let layer = frame.camera, card.opacity <= 0, Self.covers(layer, output: size) {
            return RenderFrame(
                outputSize: frame.outputSize, gradientStart: frame.gradientStart, gradientEnd: frame.gradientEnd,
                gradientAngleDegrees: frame.gradientAngleDegrees, camera: layer, background: frame.background, screenOpacity: 0,
                coveredByCamera: true)
        }
        return frame
    }

    /// How the screen's group goes from where 1b's path placed it, `from`, onto the screen's card `to`, with its corners:
    /// moved, scaled by `scale`, the card's width over `from`'s (both of the group's aspect), and faded to the card's
    /// `opacity`.
    private struct Placing {
        let from: Rect
        let to: Rect
        let cornerRadius: Double
        let scale: Double
        let opacity: Double

        init(from placed: Rect, onto card: ScreenCard) {
            (from, to, cornerRadius) = (placed, card.rect, card.cornerRadius)
            (scale, opacity) = (card.rect.width / placed.width, card.opacity)
        }

        func point(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(to.x, to.y) + (p - SIMD2(from.x, from.y)) * scale }

        func rect(_ r: Rect) -> Rect {
            let origin = point(SIMD2(r.x, r.y))
            return Rect(x: origin.x, y: origin.y, width: r.width * scale, height: r.height * scale)
        }

        /// `layer` on the card, `scale` times as large, faded with the group.
        func cursor(_ layer: CursorLayer?) -> CursorLayer? {
            layer.map { layer in
                var placed = layer
                placed.hotspot = point(layer.hotspot)
                placed.height = layer.height * scale
                placed.opacity = layer.opacity * opacity
                return placed
            }
        }
    }

    /// Moves and scales the screen's group of `frame` as `placing` says, onto the card by `s`, `placing.scale`: the
    /// screens, the window frame (its bar `s` times as tall, its corners worked out from the card's, `windowCorners`), the
    /// shadow (cast by them, of the same blur), the cursors and the click effects (`s` times as large). All of it fades at
    /// the card's opacity `o` as one group: the screen at `o` times its own (below 1 while it fades in over the screen
    /// being left during a change of screen, `f`), the one being left at `o·(1 − f) / (1 − o·f)`, so the two together are
    /// the change at `o`.
    private func place(_ frame: inout RenderFrame, _ placing: Placing) {
        let scale = placing.scale, opacity = placing.opacity
        let rect = placing.rect, cursor = placing.cursor
        var corners = placing.cornerRadius
        if var window = frame.windowFrame {
            let recordedWindow = frame.screen.map { windowTrackIDs.contains($0.trackID) } ?? false
            window.rect = rect(window.rect)
            window.barHeight *= scale
            let (top, bottom) = Self.windowCorners(corners, barHeight: window.barHeight, recordedWindow: recordedWindow)
            (window.cornerRadius, window.bottomCornerRadius, window.screenTopCornerRadius) = (top, bottom, recordedWindow ? bottom : 0)
            frame.windowFrame = window
            corners = bottom
        }
        if var settled = frame.settledWindowFrame {
            settled.rect = rect(settled.rect)
            settled.barHeight *= scale
            frame.settledWindowFrame = settled
        }
        if var shadow = frame.shadow {
            shadow.rect = rect(shadow.rect)
            shadow.cornerRadius = corners
            frame.shadow = shadow
        }
        let fadingIn = frame.screen?.opacity ?? 1
        if var screen = frame.screen {
            screen.rect = rect(screen.rect)
            screen.cornerRadius = corners
            screen.opacity = opacity * fadingIn
            frame.screen = screen
        }
        if var previous = frame.previousScreen {
            let shown = opacity * fadingIn
            previous.rect = rect(previous.rect)
            previous.cornerRadius = corners
            previous.opacity = shown < 1 ? opacity * (1 - fadingIn) / (1 - shown) : 0
            frame.previousScreen = previous
        }
        frame.cursor = cursor(frame.cursor)
        frame.cursorSamples = frame.cursorSamples.compactMap(cursor)
        frame.subframes = frame.subframes.map { StageSubframe(stage: $0.stage, cursor: cursor($0.cursor)) }
        frame.clickEffects = frame.clickEffects.map { effect in
            var placed = effect
            placed.center = placing.point(effect.center)
            placed.radius = effect.radius * scale
            placed.thickness = effect.thickness * scale
            placed.opacity = effect.opacity * opacity
            return placed
        }
    }

    /// Puts the screen's group of `frame`, placed on its card by `placing`, inside the card (1c design §5.4 and §14.2),
    /// `weight` of the way from the stage (`LayoutTimeline.cardWeight`, above 0), with `background` the background's
    /// transform: `RenderFrame.card` and the card's motion blur. `stage` is the stage's zoom at `output`, of 1b's path,
    /// which placed the group at `placed`; `motion`, what that path read for its blur.
    private func inTheCard(
        _ frame: inout RenderFrame, at output: Int64, weight: Double, stage: StageTransform, background: StageTransform,
        placed: Rect, placing: Placing, motion: Motion
    ) {
        guard let screen = frame.screen else { return }
        let content = screen.rect
        let cardSpan = motion.zoomEnds.count > 1 ? paths.cardZoom?.span(from: motion.zoomEnds[0], through: motion.zoomEnds[1]) : nil
        /// The content's transform at output time `t`: the card's camera and the stage's mixed.
        func transform(_ t: Int64) -> StageTransform {
            let card = cardTransform(cardSpan?.state(atOutput: t) ?? paths.cardZoom?.state(atOutput: t), content: content)
            let zoom = t == output
                ? stage : stageTransform(motion.zoomSpan?.state(atOutput: t) ?? paths.zoom.state(atOutput: t), screen: placed)
            return .mix(zoom, card, weight)
        }
        let now = transform(output)
        frame.card = CardPlacement(
            rect: background.outputRect(ofStage: content, outputSize: outputSize), cornerRadius: screen.cornerRadius * background.depth,
            content: now, mix: weight)
        cardBlur(&frame, at: output, transform: transform, content: content, depth: now.depth, motion: motion, placing: placing)
    }

    /// The card's camera `state` (fractions of the screen's content, `CardZoomState`) as a transform of this output's stage,
    /// over the content placed at `content` (the screen's rect on the card): the content's point at `state.center` drawn
    /// at the rect's middle, `z` times as large. An identity at rest: no state (no split), a depth of 1 or less, or one
    /// that is not a number.
    private func cardTransform(_ state: CardZoomState?, content: Rect) -> StageTransform {
        guard let state, state.depth > 1, state.depth.isFinite else { return .identity(outputSize: outputSize) }
        let origin = SIMD2(content.x, content.y), extent = SIMD2(content.width, content.height)
        let focus = origin + state.center * extent, middle = origin + extent / 2
        return StageTransform(depth: state.depth, center: focus - (middle - SIMD2<Double>(outputSize) / 2) / state.depth)
    }

    /// Adds the motion blur of the frame at output time `output` in a card to `frame` (1c design §5.4): `blur`'s rules over
    /// the content's `transform` at each time, the zoom's samples from how far the corners of the screen's rect `content`
    /// go over the camera's shutter, the cursor's from how far it goes on the card (placed by `placing`) times `depth`,
    /// the content's depth at `output`. Its `subframes` (the content's transforms), or its `cursorSamples`, or nothing.
    private func cardBlur(
        _ frame: inout RenderFrame, at output: Int64, transform: (Int64) -> StageTransform, content: Rect, depth: Double,
        motion: Motion, placing: Placing
    ) {
        (frame.subframes, frame.cursorSamples) = ([], [])
        let corners = [
            SIMD2(content.x, content.y), SIMD2(content.x + content.width, content.y), SIMD2(content.x, content.y + content.height),
            SIMD2(content.x + content.width, content.y + content.height),
        ]
        var zoomSamples = 1
        if motion.zoomEnds.count > 1 {
            zoomSamples = MotionBlurPlan.sampleCount(travelPixels: Self.travel(
                of: corners, from: transform(motion.zoomEnds[0]), to: transform(motion.zoomEnds[1]), outputSize: outputSize))
        }
        let cursor = motion.cursor
        /// The cursor on the card at output time `t`.
        func placedCursor(atOutput t: Int64) -> CursorLayer? {
            cursor.flatMap { placing.cursor(cursorLayer($0.span.sample(atOutput: t), $0.place)) }
        }
        var cursorSamples = 1
        if let cursor, let a = placedCursor(atOutput: cursor.ends[0]), let b = placedCursor(atOutput: cursor.ends[1]) {
            cursorSamples = MotionBlurPlan.sampleCount(travelPixels: simd_length(b.hotspot - a.hotspot) * depth)
        }
        if zoomSamples > 1 {
            let count = max(zoomSamples, cursorSamples)
            // The card's camera jumps where the stage's does: the same blocks.
            let stageTimes = sampleTimes(zoomShutter, count: count, at: output, jumps: paths.zoom.jumps)
            let cursorTimes = cursorSamples > 1 ? sampleTimes(cursorShutter, count: count, at: output, jumps: paths.cursor.jumps) : nil
            frame.subframes = stageTimes.indices.map { j in
                StageSubframe(stage: transform(stageTimes[j]), cursor: cursorTimes.map { placedCursor(atOutput: $0[j]) } ?? frame.cursor)
            }
        } else if cursorSamples > 1 {
            let layers = sampleTimes(cursorShutter, count: cursorSamples, at: output, jumps: paths.cursor.jumps).map {
                placedCursor(atOutput: $0)
            }
            guard var hidden = layers.lazy.compactMap({ $0 }).first else { return }
            hidden.opacity = 0
            frame.cursorSamples = layers.map { $0 ?? hidden }
        }
    }

    /// Whether `camera` covers every pixel of an output `output` big, opaque: at full opacity (only then is it opaque;
    /// below, what is under it shows, however little), with square corners, over all of it.
    private static func covers(_ camera: CameraLayer, output: SIMD2<Double>) -> Bool {
        let rect = camera.rect
        return camera.opacity >= 1 && camera.cornerRadius <= 0 && rect.x <= 0 && rect.y <= 0 && rect.x + rect.width >= output.x
            && rect.y + rect.height >= output.y
    }

    /// The output times of the ends of a shutter of `shutter` frames about `output`, held to the side of `output` of the
    /// path's `jumps` and to the output; only `output` without a shutter.
    private func shutterEnds(_ shutter: Double, at output: Int64, jumps: [ClosedRange<Int64>]) -> [Int64] {
        sampleTimes(shutter, count: 2, at: output, jumps: jumps)
    }

    /// `MotionBlurPlan.sampleTimes` of `count` subsamples of the frame at `output`, held to the side of `output` of the
    /// path's `jumps` and to the output.
    private func sampleTimes(_ shutter: Double, count: Int, at output: Int64, jumps: [ClosedRange<Int64>]) -> [Int64] {
        MotionBlurPlan.sampleTimes(at: output, shutter: shutter, frameDuration: frameDuration, count: count, jumps: jumps)
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
            let stageTimes = sampleTimes(zoomShutter, count: count, at: output, jumps: paths.zoom.jumps)
            let cursorTimes = cursorSamples > 1 ? sampleTimes(cursorShutter, count: count, at: output, jumps: paths.cursor.jumps) : nil
            frame.subframes = stageTimes.indices.map { j in
                let stage = stageTransform(zoom.span.state(atOutput: stageTimes[j]), screen: screen)
                guard let cursor, let cursorTimes else { return StageSubframe(stage: stage, cursor: frame.cursor) }
                return StageSubframe(stage: stage, cursor: cursorLayer(cursor.span.sample(atOutput: cursorTimes[j]), cursor.place))
            }
        } else if let cursor, cursorSamples > 1 {
            let layers = sampleTimes(cursorShutter, count: cursorSamples, at: output, jumps: paths.cursor.jumps).map {
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
        return travel(of: [SIMD2(0, 0), SIMD2(size.x, 0), SIMD2(0, size.y), size], from: a, to: b, outputSize: outputSize)
    }

    /// How far, in output pixels, the one of stage points `points` that moves most goes from `a` to `b`.
    private static func travel(
        of points: [SIMD2<Double>], from a: StageTransform, to b: StageTransform, outputSize: SIMD2<Int>
    ) -> Double {
        points.map { point in
            simd_length(b.outputPoint(ofStage: point, outputSize: outputSize) - a.outputPoint(ofStage: point, outputSize: outputSize))
        }.max() ?? 0
    }

    /// Where the screen of `view` goes, settled, in an output of `outputSize` with `style` (design §7.3): the rect of its
    /// region's aspect inside the padding (`StageLayout.screenRect`); with a macOS window frame, under the bar of the window
    /// around it (`StageLayout.windowRect`); with a device frame around the screen fitted whole, inside the device whose
    /// bounds fit there (`DeviceFrameGeometry.placement`, phase 2 design §6.7). Following the cursor (`style.reframe`
    /// `followCursor`, §6.5) there is never a frame: a view `stage` reframes (`StagePoints.isReframed(_:)`) fills the whole
    /// room inside the padding (`StagePoints.room`), any other is placed whole, as without a frame.
    private static func placement(
        of view: ShownScreen, style: StageStyle, outputSize: SIMD2<Double>, stage: StagePoints
    ) -> ScreenPlacement {
        let aspect = view.region.map { $0.width / $0.height }
        if style.reframe == .followCursor {
            let rect = StageLayout.screenRect(
                contentAspect: stage.isReframed(view) ? nil : aspect, padding: style.padding, outputSize: outputSize)
            return ScreenPlacement(screen: rect, window: rect, barHeight: 0)
        }
        if case let .device(device) = style.frame, style.reframe == .fit {
            return DeviceFrameGeometry.placement(contentAspect: aspect, padding: style.padding, outputSize: outputSize, frame: device)
        }
        switch style.frame {
        // A device is drawn only around the screen fitted whole (above).
        case .none, .device:
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
    ///
    /// A reframed view (`window`, the window of its region it shows, `reframedPart(of:atOutput:)`) shows that window
    /// where it goes (the room); on its way there, the part of the rect's shape about the window's centre, moved to stay
    /// inside the region, so it is the window when it gets there (2c's `layerCrop` is the crop cut, its `contentCrop`
    /// the view's: plan 2b decision 17).
    private static func fill(
        _ view: ShownScreen, settled: ScreenPlacement, into placement: ScreenPlacement, window: Rect?
    ) -> (view: ShownScreen, part: Rect?) {
        guard let region = view.region else { return (view, nil) }
        var part: Rect
        if settled == placement {
            guard let window else { return (view, nil) }
            part = window
        } else {
            part = GeometryTransitions.aspectFill(aspect: region.width / region.height, in: placement.screen)
            if let window, part.width < 1 {
                let center = window.x + window.width / 2
                part.x = min(max(center - part.width / 2, 0), 1 - part.width)
            }
        }
        func cut(_ rect: Rect) -> Rect {
            Rect(
                x: rect.x + part.x * rect.width, y: rect.y + part.y * rect.height, width: part.width * rect.width,
                height: part.height * rect.height)
        }
        return (ShownScreen(crop: cut(view.crop), region: cut(region), onScreen: view.onScreen), part)
    }

    /// The window of `view`'s region a screen that follows the cursor shows at output time `output` (`ReframePath.part`,
    /// `reframe-1`), in fractions of the region; `nil` when `view` is not reframed (`StagePoints.isReframed(_:)`), and with
    /// the screen fitted whole (`paths.reframe` is `nil`).
    private func reframedPart(of view: ShownScreen, atOutput output: Int64) -> Rect? {
        paths.reframe?.part(of: view, atOutput: output, stage: paths.stage)
    }

    /// The largest corners of a window frame, in heights of its bar. Corners of about 1.37 bars touch the first button's
    /// rim; at 1.3 the rim is 0.03 bars inside them.
    static let windowCornerBars = 1.3

    /// The corners of a window frame whose bar is `barHeight` tall, around a screen with corners of `corners`: its top
    /// ones never more than `windowCornerBars` bars, so they never cut its first button; its bottom ones (and its screen's
    /// top ones under the bar) `corners` around a window the take recorded, its top ones otherwise.
    static func windowCorners(_ corners: Double, barHeight: Double, recordedWindow: Bool) -> (top: Double, bottom: Double) {
        let top = min(corners, windowCornerBars * barHeight)
        return (top, recordedWindow ? corners : top)
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

    /// The camera at source instant `source` and output time `output`, from the start of its first segment on: its
    /// bubble measured against the document's `camera.sizeReference`, with the document's look.
    private func camera(at source: HostTime, output: Int64) -> CameraLayer? {
        let size = SIMD2(Double(outputSize.x), Double(outputSize.y))
        guard let bubble, let frame = bubble.frame(atOutput: output, host: source, output: size, reference: document.camera.sizeReference)
        else { return nil }
        return Self.cameraLayer(trackID: bubble.trackID, sourceTime: source, frame: frame, look: document.camera, output: size)
    }

    /// The camera drawn in `frame` with the look of `camera` (1c design §14.3) in an output `output` big, `s` its shorter
    /// side: its picture flipped with `mirror`; a border `border.width × weight × CameraBorder.widthFactor × s` wide, only
    /// above 0; and, with `k = shadow × weight`, a shadow cast by the camera with its corners, at opacity `0.55·k`, of σ
    /// `(0.004 + 0.016·k)·s` and `0.010·k·s` down, only for `k` above 0. `opacity` and the weights (a layout's: 1 in the
    /// Bubble) and the document's border width and shadow are read from 0 to 1, 0 if not a number: a layout's spring
    /// overshoots by about 10⁻⁴. With the legacy look (not mirrored, no border, no shadow) at opacity 1, 1b's layer.
    static func cameraLayer(
        trackID: String, sourceTime: HostTime, frame: CameraFrame, opacity: Double = 1, borderWeight: Double = 1,
        shadowWeight: Double = 1, look camera: CameraPlan, output: SIMD2<Double>
    ) -> CameraLayer {
        func unit(_ value: Double) -> Double { value.isNaN ? 0 : min(max(value, 0), 1) }
        let short = min(output.x, output.y)
        var layer = CameraLayer(
            trackID: trackID, sourceTime: sourceTime, rect: frame.rect, cornerRadius: frame.cornerRadius, mirror: camera.mirror,
            opacity: unit(opacity))
        let width = unit(camera.border.width) * unit(borderWeight) * CameraBorder.widthFactor * short
        if width > 0 {
            let color = camera.border.color
            layer.border = CameraBorderLayer(
                width: width, color: SIMD4(Float(unit(color.r)), Float(unit(color.g)), Float(unit(color.b)), Float(unit(color.a))))
        }
        let k = unit(camera.shadow) * unit(shadowWeight)
        if k > 0 {
            layer.shadow = ShadowLayer(
                rect: frame.rect, cornerRadius: frame.cornerRadius, opacity: 0.55 * k, sigma: (0.004 + 0.016 * k) * short,
                offsetY: 0.010 * k * short)
        }
        return layer
    }
}
