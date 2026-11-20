// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// An annotation as a frame draws it (phase 3 design §5.1 and §12, `annotation-1`): stuck to the recording (step 5, in the
/// stage, under the camera) or of the output (step 7, over the camera and under the keys), with everything about its place
/// and its look worked out (`AnnotationScene`, plan 3a decisions 2 to 9): a text's box measured, an arrow's path and a
/// speech bubble's tail placed, a step's number set, a clip's time in its file.
///
/// Its place is in the coordinates of its group: one stuck to the recording in the stage's (as `ScreenLayer.rect`, before
/// the zoom, the card or the motion blur, which move the whole stage), one of the output in the output's pixels.
public struct AnnotationLayer: Equatable, Sendable {
    /// What is drawn, with what the scene worked out for it.
    public enum Content: Equatable, Sendable {
        /// A text, its box measured (`rect`, `AnnotationTypography`).
        case text(TextAnnotation)
        /// An arrow and its path in the coordinates of its group (`AnnotationGeometry.arrow(_:in:)`).
        case arrow(ArrowAnnotation, path: AnnotationGeometry.ArrowPath)
        case shape(ShapeAnnotation)
        /// A speech bubble, its box measured (`rect`) and its tail (`AnnotationGeometry.calloutTail`), `nil` with its point
        /// inside it.
        case callout(CalloutAnnotation, tail: AnnotationGeometry.CalloutTail?)
        /// A step and its number (`StepNumbering`).
        case step(StepAnnotation, number: Int)
        case image(ImageAnnotation)
        /// A clip and the time of its file shown, ns (plan 3a decision 13).
        case clip(ClipAnnotation, fileTime: Int64)
    }

    /// The annotation's `id`.
    public var id: String
    public var content: Content
    /// Its box: the annotation's rect, held where its anchor lets it be (`AnnotationGeometry.clamped`), in its space. A
    /// text's and a speech bubble's are as tall as their text measured (`AnnotationTypography.box`), an arrow's the box
    /// around its ends and its bend (`AnnotationGeometry.arrowRect`).
    public var rect: Rect
    /// Its space: stuck to the recording, where the whole content of the screen shown is drawn
    /// (`AnnotationGeometry.contentSpace`); of the output, the output frame.
    public var space: Rect
    /// The height of `space`: what the sizes of its text, its strokes and its corners are fractions of.
    public var unit: Double
    /// Degrees, clockwise, about the centre of `rect`; 0 for an arrow and a speech bubble, which their points place (plan
    /// 3a decision 6).
    public var rotation: Double
    /// 0 to 1: its own opacity times its entrance and its exit (`AnnotationTiming.state`).
    public var opacity: Double
    /// 1, but while it pops in (0.9 to 1), about the centre of `rect`.
    public var scale: Double
    /// 0 to 1: the fraction of an arrow's or a shape's stroke drawn; 1 for everything else and once it is in.
    public var drawn: Double

    public init(
        id: String, content: Content, rect: Rect, space: Rect, unit: Double, rotation: Double, opacity: Double, scale: Double,
        drawn: Double
    ) {
        self.id = id
        self.content = content
        self.rect = rect
        self.space = space
        self.unit = unit
        self.rotation = rotation
        self.opacity = opacity
        self.scale = scale
        self.drawn = drawn
    }
}

/// The annotations of a document (`EditDocument.annotations`) as the frames of its take `take` draw them, with the take's
/// `events` (what the screen shown holds, as `PrivacyScene` reads it), worked out once for the scene and again for each
/// size (`FrameEvaluator.init` and `resized(to:)`), `annotation-1` (phase 3 plan 3a, decisions 2, 3, 7, 9 and 13).
///
/// - Two groups: those stuck to the take's recording (anchored to `take`), and those of the output and of the whole video
///   (of any take's scene). Each in its layers' order: by `layer`, then by the order of `document.annotations.items`.
/// - When: `AnnotationTiming.state` at the output time, so one stuck to the recording only where the output shows its
///   source range of the take (never in a cut, another take's clip, a title card or an imported clip; in a frozen frame of
///   that range, as at the frame's point), with its entrance and its exit. A clip is shown in its anchor cut to the length
///   of its file (`end − start`), and its file's time is `start + (τ −` where its anchor so cut starts`)`; anchored to the
///   take, it is never shown.
/// - Where: stuck to the recording, in the space where the whole content of the frame's screen would be drawn
///   (`AnnotationGeometry.contentSpace`: what the screen shows at that instant, `ScreenGeometry.shown(at:)`, the Area in
///   Area mode, carried through the crop the layer draws onto its rect), so it stays on the same pixel of the content with
///   another padding, format, frame, reframe, change of shape, card or zoom; none without a screen in the frame (the camera
///   over all of it, a screen hidden by its layout, a take without one). Of the output, in the output frame. The unit is
///   the space's height.
/// - Steps are numbered once, for the whole output (`StepNumbering`); one without a number is not shown.
///
/// A document without annotations measures nothing, and both groups are empty everywhere.
struct AnnotationScene: Sendable {
    /// An annotation the scene shows: as the document has it, as its timing reads it (a clip's anchor cut to its file),
    /// the output range it can be seen in, and its step's number.
    private struct Item: Sendable {
        var annotation: Annotation
        var timed: Annotation
        var range: Range<Int64>
        var number: Int?
        /// Of the output's group: what does not depend on the output time, worked out once for the size.
        var placed: Placed?
    }

    /// What a layer is besides its time: its content, its box, its space and its rotation.
    private struct Placed: Sendable {
        var content: AnnotationLayer.Content
        var rect: Rect
        var space: Rect
        var rotation: Double
    }

    private let document: EditDocument
    private let timeMap: TimeMap
    /// The take's annotations stuck to its recording, in their layers' order.
    private let contentItems: [Item]
    /// The annotations of the output and of the whole video, in their layers' order.
    private let outputItems: [Item]
    /// Where each of the take's screens is, by track ID: what its content is (`ShownScreen.crop`). Empty without
    /// annotations stuck to the take.
    private let screens: [String: ScreenGeometry]

    init(document: EditDocument, take: TakeRecord, events: [InputEvent], timeMap: TimeMap, outputSize: SIMD2<Int>) {
        self.document = document
        self.timeMap = timeMap
        guard !document.annotations.items.isEmpty else {
            (contentItems, outputItems, screens) = ([], [], [:])
            return
        }
        let numbers = StepNumbering.numbers(in: document, timeMap: timeMap)
        let outputSpace = AnnotationGeometry.outputSpace(outputSize: SIMD2(Double(outputSize.x), Double(outputSize.y)))
        var content: [(item: Item, order: Int)] = []
        var output: [(item: Item, order: Int)] = []
        for (order, annotation) in document.annotations.items.enumerated() {
            var timed = annotation
            if case let .clip(clip) = annotation.kind {
                guard let anchor = Self.cut(annotation.anchor, toFile: clip, duration: timeMap.duration) else { continue }
                timed.anchor = anchor
            }
            if case let .content(anchorTake, _, _) = annotation.anchor, anchorTake != take.id { continue }
            guard let range = AnnotationTiming.outputRange(of: timed, document: document, timeMap: timeMap), !range.isEmpty
            else { continue }
            var number: Int?
            if case .step = annotation.kind {
                guard let step = numbers[annotation.id] else { continue }
                number = step
            }
            var item = Item(annotation: annotation, timed: timed, range: range, number: number)
            if case .content = annotation.anchor {
                content.append((item, order))
            } else {
                item.placed = Self.placed(annotation, number: number, fileTime: 0, space: outputSpace)
                guard item.placed != nil else { continue }
                output.append((item, order))
            }
        }
        func ordered(_ items: [(item: Item, order: Int)]) -> [Item] {
            items.sorted { ($0.item.annotation.layer, $0.order) < ($1.item.annotation.layer, $1.order) }.map(\.item)
        }
        contentItems = ordered(content)
        outputItems = ordered(output)
        guard !contentItems.isEmpty else {
            screens = [:]
            return
        }
        let sorted = events.sortedByTime()
        screens = Dictionary(
            take.tracks.filter(\.kind.isScreen).map { ($0.id, ScreenGeometry(track: $0, events: sorted)) },
            uniquingKeysWith: { first, _ in first })
    }

    /// The annotations stuck to the recording that `frame` shows, a frame of the take at output time `output` showing source
    /// instant `t` as either path left it (`finishLayers`), in their layers' order, on the frame's screen (`frame.screen`,
    /// what it shows at `t`): none without a screen, or with the camera over the whole frame.
    func content(atSource t: HostTime, output: Int64, frame: RenderFrame) -> [AnnotationLayer] {
        guard !contentItems.isEmpty, !frame.coveredByCamera, let screen = frame.screen, let geometry = screens[screen.trackID]
        else { return [] }
        let shown = geometry.shown(at: t)?.crop ?? screen.crop
        guard let space = AnnotationGeometry.contentSpace(contentCrop: shown, layerCrop: screen.crop, drawnRect: screen.rect)
        else { return [] }
        return contentItems.compactMap { item in
            guard item.range.contains(output),
                let state = AnnotationTiming.state(of: item.timed, atOutput: output, document: document, timeMap: timeMap),
                let placed = Self.placed(item.annotation, number: item.number, fileTime: 0, space: space)
            else { return nil }
            return Self.layer(item.annotation, placed, state)
        }
    }

    /// The annotations of the output and of the whole video shown at output time `output`, in their layers' order, over
    /// whatever the clip there shows.
    func output(atOutput output: Int64) -> [AnnotationLayer] {
        guard !outputItems.isEmpty else { return [] }
        return outputItems.compactMap { item in
            guard item.range.contains(output), var placed = item.placed,
                let state = AnnotationTiming.state(of: item.timed, atOutput: output, document: document, timeMap: timeMap)
            else { return nil }
            if case let .clip(clip, _) = placed.content {
                // Within the range, which is never longer than the file's stretch: from its start to before its end.
                placed.content = .clip(clip, fileTime: clip.start + (output - item.range.lowerBound))
            }
            return Self.layer(item.annotation, placed, state)
        }
    }

    // MARK: - Private

    /// `annotation`'s layer, `placed`, at `state`.
    private static func layer(_ annotation: Annotation, _ placed: Placed, _ state: AnnotationState) -> AnnotationLayer {
        AnnotationLayer(
            id: annotation.id, content: placed.content, rect: placed.rect, space: placed.space, unit: placed.space.height,
            rotation: placed.rotation, opacity: state.opacity, scale: state.scale, drawn: state.drawn)
    }

    /// Where `annotation` is in `space` and what it draws there (a step with its `number`, a clip at `fileTime`): its rect
    /// held where its anchor lets it be, a text's and a speech bubble's as tall as their text, an arrow's around its path.
    /// `nil` for a step without a number.
    private static func placed(_ annotation: Annotation, number: Int?, fileTime: Int64, space: Rect) -> Placed? {
        let unit = space.height
        var rect = AnnotationGeometry.pixels(AnnotationGeometry.clamped(annotation.rect, anchor: annotation.anchor), in: space)
        var rotation = annotation.rotation.isFinite ? annotation.rotation : 0
        let content: AnnotationLayer.Content
        switch annotation.kind {
        case let .text(text):
            rect.height = AnnotationTypography.box(of: text, width: rect.width, unit: unit).y
            content = .text(text)
        case let .arrow(arrow):
            let aspect = space.height > 0 ? space.width / space.height : 1
            rect = AnnotationGeometry.pixels(AnnotationGeometry.arrowRect(arrow, aspect: aspect), in: space)
            content = .arrow(arrow, path: AnnotationGeometry.arrow(arrow, in: space))
            rotation = 0
        case let .shape(shape):
            content = .shape(shape)
        case let .callout(callout):
            rect.height = AnnotationTypography.box(of: callout.text, width: rect.width, unit: unit, padding: .label).y
            let em = callout.text.size * unit
            let corner = max(min(AnnotationTypography.calloutCornerEm * em, rect.width / 2, rect.height / 2), 0)
            let tail = AnnotationGeometry.calloutTail(
                bubble: rect, cornerRadius: corner.isFinite ? corner : 0, target: AnnotationGeometry.point(callout.target, in: space),
                em: em.isFinite ? em : 0)
            content = .callout(callout, tail: tail)
            rotation = 0
        case let .step(step):
            guard let number else { return nil }
            content = .step(step, number: number)
        case let .image(image):
            content = .image(image)
        case let .clip(clip):
            content = .clip(clip, fileTime: fileTime)
        }
        return Placed(content: content, rect: rect, space: space, rotation: rotation)
    }

    /// The anchor a clip over the output is shown in (plan 3a decision 13): `anchor` cut to the length of its file's
    /// stretch, `end − start`, from where it starts, so it never repeats; `nil` for a stretch of nothing, and anchored to
    /// the take (a clip is only of the output). The whole video is `[0, D)`.
    private static func cut(_ anchor: AnnotationAnchor, toFile clip: ClipAnnotation, duration: Int64) -> AnnotationAnchor? {
        let (length, overflow) = clip.end.subtractingReportingOverflow(clip.start)
        guard !overflow, length > 0 else { return nil }
        switch anchor {
        case .content:
            return nil
        case let .output(start, end):
            let (last, past) = start.addingReportingOverflow(length)
            return .output(start: start, end: past ? end : min(end, last))
        case .whole:
            return .output(start: 0, end: min(duration, length))
        }
    }
}
