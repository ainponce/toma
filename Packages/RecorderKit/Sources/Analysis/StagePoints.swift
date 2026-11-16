// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import ProjectFormat

/// Where things of a take are on the stage, in stage units: the stage is 1 tall and `aspect.ratio` wide, origin at
/// its top left, so a position does not depend on the size the output is drawn at (design §8.1 and §8.6).
///
/// The screen shown at a source instant is the one the render shows (`FrameEvaluator`): the take's track of
/// `screens.initial`, or of the last `screens.changes` of the take at or before the instant; none without one, or for
/// a track the take does not have or that is not a screen. What is shown of it, and where, is `ScreenGeometry`; its
/// rect is `StageLayout.screenRect` inside the document's padding, as the render places it.
public struct StagePoints: Sendable {
    /// Width over height of the stage: the document's aspect.
    private let ratio: Double
    /// The document's padding, as a fraction of the stage's width.
    private let padding: Double
    /// The screen track of the take at its start, and from each of its changes on (in time order).
    private let initialScreen: String?
    private let screenChanges: [(t: HostTime, track: String)]
    /// Where each screen track the document names is, by ID: only the take's screen tracks.
    private let screens: [String: ScreenGeometry]

    public init(take: TakeRecord, events: [InputEvent], document: EditDocument) {
        ratio = document.aspect.ratio
        padding = document.style.padding
        let ordered = events.sortedByTime()
        let initialScreen = document.screens.initial[take.id]
        self.initialScreen = initialScreen
        let changes = document.screens.changes.filter { $0.take == take.id }
        screenChanges = changes.enumerated()
            .sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }
            .map { ($0.element.t, $0.element.track) }
        var screens: [String: ScreenGeometry] = [:]
        for id in [initialScreen].compactMap({ $0 }) + changes.map(\.track) where screens[id] == nil {
            guard let track = take.track(id), track.kind.isScreen else { continue }
            screens[id] = ScreenGeometry(track: track, events: ordered)
        }
        self.screens = screens
    }

    /// The stage's width and height: `aspect.ratio` and 1.
    public var stageSize: SIMD2<Double> { SIMD2(ratio, 1) }

    /// Where `global` (in global points) is on the stage at source instant `host`: placed in the screen's rect as it is
    /// in the region the screen shows. `nil` off that region (its far edges are out, as for the drawn cursor), while a
    /// window is not on screen, for a screen without a usable frame, and with no screen shown.
    public func stagePoint(global: SIMD2<Double>, at host: HostTime) -> SIMD2<Double>? {
        guard let view = shown(at: host), view.onScreen, let region = view.region else { return nil }
        let point = CGPoint(x: global.x, y: global.y)
        guard CursorGeometry.contains(point, region) else { return nil }
        let rect = rect(of: view)
        return SIMD2(rect.x, rect.y) + CursorGeometry.normalized(point, in: region) * SIMD2(rect.width, rect.height)
    }

    /// The rect of the screen shown at source instant `host`, in stage units; `nil` with no screen shown.
    public func screenRect(at host: HostTime) -> Rect? {
        shown(at: host).map(rect(of:))
    }

    /// What is shown of the screen shown at `host`.
    private func shown(at host: HostTime) -> ShownScreen? {
        var low = 0, high = screenChanges.count
        while low < high {
            let mid = (low + high) / 2
            if screenChanges[mid].t <= host { low = mid + 1 } else { high = mid }
        }
        guard let track = low > 0 ? screenChanges[low - 1].track : initialScreen else { return nil }
        return screens[track]?.shown(at: host)
    }

    /// The screen's rect for `view`: of the region's aspect (of the whole room inside the padding without a region).
    private func rect(of view: ShownScreen) -> Rect {
        StageLayout.screenRect(contentAspect: view.region.map { $0.width / $0.height }, padding: padding, outputSize: stageSize)
    }
}
