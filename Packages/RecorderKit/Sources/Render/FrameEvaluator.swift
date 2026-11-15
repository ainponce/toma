// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import ProjectFormat

/// Works out what an output frame shows at an output time: a pure function of the take, its events,
/// the style and the output size.
///
/// The screen is the track `ScreenChoice` picks. Output time 0 is `timelineStart`, the start of that track's first
/// segment. The timeline ends at the latest segment end (the start, for a segment still open) of the screen and of
/// the take's first microphone track, so microphone audio recorded after the screen's last segment (a display that
/// never came back) is in the preview and the export, over the screen's last frame, which `TrackFrameReader` holds.
/// A take whose screen has no segment has a timeline of 0 s. Output times are clamped to `[0, duration]`.
///
/// Where the screen is at a time, in global points: for a display, the last `displayGeometry` event of its
/// `displayID` at or before it; for a window, the last `windowGeometry` event of its track; before the first one,
/// its `globalFrame` (events with a frame that is not finite and positive are skipped). What is shown of it is the
/// display's `captureArea` clamped to it (the whole display when no part of the area is on it), or all of it: the
/// screen's rect has the shape of that, the cursor is placed on it and hidden off it, and hidden while a window is
/// not on screen. A take of version 1 has one `displayGeometry` per display, at its start and equal to its
/// `globalFrame`, and no area: it is drawn as in phase 0.
///
/// The camera is the first camera track with a segment, drawn from the start of its first segment on at the
/// `CameraStyleTimeline` of the take's `cameraStyle` (`CameraStyle.default` without one) and its `cameraStyle`
/// events, in the whole output. It does not make the timeline longer.
public struct FrameEvaluator: Sendable {
    /// Two cursor samples at most this far apart are interpolated; farther apart, the cursor stays put
    /// until the next one.
    static let maxInterpolationGap = 0.050

    /// Host time at output time 0.
    public private(set) var timelineStart: HostTime
    /// Seconds from `timelineStart` to the latest end of a segment of the screen or of the microphone.
    public private(set) var duration: Double

    private let style: StyleV0
    private let outputSize: SIMD2<Int>
    /// ID of the screen track shown, `nil` if the take has none.
    let screenTrackID: String?
    /// Where the screen is before its first geometry event: its `globalFrame`.
    private let initialPlace: Place
    /// Where the screen is from each geometry event on, in time order.
    private let places: [(t: HostTime, place: Place)]
    /// The area of the display shown, in global points: `captureArea` in Area mode.
    private let captureArea: Rect?
    /// ID of the camera track shown, `nil` if the take has none with a segment.
    let cameraTrackID: String?
    /// Start of the camera's first segment.
    private let cameraStart: HostTime?
    private let cameraStyle: CameraStyleTimeline
    /// Cursor, mouse-down and mouse-up positions in global points, in time order.
    private let positions: [(t: HostTime, point: SIMD2<Double>)]

    /// Where the screen is: its frame in global points (`nil` when unknown), and whether macOS has it on screen.
    private struct Place: Sendable {
        var frame: Rect?
        var onScreen: Bool
    }

    /// What is shown of the screen at a time.
    private struct ScreenView {
        /// In output pixels.
        var rect: Rect
        /// Of the recorded frame.
        var crop: Rect
        /// The global points the crop shows, where the cursor is placed; `nil` when the cursor is not shown.
        var cursorRegion: Rect?
    }

    private static let wholeFrame = Rect(x: 0, y: 0, width: 1, height: 1)

    public init(take: TakeRecord, events: [InputEvent], style: StyleV0, outputSize: SIMD2<Int>) {
        self.style = style
        self.outputSize = outputSize
        let ordered = events.sortedByTime()
        let screen = ScreenChoice.screenTrack(in: take, events: events)
        screenTrackID = screen?.id
        let segments = screen?.segments ?? []
        let start = segments.map(\.startHostTime).min() ?? HostTime(nanoseconds: 0)
        // Without a screen segment there is nothing to show, and no start to measure the microphone from.
        let microphone = segments.isEmpty ? [] : take.tracks.first { $0.kind == .microphone }?.segments ?? []
        // An open segment (no end yet) counts up to its start.
        let end = (segments + microphone).map { $0.endHostTime ?? $0.startHostTime }.max() ?? start
        timelineStart = start
        duration = max(0, end.seconds(since: start))

        initialPlace = Place(frame: screen?.source.globalFrame.flatMap(Self.usable), onScreen: true)
        places = ordered.compactMap { event -> (t: HostTime, place: Place)? in
            guard let screen else { return nil }
            switch event.kind {
            case let .displayGeometry(displayID, frame, _) where screen.kind == .display && displayID == screen.source.displayID:
                return Self.usable(frame).map { (event.t, Place(frame: $0, onScreen: true)) }
            case let .windowGeometry(track, frame, onScreen) where screen.kind == .window && track == screen.id:
                return Self.usable(frame).map { (event.t, Place(frame: $0, onScreen: onScreen)) }
            default:
                return nil
            }
        }
        captureArea = screen?.kind == .display ? screen?.source.captureArea.flatMap(Self.usable) : nil

        let camera = take.tracks.first { $0.kind == .camera && !$0.segments.isEmpty }
        cameraTrackID = camera?.id
        cameraStart = camera?.segments.map(\.startHostTime).min()
        cameraStyle = CameraStyleTimeline(initial: take.cameraStyle ?? .default, events: events)

        positions = ordered.compactMap { event in event.kind.pointerPosition.map { (event.t, $0) } }
    }

    public func frame(at outputTime: Double) -> RenderFrame {
        let time = outputTime.isNaN ? 0 : min(max(outputTime, 0), duration)
        let host = timelineStart.adding(seconds: time)
        let view = screenView(at: host)
        return RenderFrame(
            outputSize: outputSize,
            gradientStart: style.gradientStart,
            gradientEnd: style.gradientEnd,
            gradientAngleDegrees: style.gradientAngleDegrees,
            screen: screenTrackID.map {
                ScreenLayer(
                    trackID: $0, sourceTime: host, rect: view.rect,
                    cornerRadius: style.cornerRadiusFraction * Double(outputSize.x), crop: view.crop)
            },
            cursor: cursor(at: host, on: view),
            camera: camera(at: host)
        )
    }

    /// `rect` when its values are finite and its size positive.
    private static func usable(_ rect: Rect) -> Rect? {
        [rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0 ? rect : nil
    }

    /// Where the screen is at `host`: the last geometry event at or before it, or its `globalFrame`.
    private func place(at host: HostTime) -> Place {
        var low = 0, high = places.count
        while low < high {
            let mid = (low + high) / 2
            if places[mid].t <= host { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? places[low - 1].place : initialPlace
    }

    /// What is shown of the screen at `host`, and where. Without a frame, the whole area inside the padding and
    /// no cursor.
    private func screenView(at host: HostTime) -> ScreenView {
        let place = place(at: host)
        guard let frame = place.frame else {
            return ScreenView(rect: Self.contentRect(aspect: nil, style: style, outputSize: outputSize), crop: Self.wholeFrame, cursorRegion: nil)
        }
        var crop = Self.wholeFrame, region = frame
        if let captureArea, let area = Self.crop(captureArea, in: frame) {
            crop = area
            region = Rect(
                x: frame.x + area.x * frame.width, y: frame.y + area.y * frame.height,
                width: area.width * frame.width, height: area.height * frame.height)
        }
        let rect = Self.contentRect(aspect: region.width / region.height, style: style, outputSize: outputSize)
        return ScreenView(rect: rect, crop: crop, cursorRegion: place.onScreen ? region : nil)
    }

    /// `area` as fractions of `frame` (`((area.x − frame.x) / frame.width, …, area.width / frame.width, …)`) clamped
    /// to `[0, 1]`; `nil` when no part of it is on `frame`.
    private static func crop(_ area: Rect, in frame: Rect) -> Rect? {
        var x = (area.x - frame.x) / frame.width, width = area.width / frame.width
        var y = (area.y - frame.y) / frame.height, height = area.height / frame.height
        if x < 0 {
            width += x
            x = 0
        }
        if y < 0 {
            height += y
            y = 0
        }
        width = min(width, 1 - x)
        height = min(height, 1 - y)
        guard width > 0, height > 0 else { return nil }
        return Rect(x: x, y: y, width: width, height: height)
    }

    /// The screen's rect: the area inside the padding, or the largest rect of `aspect` centred in it. Without an
    /// aspect, the whole area inside the padding.
    private static func contentRect(aspect: Double?, style: StyleV0, outputSize: SIMD2<Int>) -> Rect {
        let width = Double(outputSize.x), height = Double(outputSize.y)
        let padding = style.paddingFraction * width
        let available = SIMD2(max(width - 2 * padding, 0), max(height - 2 * padding, 0))
        var size = available
        if let aspect, available.x > 0, available.y > 0 {
            size = available.x / available.y > aspect
                ? SIMD2(available.y * aspect, available.y)
                : SIMD2(available.x, available.x / aspect)
        }
        return Rect(x: (width - size.x) / 2, y: (height - size.y) / 2, width: size.x, height: size.y)
    }

    /// The cursor at `host`: the last position at or before it, moved toward the next one if that comes
    /// within `maxInterpolationGap`. `nil` before the first position, off what `view` shows, or without a geometry.
    private func cursor(at host: HostTime, on view: ScreenView) -> CursorLayer? {
        guard let region = view.cursorRegion, screenTrackID != nil else { return nil }
        // Index of the first position after `host`.
        var low = 0, high = positions.count
        while low < high {
            let mid = (low + high) / 2
            if positions[mid].t <= host { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let previous = positions[low - 1]
        var point = previous.point
        if low < positions.count {
            let next = positions[low]
            let gap = next.t.seconds(since: previous.t)
            if gap <= Self.maxInterpolationGap {
                point += (next.point - previous.point) * (host.seconds(since: previous.t) / gap)
            }
        }
        let global = CGPoint(x: point.x, y: point.y)
        guard CursorGeometry.contains(global, region) else { return nil }
        let normalized = CursorGeometry.normalized(global, in: region)
        let rect = view.rect
        return CursorLayer(
            hotspot: SIMD2(rect.x, rect.y) + normalized * SIMD2(rect.width, rect.height),
            height: style.cursorPointHeight * rect.height / region.height
        )
    }

    /// The camera at `host`, from the start of its first segment on.
    private func camera(at host: HostTime) -> CameraLayer? {
        guard let cameraTrackID, let cameraStart, host >= cameraStart else { return nil }
        let frame = cameraStyle.frame(at: host, output: SIMD2(Double(outputSize.x), Double(outputSize.y)))
        return CameraLayer(trackID: cameraTrackID, sourceTime: host, rect: frame.rect, cornerRadius: frame.cornerRadius)
    }
}
