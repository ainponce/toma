// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// The zoom inside the screen's card of a split at one instant (1c design §5.4), in fractions of what is shown of the
/// screen (`StagePoints.screenRect(at:)`: with a macOS window frame, the whole window with its bar, as a fixed focus of
/// 1b), so it depends neither on where the card is nor on its size.
public struct CardZoomState: Equatable, Sendable {
    /// `u = ln z`, with `z` the depth: 0 at rest.
    public var logDepth: Double
    /// The centre of the crop shown: (0.5, 0.5), the screen's centre, at rest.
    public var center: SIMD2<Double>

    public init(logDepth: Double, center: SIMD2<Double>) {
        self.logDepth = logDepth
        self.center = center
    }

    /// `z`, 1 at rest: the crop shown is `1/z` of the screen on each axis, and a point `p` of the screen (in fractions
    /// of it) is drawn at `(p − center) × z + 0.5` of the card.
    public var depth: Double { exp(logDepth) }
}

/// Where the zoom inside the screen's card of a split looks, and how deep (1c design §5.4, part of `cameraLayout-1`):
/// the zoom camera of `ZoomCameraPath` over another viewport, the screen in its card, in fractions of what is shown of
/// it. Its simulation is the same `ZoomSimulation`, so:
///
/// - The same blocks of the take, `zoom.spring`, grid of 600 Hz and checkpoints every 600 steps as the stage's camera,
///   and so the same depth on every step; with `zoom.show` off, always at rest.
/// - The crop is `1/z` of the screen on each axis and its centre stays in `[1/(2z), 1 − 1/(2z)]` (`StageCrop` over the
///   unit square): the card never shows background.
/// - `fixed(x, y)` is that point. `follow` starts at the cursor's point in the screen shown (its stage point,
///   `StagePoints.stagePoint(global:at:)`, as a fraction of `StagePoints.screenRect(at:)`), then moves with the dead
///   zone, the central box of `ZoomCameraPath.deadZone` of the crop and steps of `followStep` of it. No zone to avoid:
///   in a split the camera is beside the screen, not over it. `instant` jumps.
///
/// The card has the screen's proportion, so the path does not depend on where the card is: it is simulated once for the
/// whole output, only for a document with a split (the project's layout or a block). Simulated everywhere, also where
/// another layout rules, so when the split comes back the zoom is where it has to be.
public struct CardZoomPath: Sendable {
    private let simulation: ZoomSimulation<CardViewport>

    /// `nil` when neither the project's layout nor any block is a split.
    public init?(document: EditDocument, timeMap: TimeMap, stage: StagePoints, cursor: CursorPath, take: TakeRecord) {
        guard document.camera.layout.kind == .split || document.camera.layouts.contains(where: { $0.kind == .split }) else {
            return nil
        }
        simulation = ZoomSimulation(
            document: document, timeMap: timeMap, cursor: cursor, take: take, viewport: CardViewport(stage: stage))
    }

    /// The camera on step `s` of the grid (held to the steps of the output), placed.
    public func state(atStep s: Int) -> CardZoomState {
        CardZoomState(simulation.state(atStep: s))
    }

    /// The camera at output time `τ`: the state of its step when `τ` is on the grid (`StepGrid.position(ofOutput:)`),
    /// otherwise the two around it mixed and placed at `τ`.
    public func state(atOutput τ: Int64) -> CardZoomState {
        CardZoomState(simulation.state(atOutput: τ))
    }

    /// The camera over a short span of output time, from one simulation (the motion blur's subsamples in the card, 1c
    /// design §5.4): `state(atOutput:)`, the same query over the steps kept, so with the same bits at every time.
    public struct Span: Sendable {
        private let span: ZoomSimulation<CardViewport>.Span

        fileprivate init(_ span: ZoomSimulation<CardViewport>.Span) {
            self.span = span
        }

        /// `state(atOutput: τ)`: from the steps kept for a time of the span, simulated on its own otherwise.
        public func state(atOutput τ: Int64) -> CardZoomState {
            CardZoomState(span.state(atOutput: τ))
        }
    }

    /// The camera from the step of `start` to the one after the step of `end` (held to the output's steps), simulated
    /// once from the checkpoint before them, every step kept: for spans of a few frames.
    public func span(from start: Int64, through end: Int64) -> Span {
        Span(simulation.span(from: start, through: end))
    }

    // MARK: - Internal (the state of the simulation, for the tests)

    typealias Camera = ZoomCamera

    /// The camera on step `s` (held to `0...lastStep`), from the checkpoint before it.
    func camera(atStep s: Int) -> Camera {
        simulation.camera(atStep: s)
    }

    /// The camera on step `s` (held to `0...lastStep`) simulated from output 0, without the checkpoints.
    func cameraSimulatedFromStart(atStep s: Int) -> Camera {
        simulation.cameraSimulatedFromStart(atStep: s)
    }

    /// `state(atStep: s)` simulated from output 0, without the checkpoints.
    func stateSimulatedFromStart(atStep s: Int) -> CardZoomState {
        CardZoomState(simulation.stateSimulatedFromStart(atStep: s))
    }
}

extension CardZoomState {
    /// A camera `ZoomSimulation` placed over the card.
    fileprivate init(_ placed: ZoomPlacement) {
        self.init(logDepth: placed.logDepth, center: placed.center)
    }
}

/// The screen in its card, in fractions of what is shown of it: what `CardZoomPath` looks over. The screen is the whole
/// viewport, so a fixed focus is its own point and the crop keeps to the unit square; nothing else is kept off the
/// cursor.
struct CardViewport: ZoomViewport {
    let size = SIMD2<Double>(1, 1)
    private let stage: StagePoints

    init(stage: StagePoints) {
        self.stage = stage
    }

    func screen(at host: HostTime?) -> Rect {
        Rect(x: 0, y: 0, width: 1, height: 1)
    }

    func cursor(global: SIMD2<Double>, at host: HostTime) -> SIMD2<Double>? {
        guard let point = stage.stagePoint(global: global, at: host), let rect = stage.screenRect(at: host) else { return nil }
        return (point - SIMD2(rect.x, rect.y)) / SIMD2(rect.width, rect.height)
    }

    func cleared(
        _ target: SIMD2<Double>, cursor point: SIMD2<Double>, depth: Double, atOutput τ: Int64, host: HostTime
    ) -> SIMD2<Double> {
        target
    }
}
