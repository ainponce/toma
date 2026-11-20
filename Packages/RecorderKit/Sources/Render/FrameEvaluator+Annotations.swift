// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat
import Synchronization

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
    /// text's and a speech bubble's are as tall as their text measured (`AnnotationTypography.box`), and held with that
    /// height; of the output, as wide as their rect's width times the output frame's own proportion (see
    /// `AnnotationScene`). An arrow's is the box around its ends and its bend (`AnnotationGeometry.arrowRect`).
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
/// size (`FrameEvaluator.init` and `resized(to:)`), `annotation-1` (phase 3 plan 3a, decisions 2, 3, 5, 7, 9 and 13).
///
/// - Two groups: those stuck to the take's recording (anchored to `take`), and those of the output and of the whole video
///   (of any take's scene). Each in its layers' order: by `layer`, then by the order of `document.annotations.items`.
/// - When: `AnnotationTiming.state` at the output time, so one stuck to the recording only where the output shows its
///   source range of the take (never in a cut, another take's clip, a title card or an imported clip; in a frozen frame
///   whose point is in that range, also one at an edge of its output range, as at the frame's point), with its entrance
///   and its exit. A clip is shown in its range (`AnnotationTiming.outputRange`, its anchor cut to its file), and its
///   file's time at output time `τ` is `start + (τ − c)`, with `c` where that range starts.
/// - Where: stuck to the recording, in the space where the whole content of the frame's screen would be drawn
///   (`AnnotationGeometry.contentSpace`: what the screen shows at that instant, `ScreenGeometry.shown(at:)`, the Area in
///   Area mode, carried through the crop the layer draws onto its rect), so it stays on the same pixel of the content with
///   another padding, format, frame, reframe, change of shape, card or zoom; none without a screen in the frame (the camera
///   over all of it, a screen hidden by its layout, a take without one). Of the output, in the output frame. The unit is
///   the space's height.
/// - A text's and a speech bubble's box is as tall as its text measured (`AnnotationTypography`), and is then held where
///   its anchor lets it be with that height. Of the output, it is as wide as its rect's width times the output's own
///   proportion (`outputAspect`) times the frame's height, not times its width: every size of the output rounds its sides
///   to whole even pixels, and a proportion 0.06 % off would wrap a word at the limit on another line in the preview than
///   at 4K. Stuck to the recording, the content's proportion is not rounded. Each one's lines and line height are kept
///   while its frames ask for the same (`TextMeasure`): a still stage measures nothing after its first frame.
/// - Steps are numbered once, for the whole output (`StepNumbering`); one without a number is not shown.
///
/// A document without annotations measures nothing, and both groups are empty everywhere.
struct AnnotationScene: Sendable {
    /// An annotation the scene shows: as the document has it, the output range it can be seen in
    /// (`AnnotationTiming.outputRange`), its step's number and what its text measured.
    private struct Item: Sendable {
        var annotation: Annotation
        var range: Range<Int64>
        var number: Int?
        var measure: TextMeasure
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
        let size = SIMD2(Double(outputSize.x), Double(outputSize.y))
        let outputSpace = AnnotationGeometry.outputSpace(outputSize: size)
        var aspect: Double?
        var content: [(item: Item, order: Int)] = []
        var output: [(item: Item, order: Int)] = []
        for (order, annotation) in document.annotations.items.enumerated() {
            if case let .content(anchorTake, _, _) = annotation.anchor, anchorTake != take.id { continue }
            // One of the take with an empty range can still be on a frozen frame of its source range.
            guard let range = AnnotationTiming.outputRange(of: annotation, document: document, timeMap: timeMap),
                !range.isEmpty || annotation.anchor.isContent
            else { continue }
            var number: Int?
            if case .step = annotation.kind {
                guard let step = numbers[annotation.id] else { continue }
                number = step
            }
            var item = Item(annotation: annotation, range: range, number: number, measure: TextMeasure())
            if case .content = annotation.anchor {
                content.append((item, order))
            } else {
                let proportion = aspect ?? Self.outputAspect(document: document, take: take, events: events, outputSize: size)
                aspect = proportion
                item.placed = Self.placed(item, space: outputSpace, aspect: proportion, fileTime: 0)
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
        // A frozen frame of the take can show one at an edge of its range, or past it (`AnnotationTiming.state`).
        let frozen = timeMap.contentOffset(atOutput: output) != nil
        return contentItems.compactMap { item in
            guard frozen || item.range.contains(output),
                let state = AnnotationTiming.state(of: item.annotation, atOutput: output, document: document, timeMap: timeMap),
                let placed = Self.placed(item, space: space, aspect: nil, fileTime: 0)
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
                let state = AnnotationTiming.state(of: item.annotation, atOutput: output, document: document, timeMap: timeMap)
            else { return nil }
            if case let .clip(clip, _) = placed.content {
                // Within the range, which is never longer than the file's stretch: from its start to before its end.
                placed.content = .clip(clip, fileTime: clip.start + (output - item.range.lowerBound))
            }
            return Self.layer(item.annotation, placed, state)
        }
    }

    /// How many times the texts' lines and line heights were measured, for tests and the measures.
    var measureCount: Int {
        (contentItems + outputItems).reduce(0) { $0 + $1.measure.count }
    }

    /// The proportion of the output frame the boxes of the output's texts are measured with: the one the document names
    /// (its aspect; the recording's for `.auto`, `StageLayout.contentRatio`, as the export sizes it), which each size of the
    /// output rounds to whole even pixels; `outputSize`'s own when it is not within 1 % of that (a frame drawn at a size
    /// of another proportion).
    static func outputAspect(document: EditDocument, take: TakeRecord, events: [InputEvent], outputSize: SIMD2<Double>) -> Double {
        let actual = outputSize.y > 0 ? outputSize.x / outputSize.y : 1
        let ratio = document.aspect == .auto ? StageLayout.contentRatio(take: take, document: document, events: events) : nil
        let named = document.aspect.ratio(contentRatio: ratio)
        return named.isFinite && named > 0 && abs(named / actual - 1) < 0.01 ? named : actual
    }

    // MARK: - Private

    /// `annotation`'s layer, `placed`, at `state`.
    private static func layer(_ annotation: Annotation, _ placed: Placed, _ state: AnnotationState) -> AnnotationLayer {
        AnnotationLayer(
            id: annotation.id, content: placed.content, rect: placed.rect, space: placed.space, unit: placed.space.height,
            rotation: placed.rotation, opacity: state.opacity, scale: state.scale, drawn: state.drawn)
    }

    /// Where `item`'s annotation is in `space` and what it draws there (a step with its number, a clip at `fileTime`): its
    /// rect held where its anchor lets it be; a text's and a speech bubble's as tall as their text, measured with `aspect`
    /// as the space's proportion when it is given (the output's, `outputAspect`), then held with that height; an arrow's
    /// around its path. `nil` for a step without a number.
    private static func placed(_ item: Item, space: Rect, aspect: Double?, fileTime: Int64) -> Placed? {
        let annotation = item.annotation
        let unit = space.height
        let held = AnnotationGeometry.clamped(annotation.rect, anchor: annotation.anchor)
        var rect = AnnotationGeometry.pixels(held, in: space)
        var rotation = annotation.rotation.isFinite ? annotation.rotation : 0
        /// The box of `text` with the padding of `padding`: as wide as the rect (in the frame's height times `aspect`),
        /// as tall as its text, held there with that height.
        func box(_ text: TextAnnotation, padding: TextPreset?) -> Rect {
            let width = aspect.map { held.width * $0 * unit } ?? rect.width
            let height = item.measure.height(of: text, width: width, unit: unit, padding: padding)
            var box = rect
            if unit > 0, height.isFinite {
                var measured = held
                measured.height = height / unit
                box = AnnotationGeometry.pixels(AnnotationGeometry.clamped(measured, anchor: annotation.anchor), in: space)
            }
            (box.width, box.height) = (width, height)
            return box
        }
        let content: AnnotationLayer.Content
        switch annotation.kind {
        case let .text(text):
            rect = box(text, padding: nil)
            content = .text(text)
        case let .arrow(arrow):
            let proportion = space.height > 0 ? space.width / space.height : 1
            rect = AnnotationGeometry.pixels(AnnotationGeometry.arrowRect(arrow, aspect: proportion), in: space)
            content = .arrow(arrow, path: AnnotationGeometry.arrow(arrow, in: space))
            rotation = 0
        case let .shape(shape):
            content = .shape(shape)
        case let .callout(callout):
            rect = box(callout.text, padding: .label)
            let em = callout.text.size * unit
            let corner = max(min(AnnotationTypography.calloutCornerEm * em, rect.width / 2, rect.height / 2), 0)
            let tail = AnnotationGeometry.calloutTail(
                bubble: rect, cornerRadius: corner.isFinite ? corner : 0, target: AnnotationGeometry.point(callout.target, in: space),
                em: em.isFinite ? em : 0)
            content = .callout(callout, tail: tail)
            rotation = 0
        case let .step(step):
            guard let number = item.number else { return nil }
            content = .step(step, number: number)
        case let .image(image):
            content = .image(image)
        case let .clip(clip):
            content = .clip(clip, fileTime: fileTime)
        }
        return Placed(content: content, rect: rect, space: space, rotation: rotation)
    }
}

/// What a text of one annotation measured (`AnnotationTypography`), kept while the frames ask for the same, under a lock
/// held only to read and keep it (the measuring is outside it):
/// its lines' count for the last width they were wrapped at (in pixels of `AnnotationTypography.referenceUnit`, which only
/// the space's proportion changes), and the height of a line for the last em. So a text whose stage does not change
/// measures once, and one whose screen's card grows measures again only while it grows. The same numbers as
/// `AnnotationTypography.box`, so the same box.
final class TextMeasure: Sendable {
    private struct State {
        var lines: (width: Double?, count: Int?)?
        var line: (em: Double, height: Double?)?
        var count = 0
    }

    private let state = Mutex(State())

    init() {}

    /// How many times it measured: lines or a line's height.
    var count: Int { state.withLock { $0.count } }

    /// The height of `text`'s box `width` pixels wide with the padding of `paddingPreset` (its own preset's when `nil`),
    /// with `unit` the height of its space: `AnnotationTypography.box(of:width:unit:padding:).y`.
    func height(of text: TextAnnotation, width: Double, unit: Double, padding paddingPreset: TextPreset?) -> Double {
        let em = text.size * unit
        let padding = AnnotationTypography.padding(paddingPreset ?? text.preset, em: em)
        let wrap = AnnotationTypography.referenceWidth(of: text, width: width, unit: unit, padding: paddingPreset)
        // What is kept, read under the lock; what is not is measured outside it (CoreText, the font's design) and kept
        // after. Two frames that miss at once both measure, the same numbers.
        let (keptLines, keptLine) = state.withLock { state in
            (state.lines.flatMap { $0.width == wrap ? .some($0.count) : nil }, state.line.flatMap { $0.em == em ? .some($0.height) : nil })
        }
        let count = keptLines ?? AnnotationTypography.lines(of: text, width: width, unit: unit, padding: paddingPreset)?.count
        let lineHeight = keptLine ?? AnnotationTypography.font(text, unit: unit, scale: 1).map(AnnotationTypography.lineHeight(of:))
        if keptLines == nil || keptLine == nil {
            state.withLock { state in
                if keptLines == nil {
                    state.lines = (wrap, count)
                    state.count += 1
                }
                if keptLine == nil {
                    state.line = (em, lineHeight)
                    state.count += 1
                }
            }
        }
        guard let count, let lineHeight else { return 2 * padding.y }
        return Double(count) * lineHeight + 2 * padding.y
    }
}

extension AnnotationAnchor {
    /// Stuck to a take's recording.
    fileprivate var isContent: Bool {
        if case .content = self { return true }
        return false
    }
}
