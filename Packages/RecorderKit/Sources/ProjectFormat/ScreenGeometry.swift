// SPDX-License-Identifier: GPL-3.0-or-later

/// What is shown of a recorded screen at a host time, from the take's geometry events: the rules of phase 0 and 1a.
///
/// Where the screen is at a time, in global points: for a display, the last `displayGeometry` event of its
/// `displayID` at or before it; for a window, the last `windowGeometry` event of its track; before the first one,
/// its `globalFrame`. A frame that is not finite and positive is skipped (a window's event still says whether it is
/// on screen). What is shown of it is the display's `captureArea`, or all of it. The area is kept where it was on
/// the display when the take started: its offset from the display's corner is measured from `globalFrame`, so it
/// follows the display when the display moves, and it is clamped to the display's current size. When no part of it
/// is on the display, or it cannot be placed (a `captureArea` with a value that is not finite or a size that is not
/// positive, or a display without a finite `globalFrame` of positive size), nothing of the screen is shown, never what
/// the user left out of the area. A take of version 1 has one `displayGeometry` per display, at its start and equal to
/// its `globalFrame`, and no area: it is shown as in phase 0.
public struct ScreenGeometry: Sendable {
    /// Where the screen is: its frame in global points (`nil` when unknown), and whether macOS has it on screen.
    private struct Place: Sendable {
        var frame: Rect?
        var onScreen: Bool
    }

    /// Where the screen is before its first geometry event: its `globalFrame`.
    private let initialPlace: Place
    /// Where the screen is from each geometry event on, in time order.
    private let places: [(t: HostTime, place: Place)]
    /// In Area mode, the area in points from the display's top-left corner as the take started: `captureArea` moved
    /// by the origin of `globalFrame`. `nil` without an area.
    private let areaOffset: Rect?
    /// An area was recorded but cannot be placed: it or the display's `globalFrame` is not usable.
    private let areaUnplaced: Bool

    private static let wholeFrame = Rect(x: 0, y: 0, width: 1, height: 1)

    /// The geometry of screen track `track` (a display or a window) from the take's `events`, in any order.
    public init(track: TrackRecord, events: [InputEvent]) {
        let initialPlace = Place(frame: track.source.globalFrame.flatMap(Self.usable), onScreen: true)
        self.initialPlace = initialPlace
        var places: [(t: HostTime, place: Place)] = []
        var last = initialPlace
        let geometry = events.filter {
            switch $0.kind {
            case .displayGeometry, .windowGeometry: true
            default: false
            }
        }
        for event in geometry.sortedByTime() {
            switch event.kind {
            case let .displayGeometry(displayID, frame, _) where track.kind == .display && displayID == track.source.displayID:
                guard let frame = Self.usable(frame) else { continue }
                last = Place(frame: frame, onScreen: true)
            case let .windowGeometry(window, frame, onScreen) where track.kind == .window && window == track.id:
                // Without a usable frame, the window stays where it was, but whether it is on screen still counts.
                last = Place(frame: Self.usable(frame) ?? last.frame, onScreen: onScreen)
            default:
                continue
            }
            places.append((event.t, last))
        }
        self.places = places
        if track.kind == .display, let area = track.source.captureArea {
            let placed = Self.usable(area).flatMap { area in
                initialPlace.frame.map { Rect(x: area.x - $0.x, y: area.y - $0.y, width: area.width, height: area.height) }
            }
            areaOffset = placed
            areaUnplaced = placed == nil
        } else {
            areaOffset = nil
            areaUnplaced = false
        }
    }

    /// What is shown of the screen at `host`: without a usable frame, all of it with no `region`. `nil`, nothing of
    /// the screen, when its area is not on the display or cannot be placed.
    public func shown(at host: HostTime) -> ShownScreen? {
        guard !areaUnplaced else { return nil }
        let place = place(at: host)
        guard let frame = place.frame else { return ShownScreen(crop: Self.wholeFrame, region: nil, onScreen: place.onScreen) }
        guard let areaOffset else { return ShownScreen(crop: Self.wholeFrame, region: frame, onScreen: place.onScreen) }
        guard let area = Self.crop(areaOffset, in: frame) else { return nil }
        let region = Rect(
            x: frame.x + area.x * frame.width, y: frame.y + area.y * frame.height,
            width: area.width * frame.width, height: area.height * frame.height)
        return ShownScreen(crop: area, region: region, onScreen: place.onScreen)
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

    /// The area at `offset` from the display's corner as fractions of the display's current `frame`
    /// (`(offset.x / frame.width, …, offset.width / frame.width, …)`, where `offset.x` is `area.x − globalFrame.x`)
    /// clamped to `[0, 1]`; `nil` when no part of it is on the display.
    private static func crop(_ offset: Rect, in frame: Rect) -> Rect? {
        var x = offset.x / frame.width, width = offset.width / frame.width
        var y = offset.y / frame.height, height = offset.height / frame.height
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
}

/// What is shown of a screen at a time.
public struct ShownScreen: Equatable, Sendable {
    /// The part of the recorded frame shown, as fractions of it (0, 0 is its top-left corner, 1, 1 the bottom-right
    /// one): the area in Area mode, the whole frame otherwise.
    public var crop: Rect
    /// The global points `crop` shows, where the cursor is placed; `nil` when the screen has no usable frame.
    public var region: Rect?
    /// Whether macOS has the screen on screen (a window can be off it).
    public var onScreen: Bool

    public init(crop: Rect, region: Rect? = nil, onScreen: Bool) {
        self.crop = crop
        self.region = region
        self.onScreen = onScreen
    }
}
