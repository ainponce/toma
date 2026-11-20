// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat
import Render

/// What the files for external editors say of a whole export (plan 4c, decision 10), in the video's frames and pixels:
/// the FCPXML (`FCPXMLWriter`) and `metadata-1` (`EditorMetadataFile`) are both written from it, so they never disagree.
///
/// Times are output nanoseconds; frame `n` of an output instant `τ` is `round(τ · fps / 10⁹)`, the frame the video shows
/// it in. What falls on a frame past the video's last (`n ≥ frameCount`) is left out.
struct EditorTimeline: Equatable, Sendable {
    /// A marker the output shows (`MarkerList.visible`).
    struct Marker: Equatable, Sendable {
        /// Its entry's id, or `rec-<take>-<ns>` for a recorded one without entry (`VisibleMarker.id`).
        var id: String
        /// `""` has none.
        var name: String
        var output: Int64
        var frame: Int
    }

    /// A chapter of the file's chapter track (`ExportSettings.chapters`).
    struct Chapter: Equatable, Sendable {
        var title: String
        var output: Int64
        var frame: Int
    }

    /// A click of the cursor (`CursorPath.clicks` of a take): a `mouseDown` the output keeps.
    struct Click: Equatable, Sendable {
        var output: Int64
        var frame: Int
        /// Where its frame draws the cursor (`Frame.cursor`), in the video's pixels; `nil` when it is not seen there.
        var point: SIMD2<Double>?
    }

    /// A zoom block of the document (`ZoomPlan.regions`) where the output shows it, its cuts closed.
    struct ZoomBlock: Equatable, Sendable {
        var id: String
        /// `TimeMap.outputRange(ofSource:take:)`.
        var output: Range<Int64>
        /// `output` in frames of the video, held to `[0, frameCount]`, a frame at least.
        var frames: Range<Int>
        /// Its own or `auto.depth`, held to 1…16 (1 if it is not a number), as the zoom camera reads it.
        var depth: Double
        var mode: ZoomMode
        var origin: Origin
    }

    /// What a clip shows instead of a stretch of its take (`ClipContent`).
    enum Content: String, Equatable, Sendable {
        case freeze, titleCard, media
    }

    /// A clip of the sequence that the output shows: the stretch of its take that is kept, and where.
    struct Cut: Equatable, Sendable {
        var take: String
        /// In host time; a point (`start == end`) for a clip with content.
        var sourceStart: HostTime
        var sourceEnd: HostTime
        /// `O_k` to `O_k + D_k`, in output nanoseconds.
        var output: Range<Int64>
        /// The clip's (an imported clip's own) as `ClipSpeed.clamped` reads it; 1 for a frozen frame and a title card.
        var speed: Double
        /// `nil` for a stretch of the take.
        var content: Content?
    }

    /// The drawn cursor of a frame.
    struct Cursor: Equatable, Sendable {
        /// Its hotspot drawn through the frame's zoom, in the video's pixels.
        var point: SIMD2<Double>
        /// Drawn: not hidden (its opacity above 0), not under the camera full screen, and inside the video.
        var visible: Bool
        /// A button is down (`CursorSample.pressed` of the frame's take).
        var pressed: Bool
    }

    /// The zoom camera of a frame: the transform its stage (its card's content, in a card) is drawn through.
    struct Zoom: Equatable, Sendable {
        var depth: Double
        /// The centre of what is shown, in pixels of the stage unzoomed.
        var center: SIMD2<Double>
    }

    struct Frame: Equatable, Sendable {
        /// `nil` when the frame has no cursor (none recorded yet, off the screen shown, a title card, an imported clip).
        var cursor: Cursor?
        var zoom: Zoom
    }

    var outputSize: SIMD2<Int>
    var frameRate: Int
    var frameCount: Int
    /// By output, ties by id.
    var markers: [Marker]
    var chapters: [Chapter]
    /// By output.
    var clicks: [Click]
    /// By output, the document's order among those that start together. Overlaps are not settled: they are notes; the
    /// camera of each frame (`frames`) is the one drawn.
    var zoomBlocks: [ZoomBlock]
    /// In the sequence's order.
    var cuts: [Cut]
    /// One per frame of the video.
    var frames: [Frame]

    /// How many frames are sampled between two looks at `isCancelled`.
    static let cancelCheckEvery = 600

    /// The timeline of the export of `document` of `project` with `settings` (size, frames per second, chapters) as a
    /// video of `frameCount` frames: each frame is the one `FrameEvaluator` makes for the renderer at its output time
    /// (`TimeMap.frameTime`), of every take the sequence shows, with each take's camera readable as `FrameRenderer` finds it
    /// in the package (`LayoutTimeline.cameraReadable`) and no analysis (what it reads moves neither the cursor nor the
    /// zoom). Reads the events of every take the sequence shows (the disk, the first time) and samples every frame: never
    /// on the main thread.
    /// - Throws: `ExportError.cancelled` once `isCancelled` says so, looked at every `cancelCheckEvery` frames.
    static func make(
        project: LoadedProject, document: EditDocument, settings: ExportSettings, frameCount: Int, isCancelled: () -> Bool
    ) throws -> EditorTimeline {
        let fps = settings.framesPerSecond, size = settings.outputSize
        let timeMap = TimeMap(sequence: document.sequence)
        let shown = [project] + project.takesShown(by: document)
        var readable: [String: Bool] = [:]
        for take in [project.take] + project.takes where readable[take.id] == nil {
            readable[take.id] = LayoutTimeline.cameraReadable(take: take) { SegmentAvailability.classify($0, in: project.package) }
        }
        let scene = FrameEvaluator(
            project: project, document: document, outputSize: size, frameRate: fps, cameraReadable: readable)
        let paths = scene.sequencePaths
        let frame = { (τ: Int64) in Self.frame(of: τ, frameRate: fps) }
        let inVideo = { (n: Int) in n >= 0 && n < frameCount }

        var buttons = Buttons(paths: paths)
        var frames: [Frame] = []
        frames.reserveCapacity(max(frameCount, 0))
        for n in 0..<max(frameCount, 0) {
            if n % cancelCheckEvery == 0, isCancelled() { throw ExportError.cancelled }
            let τ = TimeMap.frameTime(n, frameRate: fps)
            let drawn = scene.frame(at: Double(τ) / 1e9) { _ in true }
            let pressed = buttons.pressed(
                take: drawn.take ?? project.take.id, atOutput: cursorTime(of: τ, document: document, timeMap: timeMap))
            frames.append(Self.frame(drawn, pressed: pressed, outputSize: size))
        }

        var recorded: MarkerList.Recorded = [:]
        for take in shown where recorded[take.take.id] == nil {
            let instants = MarkerList.recordedInstants(in: take.events)
            if !instants.isEmpty { recorded[take.take.id] = instants }
        }
        let markers = MarkerList.visible(document: document, recorded: recorded, timeMap: timeMap).compactMap { marker in
            let n = frame(marker.output)
            return inVideo(n) ? Marker(id: marker.id, name: marker.name, output: marker.output, frame: n) : nil
        }
        let chapters = settings.chapters.compactMap { chapter in
            let n = frame(chapter.start)
            return inVideo(n) ? Chapter(title: chapter.title, output: chapter.start, frame: n) : nil
        }
        var clicks: [Click] = []
        for take in scene.takes {
            for click in paths.byTake[take]?.cursor.clicks ?? [] {
                let n = frame(click.output)
                guard inVideo(n) else { continue }
                let cursor = frames[n].cursor
                clicks.append(Click(output: click.output, frame: n, point: cursor?.visible == true ? cursor?.point : nil))
            }
        }
        clicks = clicks.enumerated().sorted { ($0.element.output, $0.offset) < ($1.element.output, $1.offset) }.map(\.element)

        return EditorTimeline(
            outputSize: size, frameRate: fps, frameCount: frameCount, markers: markers, chapters: chapters, clicks: clicks,
            zoomBlocks: zoomBlocks(of: document, timeMap: timeMap, frameRate: fps, frameCount: frameCount),
            cuts: cuts(of: document, timeMap: timeMap), frames: frames)
    }

    /// Whether a button is down, for frame after frame: each take's `CursorSample.pressed` read from a span of its cursor's
    /// path (`CursorPath.span(from:through:)`, the same bits as `sample(atOutput:)`) a second long, simulated once, instead
    /// of from a checkpoint for each frame.
    private struct Buttons {
        let paths: SequencePaths
        private var spans: [String: (covers: ClosedRange<Int64>, span: CursorPath.Span)] = [:]
        /// What a span covers: a second of output.
        private static let length: Int64 = 1_000_000_000

        init(paths: SequencePaths) {
            self.paths = paths
        }

        mutating func pressed(take: String, atOutput τ: Int64) -> Bool {
            guard let path = paths.byTake[take]?.cursor else { return false }
            if let known = spans[take], known.covers.contains(τ) { return known.span.sample(atOutput: τ)?.pressed ?? false }
            let end = τ.addingReportingOverflow(Self.length).overflow ? Int64.max : τ + Self.length
            let span = path.span(from: τ, through: end)
            spans[take] = (τ...end, span)
            return span.sample(atOutput: τ)?.pressed ?? false
        }
    }

    /// The frame of the video at `fps` that shows output instant `τ`: `round(τ · fps / 10⁹)`.
    static func frame(of τ: Int64, frameRate fps: Int) -> Int {
        Int((Double(τ) * Double(fps) / 1e9).rounded())
    }

    /// The output instant whose cursor the frame at `τ` draws: the start of its clip in a frozen frame (which draws that
    /// instant all through it), `τ` itself otherwise.
    private static func cursorTime(of τ: Int64, document: EditDocument, timeMap: TimeMap) -> Int64 {
        guard let (k, _) = timeMap.contentOffset(atOutput: τ), case .freeze = document.sequence[k].content else { return τ }
        return timeMap.clipOutputStarts[k]
    }

    /// `drawn` as the files say it: the cursor's hotspot and the zoom through the frame's transform (its card's content,
    /// in a card; the stage's, or the identity at rest), in an output of `outputSize`.
    private static func frame(_ drawn: RenderFrame, pressed: Bool, outputSize: SIMD2<Int>) -> Frame {
        let transform = drawn.card?.content ?? drawn.stage ?? .identity(outputSize: outputSize)
        let cursor = drawn.cursor.map { layer in
            let point = transform.outputPoint(ofStage: layer.hotspot, outputSize: outputSize)
            let inside = point.x >= 0 && point.y >= 0 && point.x <= Double(outputSize.x) && point.y <= Double(outputSize.y)
            return Cursor(point: point, visible: layer.opacity > 0 && !drawn.coveredByCamera && inside, pressed: pressed)
        }
        return Frame(cursor: cursor, zoom: Zoom(depth: transform.depth, center: transform.center))
    }

    /// The zoom blocks of `document` the output shows (none with `zoom.show` off), as the zoom camera places them
    /// (`ZoomCameraPath`): each by `TimeMap.outputRange(ofSource:take:)` (one with nothing kept, or nothing left in the video,
    /// is not there), its depth `depth ?? auto.depth` held to 1…16, its mode `resolvedMode(auto:)`.
    private static func zoomBlocks(of document: EditDocument, timeMap: TimeMap, frameRate fps: Int, frameCount: Int) -> [ZoomBlock] {
        guard document.zoom.show else { return [] }
        let auto = document.zoom.auto
        var blocks: [(block: ZoomBlock, order: Int)] = []
        for (order, region) in document.zoom.regions.enumerated() where region.start < region.end {
            guard let output = timeMap.outputRange(ofSource: region.start..<region.end, take: region.take), !output.isEmpty
            else { continue }
            let first = max(frame(of: output.lowerBound, frameRate: fps), 0)
            guard first < frameCount else { continue }
            let last = max(min(frame(of: output.upperBound, frameRate: fps), frameCount), first + 1)
            let read = region.depth ?? auto.depth
            let depth = read.isNaN ? 1 : min(max(read, 1), 16)
            let block = ZoomBlock(
                id: region.id, output: output, frames: first..<last, depth: depth, mode: region.resolvedMode(auto: auto),
                origin: region.origin)
            blocks.append((block, order))
        }
        return blocks.sorted { ($0.block.output.lowerBound, $0.order) < ($1.block.output.lowerBound, $1.order) }.map(\.block)
    }

    /// Every clip of `document`'s sequence the output shows (`D_k > 0`), in its order: its take's kept source range (a point
    /// for a clip with content) and its place in the output.
    private static func cuts(of document: EditDocument, timeMap: TimeMap) -> [Cut] {
        document.sequence.enumerated().compactMap { k, clip in
            let duration = TimeMap.outputDuration(of: clip)
            guard duration > 0 else { return nil }
            let start = timeMap.clipOutputStarts[k]
            let (content, speed): (Content?, Double) = switch clip.content {
            case nil: (nil, ClipSpeed.clamped(clip.speed))
            case .freeze: (.freeze, 1)
            case .card: (.titleCard, 1)
            case let .media(media): (.media, ClipSpeed.clamped(media.speed))
            }
            let end = content == nil ? max(clip.end, clip.start) : clip.start
            return Cut(
                take: clip.take, sourceStart: clip.start, sourceEnd: end, output: start..<(start + duration), speed: speed,
                content: content)
        }
    }
}
