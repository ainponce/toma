// SPDX-License-Identifier: GPL-3.0-or-later
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
/// - Background: the document's gradient, colour or wallpaper (`WallpaperPreset`). A wallpaper this version does not
///   know, an image and the desktop draw the classic gradient (`Background.tomaClassic`) until the render has them.
/// - Screen: the take's track of `screens.initial`, or of the last `screens.changes` of the take at or before the
///   source instant (it jumps); none without one, or for a track the take does not have. What is shown of it, and
///   where, is `ScreenGeometry`; its rect is `StageLayout.screenRect` inside the document's padding, with the
///   document's corners.
/// - Cursor (Toma's arrow, `cursor.show`): the take's pointer positions (`cursor`, `mouseDown`, `mouseUp`) in output
///   time. A position in a cut between two clips is dropped; one before the first clip or after the last keeps its
///   time through that clip's mapping (negative, or past `D`), so a sample the recorder took before the sources
///   started counts at output 0, as it always did. At an output time the cursor is the last position at or before it,
///   moved toward the next one if that comes within `maxInterpolationGap`; `scale × 24` points tall in the region the
///   screen shows; hidden off that region, while a window is not on screen, and without a usable frame.
/// - Camera (`camera.show`): the first camera track with a segment, from the start of its first segment on, at the
///   `CameraStyleTimeline` of the take's `camera.initial` and its `camera.changes` in output time: a change in a cut
///   rules from the first instant kept after it, one before the first clip keeps its time through that clip's mapping
///   (it is under way at output 0, as it always was), and one after the last never rules.
public struct FrameEvaluator: Sendable {
    /// Two cursor samples at most this far apart in output seconds are interpolated; farther apart, the cursor stays
    /// put until the next one.
    static let maxInterpolationGap = 0.050

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
    /// The screen track of the take at its start, and from each of its changes on (in time order).
    private let initialScreen: String?
    private let screenChanges: [(t: HostTime, track: String)]
    /// Where each screen track the plan names is, by ID: only the take's screen tracks.
    private let screens: [String: ScreenGeometry]
    /// The video tracks a frame can show: the screens of `screens`, then the camera when it is shown.
    let videoTrackIDs: [String]
    /// ID of the take's camera track, the first with a segment; `nil` if it has none.
    let cameraTrackID: String?
    /// Start of the camera's first segment.
    private let cameraStart: HostTime?
    private let cameraStyle: CameraStyleTimeline
    /// Cursor, mouse-down and mouse-up positions in global points at their output times, in time order.
    private let positions: [(t: Int64, point: SIMD2<Double>)]

    public init(take: TakeRecord, events: [InputEvent], document: EditDocument, outputSize: SIMD2<Int>) {
        let timeMap = TimeMap(sequence: document.sequence)
        self.document = document
        self.timeMap = timeMap
        timelineStart = document.sequence.first?.start ?? HostTime(nanoseconds: 0)
        duration = timeMap.durationSeconds
        takeID = take.id
        self.outputSize = outputSize
        (background, gradient) = Self.background(of: document.style.background)
        let ordered = events.sortedByTime()
        let placement = OutputPlacement(sequence: document.sequence, timeMap: timeMap, take: take.id)

        initialScreen = document.screens.initial[take.id]
        let changes = document.screens.changes.filter { $0.take == take.id }
        screenChanges = changes.enumerated()
            .sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }
            .map { ($0.element.t, $0.element.track) }
        var screens: [String: ScreenGeometry] = [:]
        var videoTrackIDs: [String] = []
        for id in [initialScreen].compactMap({ $0 }) + changes.map(\.track) where screens[id] == nil {
            guard let track = take.track(id), track.kind.isScreen else { continue }
            screens[id] = ScreenGeometry(track: track, events: ordered)
            videoTrackIDs.append(id)
        }
        self.screens = screens

        let camera = take.tracks.first { $0.kind == .camera && !$0.segments.isEmpty }
        cameraTrackID = camera?.id
        cameraStart = camera?.segments.map(\.startHostTime).min()
        if document.camera.show, let camera { videoTrackIDs.append(camera.id) }
        self.videoTrackIDs = videoTrackIDs
        cameraStyle = CameraStyleTimeline(
            initial: document.camera.initial[take.id] ?? .default,
            changes: document.camera.changes.filter { $0.take == take.id }.compactMap { change in
                placement.output(ofChangeAt: change.t).map { ($0, change.style) }
            })

        positions = ordered.compactMap { event in
            guard let point = event.kind.pointerPosition, let t = placement.output(ofSampleAt: event.t) else { return nil }
            return (t, point)
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

    public func frame(at outputTime: Double) -> RenderFrame {
        var frame = RenderFrame(
            outputSize: outputSize, gradientStart: gradient.start, gradientEnd: gradient.end, gradientAngleDegrees: gradient.angle,
            background: background)
        let τ = TimeMap.outputNanoseconds(seconds: outputTime)
        guard let shown = timeMap.source(atOutput: τ), document.sequence[shown.clip].take == takeID else { return frame }
        let source = shown.source
        // The output time shown, as `source(atOutput:)` clamps it.
        let output = min(max(τ, 0), timeMap.duration - 1)
        let size = SIMD2(Double(outputSize.x), Double(outputSize.y))
        if let trackID = screen(at: source), let view = screens[trackID]?.shown(at: source) {
            let rect = StageLayout.screenRect(
                contentAspect: view.region.map { $0.width / $0.height }, padding: document.style.padding, outputSize: size)
            frame.screen = ScreenLayer(
                trackID: trackID, sourceTime: source, rect: rect, cornerRadius: document.style.cornerRadius * size.x, crop: view.crop)
            if document.cursor.show, view.onScreen, let region = view.region {
                frame.cursor = cursor(at: output, in: region, shownIn: rect)
            }
        }
        frame.camera = camera(at: source, output: output)
        return frame
    }

    /// A gradient as the shader takes it.
    private typealias Gradient = (start: SIMD4<Float>, end: SIMD4<Float>, angle: Float)

    /// What the compositor draws for `background`, and the gradient it draws with `.gradient`: that of a gradient, the
    /// classic one otherwise. An unknown wallpaper, an image and the desktop are the classic gradient.
    private static func background(of background: Background) -> (layer: BackgroundLayer, gradient: Gradient) {
        func floats(_ color: RGBA) -> SIMD4<Float> { SIMD4(Float(color.r), Float(color.g), Float(color.b), Float(color.a)) }
        func classic() -> Gradient { Self.background(of: .tomaClassic).gradient }
        switch background {
        case let .gradient(start, end, angle):
            return (.gradient, (floats(start), floats(end), Float(angle)))
        case let .color(color):
            return (.color(floats(color)), classic())
        case let .wallpaper(id):
            return (WallpaperPreset.preset(id: id).map(BackgroundLayer.wallpaper) ?? .gradient, classic())
        case .image, .desktop:
            return (.gradient, classic())
        }
    }

    /// The screen track shown at `source`: the last change at or before it, or the initial one.
    private func screen(at source: HostTime) -> String? {
        var low = 0, high = screenChanges.count
        while low < high {
            let mid = (low + high) / 2
            if screenChanges[mid].t <= source { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? screenChanges[low - 1].track : initialScreen
    }

    /// The cursor at output time `τ`: the last position at or before it, moved toward the next one if that comes
    /// within `maxInterpolationGap`, placed on `rect` where it is in `region`. `nil` before the first position and off
    /// `region`.
    private func cursor(at τ: Int64, in region: Rect, shownIn rect: Rect) -> CursorLayer? {
        // Index of the first position after `τ`.
        var low = 0, high = positions.count
        while low < high {
            let mid = (low + high) / 2
            if positions[mid].t <= τ { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let previous = positions[low - 1]
        var point = previous.point
        if low < positions.count {
            let next = positions[low]
            let gap = Self.seconds(next.t, since: previous.t)
            if gap <= Self.maxInterpolationGap {
                point += (next.point - previous.point) * (Self.seconds(τ, since: previous.t) / gap)
            }
        }
        let global = CGPoint(x: point.x, y: point.y)
        guard CursorGeometry.contains(global, region) else { return nil }
        let normalized = CursorGeometry.normalized(global, in: region)
        return CursorLayer(
            hotspot: SIMD2(rect.x, rect.y) + normalized * SIMD2(rect.width, rect.height),
            height: document.cursor.scale * 24 * rect.height / region.height
        )
    }

    /// The camera at source instant `source` and output time `output`, from the start of its first segment on.
    private func camera(at source: HostTime, output: Int64) -> CameraLayer? {
        guard document.camera.show, let cameraTrackID, let cameraStart, source >= cameraStart else { return nil }
        let frame = cameraStyle.frame(atOutput: output, output: SIMD2(Double(outputSize.x), Double(outputSize.y)))
        return CameraLayer(trackID: cameraTrackID, sourceTime: source, rect: frame.rect, cornerRadius: frame.cornerRadius)
    }

    /// Seconds from output time `b` to `a`, counted as `HostTime.seconds(since:)` counts them: with integer
    /// nanoseconds below 2⁵³, the same `Double` as the difference of the source instants they stand for at 1×.
    private static func seconds(_ a: Int64, since b: Int64) -> Double {
        (Double(a) - Double(b)) / 1_000_000_000
    }
}

/// Where a source instant of a take goes in the output, beyond `TimeMap`'s own rule for the instants of its clips:
/// what happens at an instant the clips leave out.
private struct OutputPlacement {
    let sequence: [Clip]
    let timeMap: TimeMap
    let take: String
    /// The take's first and last clips with any source (`start < end`), as `TimeMap` counts them: indices in `sequence`.
    let first: Int?
    let last: Int?

    init(sequence: [Clip], timeMap: TimeMap, take: String) {
        self.sequence = sequence
        self.timeMap = timeMap
        self.take = take
        let clips = sequence.indices.filter { sequence[$0].take == take && sequence[$0].start < sequence[$0].end }
        first = clips.first
        last = clips.last
    }

    /// A pointer sample's output time: its own in a clip, through the mapping of the first clip before it and of the
    /// last one from its end on; `nil` in a cut between two clips.
    func output(ofSampleAt x: HostTime) -> Int64? {
        guard let first, let last else { return nil }
        if x < sequence[first].start { return extrapolated(x, clip: first) }
        if x >= sequence[last].end { return extrapolated(x, clip: last) }
        return timeMap.output(atSource: x, take: take)
    }

    /// Where a change (of the camera) starts to rule: before the first clip, at its time through that clip's mapping;
    /// otherwise from the first instant kept at or after it (`TimeMap.firstKeptOutput`), never after the last clip.
    func output(ofChangeAt x: HostTime) -> Int64? {
        guard let first else { return nil }
        if x < sequence[first].start { return extrapolated(x, clip: first) }
        return timeMap.firstKeptOutput(atOrAfter: x, take: take)
    }

    /// `O_k + round((x − s_k) / v_k)` for an instant `x` outside clip `k`, as `TimeMap` maps the ones inside it,
    /// saturating at the ends of `Int64`.
    private func extrapolated(_ x: HostTime, clip k: Int) -> Int64 {
        let clip = sequence[k]
        let speed = Self.speed(of: clip)
        let offset = x >= clip.start
            ? Self.rounded(Double(x.nanoseconds - clip.start.nanoseconds) / speed)
            : -Self.rounded(Double(clip.start.nanoseconds - x.nanoseconds) / speed)
        let (sum, overflow) = timeMap.clipOutputStarts[k].addingReportingOverflow(offset)
        return overflow ? (offset < 0 ? .min : .max) : sum
    }

    /// The speed `TimeMap` reads for `clip`: clamped to 0.25…16, 1 when it is not a number.
    private static func speed(of clip: Clip) -> Double {
        clip.speed.isNaN ? 1 : min(max(clip.speed, 0.25), 16)
    }

    /// `x` (never negative) rounded to the nearest integer, halves away from zero, at most `Int64.max`.
    private static func rounded(_ x: Double) -> Int64 {
        let rounded = x.rounded()
        // `Double(Int64.max)` is 2⁶³, one past it.
        return rounded >= Double(Int64.max) ? .max : Int64(rounded)
    }
}
