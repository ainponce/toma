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
/// its own size (`FrameEvaluator`), so even a deep zoom shows no strip of background beside it.
public struct StagePoints: Sendable {
    /// The output the window frame is placed in: the document's aspect, 1080 px on its shorter side.
    private static let windowFrameShortSide = 1080

    /// Width over height of the stage: the document's aspect.
    private let ratio: Double
    /// The document's padding, as a fraction of the stage's width.
    private let padding: Double
    /// With a macOS window frame, the output its rects are worked out in; `nil` without a frame.
    private let windowFrameOutput: SIMD2<Double>?
    /// The screen track of the take at its start, and from each of its changes on (in time order).
    private let initialScreen: String?
    private let screenChanges: [(t: HostTime, track: String)]
    /// Where each screen track the document names is, by ID: only the take's screen tracks.
    private let screens: [String: ScreenGeometry]
    /// The screen tracks of `screens`, each once, in the order the document names them: `screens.initial`, then
    /// `screens.changes` as listed. Those a frame can show.
    public let screenTrackIDs: [String]

    public init(take: TakeRecord, events: [InputEvent], document: EditDocument) {
        let ordered = events.sortedByTime()
        self.init(take: take, document: document) { ScreenGeometry(track: $0, events: ordered) }
    }

    /// The same as `init(take:events:document:)`, from the take's screens read once (`TakeScreens`): it reads only what
    /// the document names, so an editor makes one for each revision without going over the take's events again.
    public init(take: TakeRecord, document: EditDocument, screens: TakeScreens) {
        self.init(take: take, document: document) { screens.geometry(of: $0) }
    }

    private init(take: TakeRecord, document: EditDocument, geometry: (TrackRecord) -> ScreenGeometry) {
        ratio = document.aspect.ratio
        padding = document.style.padding
        switch document.style.frame {
        // A device is measured as no frame until the render draws it (plan decision 10).
        case .none, .device:
            windowFrameOutput = nil
        case .macWindow:
            windowFrameOutput = SIMD2<Double>(StageLayout.outputSize(aspect: document.aspect, shortSide: Self.windowFrameShortSide))
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

    /// The stage's width and height: `aspect.ratio` and 1.
    public var stageSize: SIMD2<Double> { SIMD2(ratio, 1) }

    /// Where `global` (in global points) is on the stage at source instant `host`: placed in the screen's rect as it is
    /// in the region the screen shows (under the bar, with a window frame). `nil` off that region (its far edges are out,
    /// as for the drawn cursor), while a window is not on screen, for a screen without a usable frame, and with no screen
    /// shown.
    public func stagePoint(global: SIMD2<Double>, at host: HostTime) -> SIMD2<Double>? {
        guard let view = shownScreen(at: host)?.view, view.onScreen, let region = view.region else { return nil }
        let point = CGPoint(x: global.x, y: global.y)
        guard CursorGeometry.contains(point, region) else { return nil }
        let rect = rects(of: view).screen
        return SIMD2(rect.x, rect.y) + CursorGeometry.normalized(point, in: region) * SIMD2(rect.width, rect.height)
    }

    /// The rect of the screen shown at source instant `host`, in stage units: with a window frame, the whole window, bar
    /// included (the `R` the zoom's camera keeps to, design §7.4). `nil` with no screen shown.
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
    /// the window's around it: the same rect without a window frame. The screen's is where `stagePoint(global:at:)` places
    /// the cursor; the window's is `screenRect(at:)`.
    public func rects(of view: ShownScreen) -> (window: Rect, screen: Rect) {
        let aspect = view.region.map { $0.width / $0.height }
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

    public init(take: TakeRecord, events: [InputEvent]) {
        let ordered = events.sortedByTime()
        geometries = Dictionary(
            take.tracks.filter(\.kind.isScreen).map { ($0.id, ScreenGeometry(track: $0, events: ordered)) },
            uniquingKeysWith: { first, _ in first })
    }

    /// The screen `track` of the take, as the take's events place it.
    func geometry(of track: TrackRecord) -> ScreenGeometry {
        geometries[track.id] ?? ScreenGeometry(track: track, events: [])
    }
}
