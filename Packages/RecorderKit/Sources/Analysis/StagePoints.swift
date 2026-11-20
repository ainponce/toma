// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import ProjectFormat

/// Where things of a take are on the stage, in stage units: the stage is 1 tall and `aspect.ratio` wide, origin at
/// its top left, so a position does not depend on the size the output is drawn at (design §8.1 and §8.6).
///
/// The screen shown at a source instant is `shownScreen(at:)`, the one rule the render shows it by too
/// (`FrameEvaluator`): the take's track of `screens.initial`, or of the last `screens.changes` of the take at or before
/// the instant; none without one, or for a track the take does not have or that is not a screen. What is shown of it,
/// and where, is `ScreenGeometry`; its rect is `StageLayout.screenRect` inside the document's padding, as the render
/// places it (the render places it at the output's own size, and the cursor on it there). With a macOS window frame
/// around the screen (`style.frame`), the window is `StageLayout.windowRect` as the render places it in an output of the
/// document's aspect 1080 px on its shorter side (the 1920 × 1080 of the preview), the size the bar's 18 px floor is
/// measured at. Stage units cannot hold a floor in pixels, so that is the render's window only in outputs where the bar
/// is at its floor in both or in neither: a smaller output with a wide padding, whose bar is at its floor and the
/// reference's is not (720 × 720 with a padding past about 0.11), has its window a few pixels off this one. The zoom
/// camera keeps to this rect (`ZoomCameraPath`), and the render places its crop again over the window's exact rect at
/// its own size (`FrameEvaluator`), so even a deep zoom shows no strip of background beside it. With a device frame
/// (`deviceFrame-1`, with the screen fitted, `style.reframe` `fit`), the screen is the device's
/// (`StageLayout.deviceRects(contentAspect:padding:outputSize:model:)`) and the window its bounds: every measure of a
/// device is a fraction of its screen, so stage units hold it exactly.
///
/// Following the cursor (`style.reframe` `followCursor`, `reframe-1`), there is never a frame, and a view wider than the
/// room (`isReframed(_:)`) fills the whole room inside the padding (`room`) with a window of its region as tall as it
/// (`ReframePath.part`); a view no wider than the room is placed whole, as with `fit`.
public struct StagePoints: Sendable {
    /// The output the window frame is placed in: the document's aspect, 1080 px on its shorter side.
    private static let windowFrameShortSide = 1080

    /// Width over height of the stage: the document's aspect (`auto`: the content's), the output's.
    private let ratio: Double
    /// The ratio of the content `auto` follows (`StageLayout.contentRatio`): of the take of the document's first clip
    /// (`StageLayout.contentRatioTake(of:ownTake:)`), given for a stage of another take; `nil` without a screen. The same
    /// one the export and the preview size themselves by.
    public let contentRatio: Double?
    /// The document's padding, as a fraction of the stage's width.
    private let padding: Double
    /// How the screen fills the stage (`style.reframe`).
    private let reframe: Reframe
    /// The take the document's screens are of.
    let takeID: String
    /// With a macOS window frame, the output its rects are worked out in; `nil` without a frame.
    private let windowFrameOutput: SIMD2<Double>?
    /// With a device frame around the fitted screen, its model; `nil` without one.
    private let device: DeviceModel?
    /// The screen track of the take at its start, and from each of its changes on (in time order).
    private let initialScreen: String?
    private let screenChanges: [(t: HostTime, track: String)]
    /// The source instants of the take's geometry events (`displayGeometry` and `windowGeometry`, of any screen), in
    /// order: with `screenChanges`, every instant at which what `shownScreen(at:)` gives can change.
    private let geometryTimes: [HostTime]
    /// Where each screen track the document names is, by ID: only the take's screen tracks.
    private let screens: [String: ScreenGeometry]
    /// The screen tracks of `screens`, each once, in the order the document names them: `screens.initial`, then
    /// `screens.changes` as listed. Those a frame can show.
    public let screenTrackIDs: [String]

    /// `contentRatio`: the ratio `auto` follows, for a stage of a take that is not the one of the document's first clip
    /// (phase 3 design §9: every take's stage is laid out in the output, its screens fitted inside it):
    /// `StageLayout.contentRatio(project:document:)`, `.some(nil)` when that take has no screen. `nil` (the default) works
    /// it out from `take`, as phase 2 does: the stage of the take of the first clip, or of the only take.
    public init(take: TakeRecord, events: [InputEvent], document: EditDocument, contentRatio: Double?? = nil) {
        let ordered = events.sortedByTime()
        self.init(
            take: take, document: document, geometryTimes: TakeScreens.geometryTimes(of: ordered), contentRatio: contentRatio
        ) {
            ScreenGeometry(track: $0, events: ordered)
        }
    }

    /// The same as `init(take:events:document:contentRatio:)`, from the take's screens read once (`TakeScreens`): it reads
    /// only what the document names, so an editor makes one for each revision without going over the take's events again.
    public init(take: TakeRecord, document: EditDocument, screens: TakeScreens, contentRatio: Double?? = nil) {
        self.init(take: take, document: document, geometryTimes: screens.geometryTimes, contentRatio: contentRatio) {
            screens.geometry(of: $0)
        }
    }

    private init(
        take: TakeRecord, document: EditDocument, geometryTimes: [HostTime], contentRatio given: Double??,
        geometry: (TrackRecord) -> ScreenGeometry
    ) {
        let contentRatio = given ?? StageLayout.contentRatio(take: take, document: document, geometry: geometry)
        self.contentRatio = contentRatio
        ratio = document.aspect.ratio(contentRatio: contentRatio)
        padding = document.style.padding
        reframe = document.style.reframe
        takeID = take.id
        self.geometryTimes = geometryTimes
        switch document.style.frame {
        case .none:
            (windowFrameOutput, device) = (nil, nil)
        case let .device(frame):
            // Only around the screen fitted whole: following the cursor, the screen is cut and has no frame.
            (windowFrameOutput, device) = (nil, document.style.reframe == .fit ? frame.model : nil)
        case .macWindow:
            // The same: following the cursor, no window frame either (phase 2 design §6.5).
            windowFrameOutput = document.style.reframe == .fit
                ? SIMD2<Double>(StageLayout.outputSize(
                    aspect: document.aspect, shortSide: Self.windowFrameShortSide, contentRatio: contentRatio))
                : nil
            device = nil
        }
        let initialScreen = document.screens.initial[take.id]
        self.initialScreen = initialScreen
        let changes = document.screens.changes.filter { $0.take == take.id }
        screenChanges = changes.enumerated()
            .sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }
            .map { ($0.element.t, $0.element.track) }
        var screens: [String: ScreenGeometry] = [:]
        var screenTrackIDs: [String] = []
        for id in [initialScreen].compactMap({ $0 }) + changes.map(\.track) where screens[id] == nil {
            guard let track = take.track(id), track.kind.isScreen else { continue }
            screens[id] = geometry(track)
            screenTrackIDs.append(id)
        }
        self.screens = screens
        self.screenTrackIDs = screenTrackIDs
    }

    /// The stage's width and height: the aspect's ratio (the content's for `auto`) and 1.
    public var stageSize: SIMD2<Double> { SIMD2(ratio, 1) }

    /// The whole room the screen has inside the padding, in stage units (`StageLayout.screenRect` without an aspect):
    /// what a reframed screen fills (an empty rect at the centre when the padding leaves it none).
    public var room: Rect {
        StageLayout.screenRect(contentAspect: nil, padding: padding, outputSize: stageSize)
    }

    /// Whether `view` is reframed (`reframe-1`): the document follows the cursor and `view`'s region is wider than the
    /// room. A view no wider than the room, or without a region, is placed whole.
    public func isReframed(_ view: ShownScreen) -> Bool {
        reframedWidth(of: view) != nil
    }

    /// The width of the window of `view`'s region a reframed screen shows, as a fraction of the region's width: the
    /// room's aspect over the region's, below 1; `nil` when `view` is not reframed (`isReframed(_:)`).
    func reframedWidth(of view: ShownScreen) -> Double? {
        guard reframe == .followCursor, let region = view.region, region.width > 0, region.height > 0 else { return nil }
        let room = room
        guard room.width > 0, room.height > 0 else { return nil }
        let width = (room.width / room.height) / (region.width / region.height)
        return width.isFinite && width > 0 && width < 1 - Self.sameAspect ? width : nil
    }

    /// Two aspects closer than this (relatively) are the same: a region of the room's own aspect is placed whole.
    private static let sameAspect = 1e-9

    /// Where `global` (in global points) is on the stage at source instant `host`: placed in the screen's rect as it is
    /// in the region the screen shows (under the bar, with a window frame). `nil` off that region (its far edges are out,
    /// as for the drawn cursor), while a window is not on screen, for a screen without a usable frame, and with no screen
    /// shown. A reframed screen (`isReframed(_:)`) shows its whole region squeezed into the room here; with the part it
    /// shows, `stagePoint(global:at:part:)` places it.
    public func stagePoint(global: SIMD2<Double>, at host: HostTime) -> SIMD2<Double>? {
        stagePoint(global: global, at: host, part: nil)
    }

    /// `stagePoint(global:at:)` where the screen shown, when it is reframed (`isReframed(_:)`), shows `part` of its region
    /// (`ReframePath.part`, in fractions of the region) over the whole room: the point placed in that window, `nil`
    /// outside it (its far edges are out). For a view that is not reframed, or with `part` `nil`, the same as
    /// `stagePoint(global:at:)`.
    public func stagePoint(global: SIMD2<Double>, at host: HostTime, part: Rect?) -> SIMD2<Double>? {
        guard let view = shownScreen(at: host)?.view else { return nil }
        return stagePoint(global: global, in: view, part: part.flatMap { isReframed(view) ? $0 : nil })
    }

    /// `global` placed on the stage as `view` shows it, through `part` of its region when there is one: see
    /// `stagePoint(global:at:part:)`.
    func stagePoint(global: SIMD2<Double>, in view: ShownScreen, part: Rect?) -> SIMD2<Double>? {
        guard view.onScreen, let region = view.region else { return nil }
        let point = CGPoint(x: global.x, y: global.y)
        guard CursorGeometry.contains(point, region),
            let shown = Self.placed(CursorGeometry.normalized(point, in: region), in: part)
        else { return nil }
        let rect = rects(of: view).screen
        return SIMD2(rect.x, rect.y) + shown * SIMD2(rect.width, rect.height)
    }

    /// `fraction`, of a region, in fractions of `part` of it; `nil` outside `part` (its far edges are out). `fraction`
    /// itself without a part.
    static func placed(_ fraction: SIMD2<Double>, in part: Rect?) -> SIMD2<Double>? {
        guard let part else { return fraction }
        let shown = (fraction - SIMD2(part.x, part.y)) / SIMD2(part.width, part.height)
        guard shown.x >= 0, shown.x < 1, shown.y >= 0, shown.y < 1 else { return nil }
        return shown
    }

    /// Every source instant from which what `shownScreen(at:)` gives can change, in order and each once: the take's
    /// `screens.changes` and its geometry events (more than that, never fewer).
    var viewChanges: [HostTime] {
        // Both are in order: merged.
        var instants: [HostTime] = []
        instants.reserveCapacity(screenChanges.count + geometryTimes.count)
        var (i, j) = (0, 0)
        while i < screenChanges.count || j < geometryTimes.count {
            let instant: HostTime
            if j == geometryTimes.count || (i < screenChanges.count && screenChanges[i].t <= geometryTimes[j]) {
                instant = screenChanges[i].t
                i += 1
            } else {
                instant = geometryTimes[j]
                j += 1
            }
            if instants.last != instant { instants.append(instant) }
        }
        return instants
    }

    /// The rect of the screen shown at source instant `host`, in stage units: with a window frame, the whole window, bar
    /// included (the `R` the zoom's camera keeps to, design §7.4); with a device frame, the device's bounds. `nil` with no
    /// screen shown.
    public func screenRect(at host: HostTime) -> Rect? {
        shownScreen(at: host).map { rects(of: $0.view).window }
    }

    /// The screen shown at source instant `host`, and what is shown of it: the track of the last of the take's
    /// `screens.changes` at or before `host`, or of `screens.initial`, as `ScreenGeometry` shows it then. `nil` without
    /// one, for a track the take does not have or that is not a screen, and when nothing of it is shown.
    public func shownScreen(at host: HostTime) -> (track: String, view: ShownScreen)? {
        var low = 0, high = screenChanges.count
        while low < high {
            let mid = (low + high) / 2
            if screenChanges[mid].t <= host { low = mid + 1 } else { high = mid }
        }
        guard let track = low > 0 ? screenChanges[low - 1].track : initialScreen, let view = screens[track]?.shown(at: host)
        else { return nil }
        return (track, view)
    }

    /// The screen's rect for `view`, of the region's aspect (of the whole room inside the padding without a region), and
    /// the window's around it: the same rect without a window frame, the device's bounds with a device frame (an empty
    /// rect at the centre for both when the padding leaves it no room). A reframed view's (`isReframed(_:)`) are both the
    /// room. The screen's is where `stagePoint(global:at:)`
    /// places the cursor; the window's is `screenRect(at:)`.
    public func rects(of view: ShownScreen) -> (window: Rect, screen: Rect) {
        if isReframed(view) {
            // Following the cursor, the window of the region fills the room, without a frame.
            let room = room
            return (room, room)
        }
        let aspect = view.region.map { $0.width / $0.height }
        if let device {
            guard let rects = StageLayout.deviceRects(contentAspect: aspect, padding: padding, outputSize: stageSize, model: device)
            else {
                let empty = Rect(x: stageSize.x / 2, y: stageSize.y / 2, width: 0, height: 0)
                return (empty, empty)
            }
            return (rects.bounds, rects.screen)
        }
        guard let output = windowFrameOutput else {
            let rect = StageLayout.screenRect(contentAspect: aspect, padding: padding, outputSize: stageSize)
            return (rect, rect)
        }
        let layout = StageLayout.windowRect(contentAspect: aspect, padding: padding, outputSize: output)
        // Output pixels to stage units: the stage is 1 tall.
        func units(_ rect: Rect) -> Rect {
            Rect(x: rect.x / output.y, y: rect.y / output.y, width: rect.width / output.y, height: rect.height / output.y)
        }
        return (units(layout.window), units(layout.screen))
    }
}

/// What `StagePoints` reads of a take whatever the document: where each of its screen tracks is (`ScreenGeometry`), from
/// its events sorted once. The same for every revision of a document of the take, so an editor makes it once, off the
/// main thread, and each revision's `StagePoints(take:document:screens:)` reads only what that document names.
public struct TakeScreens: Sendable {
    private let geometries: [String: ScreenGeometry]
    /// The source instants of the take's geometry events, in order (`StagePoints.viewChanges`).
    let geometryTimes: [HostTime]

    public init(take: TakeRecord, events: [InputEvent]) {
        let ordered = events.sortedByTime()
        geometries = Dictionary(
            take.tracks.filter(\.kind.isScreen).map { ($0.id, ScreenGeometry(track: $0, events: ordered)) },
            uniquingKeysWith: { first, _ in first })
        geometryTimes = Self.geometryTimes(of: ordered)
    }

    /// The instants of the `displayGeometry` and `windowGeometry` events of `events`, in time order, of any screen.
    static func geometryTimes(of ordered: [InputEvent]) -> [HostTime] {
        ordered.compactMap { event in
            switch event.kind {
            case .displayGeometry, .windowGeometry: event.t
            default: nil
            }
        }
    }

    /// The ratio `auto` takes for `document` (`StageLayout.contentRatio`), from the screens read once.
    public func contentRatio(take: TakeRecord, document: EditDocument) -> Double? {
        StageLayout.contentRatio(take: take, document: document) { geometry(of: $0) }
    }

    /// `StageLayout.contentRatio(project:document:)` from the screens of each take read once (`screens`, by take id):
    /// those of the take of the document's first clip (`StageLayout.contentRatioTake(of:ownTake:)`), one of `takes` (the
    /// manifest's); `nil` for a take `takes` or `screens` does not have. What an editor sizes its preview and its export by
    /// for each revision, without going over a take's events again.
    public static func contentRatio(
        of document: EditDocument, takes: [TakeRecord], ownTake: String, screens: [String: TakeScreens]
    ) -> Double? {
        let id = StageLayout.contentRatioTake(of: document, ownTake: ownTake)
        guard let take = takes.first(where: { $0.id == id }), let shown = screens[id] else { return nil }
        return shown.contentRatio(take: take, document: document)
    }

    /// The screen `track` of the take, as the take's events place it.
    func geometry(of track: TrackRecord) -> ScreenGeometry {
        geometries[track.id] ?? ScreenGeometry(track: track, events: [])
    }
}
