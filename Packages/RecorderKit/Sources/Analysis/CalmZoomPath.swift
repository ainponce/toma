// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// The calm zoom at one instant (phase 3 design §6, `calmZoom-1`): what a calm block (highlight, dim or loupe) points at
/// while the picture does not move, in stage units (the stage is 1 tall), so it does not depend on the size the output
/// is drawn at.
public struct CalmZoomState: Equatable, Sendable {
    /// The block's, or that of the last one left while it fades.
    public var mode: ZoomMode
    /// How much of the effect is seen, from 0 to 1 (never 0: there is no state then).
    public var amount: Double
    /// The depth of the instant, at least 1: it goes from 1 to `blockDepth` and back with the spring, as the classic
    /// camera's would. The focus is the stage over it.
    public var depth: Double
    /// The depth of the block, or of the last one left while it fades: the depth the focus is placed at, and the loupe's
    /// magnification.
    public var blockDepth: Double
    /// The focus's centre, placed with `StageCrop` at `blockDepth` over the screen's rect of the instant: where the
    /// classic camera's crop would be at that depth.
    public var center: SIMD2<Double>
    /// The block's lens (`ZoomRegion.resolvedLoupe`), or that of the last one left while it fades.
    public var loupe: LoupeStyle

    public init(
        mode: ZoomMode, amount: Double, depth: Double, blockDepth: Double, center: SIMD2<Double>, loupe: LoupeStyle
    ) {
        self.mode = mode
        self.amount = amount
        self.depth = depth
        self.blockDepth = blockDepth
        self.center = center
        self.loupe = loupe
    }

    /// The focus on a stage of `stageSize` (in stage units, `StagePoints.stageSize`): `center ± stageSize / (2 depth)`,
    /// the whole stage about `center` at depth 1, what the classic crop would show at `blockDepth`.
    public func focus(stageSize: SIMD2<Double>) -> Rect {
        let half = stageSize / depth / 2
        return Rect(x: center.x - half.x, y: center.y - half.y, width: 2 * half.x, height: 2 * half.y)
    }
}

/// What the calm blocks of the take point at, and how much (phase 3 design §6, plan 3b decisions 3 to 5), in output time
/// and stage units:
///
/// - The focus is the zoom camera of `ZoomCameraPath` (the same `ZoomSimulation` over the stage, with its viewport,
///   spring, dead zone, cursor, bubble, window of the reframe and instant jumps) simulated over the calm blocks alone
///   (`ZoomSelection.calm`), so it is what the classic zoom would show with that depth and focus, and changing between
///   calm modes does not move it. Two rules of its own keep the focus from appearing at the stage's centre and
///   travelling: outside every block the centre stays where it is, and on entering a block from outside every one it
///   jumps to its target (the depth goes on with the spring, but into an instant block). Its centre is placed with
///   `StageCrop` at the depth of the block (that of the last one left while it fades); its size is the stage over the
///   depth of the instant, so Highlight and Dim close on the focus from the whole stage and the loupe magnifies from 1×
///   to the block's depth, without moving.
/// - How much is seen (`amount`): the step response of `zoom.spring` (`stepResponse(of:)`) summed over the edges of each
///   run of calm blocks that touch (+1 on entering, −1 on leaving), from the last instant edge, which sets its value at
///   once (1 entering, 0 leaving), held from 0 to 1 and mixed linearly between steps. Two calm blocks that touch are one
///   run, which does not fade between them; where their modes differ, the mode changes on the step of the border.
/// - The mode, the lens and the block's depth are those of the block of the step, or of the last one left while it
///   fades; where `amount` is 0 there is no state.
///
/// Built with `MotionPaths`, off the main thread, after an edit from the path before it (`MotionPaths.calmZoom`), with the
/// bits of building it from nothing. In a calm block the stage's and the card's cameras are at rest
/// (`ZoomCameraPath`), so nothing of a calm block is ever blurred by the motion.
public struct CalmZoomPath: Sendable {
    /// The look of the focus, its entry and exit, Highlight and Dim; the loupe's lens is `loupe-1`.
    public static let id = "calmZoom-1"

    /// The simulation of the calm blocks alone.
    let camera: ZoomCameraPath
    /// The calm blocks, in output order: `camera`'s.
    private let blocks: [ZoomBlock]
    /// The edges of the runs of calm blocks that touch, in output order (strictly: runs that do not touch have a step
    /// between them).
    private let edges: [Edge]
    /// `stepResponse(of: zoom.spring)`.
    private let response: [Double]

    /// An edge of a run of calm blocks that touch: the first step of its first block, or the step after its last block.
    private struct Edge: Sendable {
        var step: Int
        var entering: Bool
        /// The block on its inner side is instant: the amount is set at once.
        var instant: Bool
    }

    /// `nil` without a calm block of the take or with `zoom.show` off. `cameraReadable` and `reframe`: as for
    /// `ZoomCameraPath`, the same camera.
    public init?(
        document: EditDocument, timeMap: TimeMap, stage: StagePoints, cursor: CursorPath, take: TakeRecord,
        cameraReadable: Bool = true, reframe: ReframePath? = nil
    ) {
        guard Self.hasCalmBlocks(document, take: take, timeMap: timeMap) else { return nil }
        self.init(
            document: document, timeMap: timeMap, stage: stage, cursor: cursor, take: take, after: nil, changedFrom: nil,
            layouts: ZoomCameraPath.layouts(of: document, take: take, timeMap: timeMap, cameraReadable: cameraReadable),
            reframe: reframe)
    }

    /// The path of the same take after an edit (`MotionPaths.init(take:events:document:after:)`): bit for bit the one
    /// built from nothing, from `old`'s camera as `ZoomCameraPath` keeps it, with the stage's camera's `changed` and
    /// `layouts`.
    init?(
        document: EditDocument, timeMap: TimeMap, stage: StagePoints, cursor: CursorPath, take: TakeRecord,
        after old: CalmZoomPath?, changedFrom changed: Int?, layouts: LayoutTimeline, reframe: ReframePath?
    ) {
        guard Self.hasCalmBlocks(document, take: take, timeMap: timeMap) else { return nil }
        camera = ZoomCameraPath(
            document: document, timeMap: timeMap, stage: stage, cursor: cursor, take: take, after: old?.camera,
            changedFrom: changed, layouts: layouts, reframe: reframe, selecting: .calm)
        blocks = camera.blocks
        edges = Self.edges(of: blocks)
        response = Self.stepResponse(of: document.zoom.spring)
    }

    /// Whether the take has a calm block on the grid, its overlaps settled, with `zoom.show` on.
    private static func hasCalmBlocks(_ document: EditDocument, take: TakeRecord, timeMap: TimeMap) -> Bool {
        document.zoom.show
            && document.zoom.regions.contains { $0.take == take.id && $0.resolvedMode(auto: document.zoom.auto).isCalm }
            && ZoomBlock.blocks(of: document.zoom, take: take.id, timeMap: timeMap).contains { ZoomSelection.calm.selects($0) }
    }

    /// The calm zoom at output time `τ`: on the grid, its step's; between two steps, the amount and the camera mixed
    /// linearly, with the block of the later step. Before the output, its first step's; after its end, its last step's.
    /// `nil` where the amount is 0.
    public func state(atOutput τ: Int64) -> CalmZoomState? {
        let (s, fraction) = StepGrid.position(ofOutput: τ)
        let amount: Double
        let step: Int
        if fraction > 0, s >= 0, s < camera.lastStep {
            let a = self.amount(atStep: s), b = self.amount(atStep: s + 1)
            amount = a + (b - a) * fraction
            step = s + 1
        } else {
            step = min(max(s, 0), camera.lastStep)
            amount = self.amount(atStep: step)
        }
        guard amount > 0, let block = block(atStep: step) else { return nil }
        let placed = camera.state(atOutput: τ, placedAt: block.depth)
        return CalmZoomState(
            mode: block.mode, amount: amount, depth: placed.depth, blockDepth: block.depth, center: placed.center,
            loupe: block.loupe)
    }

    // MARK: - Internal

    /// How many steps the step response is read for before it is 1: 10 s.
    static let responseSteps = 10 * StepGrid.rate

    /// The response of `spring` (through `StepGrid.stable(_:)`) to a step from 0 to 1 on the grid: the value `k` steps
    /// after the step of the edge, the spring having moved once on it (as a camera moves on the first step of its block),
    /// for `k` from 0 to `responseSteps − 1`; 1 from there on.
    static func stepResponse(of spring: SpringSpec) -> [Double] {
        let spring = StepGrid.stable(spring)
        var x = 0.0, v = 0.0
        return (0..<responseSteps).map { _ in
            StepGrid.spring(&x, &v, target: 1, spring)
            return x
        }
    }

    /// How much is seen on step `s` (0 to 1): the edges up to it from the last one settled (instant, or `responseSteps`
    /// or more before it), which gives 1 after an entry and 0 after an exit, then each later one's response, in order.
    func amount(atStep s: Int) -> Double {
        var low = 0, high = edges.count
        while low < high {
            let mid = (low + high) / 2
            if edges[mid].step <= s { low = mid + 1 } else { high = mid }
        }
        let last = low - 1
        guard last >= 0 else { return 0 }
        var settled = last
        while settled >= 0, !edges[settled].instant, s - edges[settled].step < response.count { settled -= 1 }
        var value = settled >= 0 && edges[settled].entering ? 1.0 : 0.0
        for edge in edges[(settled + 1)..<(last + 1)] {
            let r = response[s - edge.step]
            value = edge.entering ? value + r : value - r
        }
        return min(max(value, 0), 1)
    }

    /// The block of step `s`: the one it is in, or the last one before it; `nil` before the first.
    private func block(atStep s: Int) -> ZoomBlock? {
        var low = 0, high = blocks.count
        while low < high {
            let mid = (low + high) / 2
            if blocks[mid].steps.lowerBound <= s { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? blocks[low - 1] : nil
    }

    /// The edges of the runs of `blocks` (in output order, never overlapping) that touch: a block that starts on the step
    /// the one before it ends goes on its run.
    private static func edges(of blocks: [ZoomBlock]) -> [Edge] {
        var edges: [Edge] = []
        for (k, block) in blocks.enumerated() {
            if k > 0, blocks[k - 1].steps.upperBound == block.steps.lowerBound { continue }
            if k > 0 { edges.append(Edge(step: blocks[k - 1].steps.upperBound, entering: false, instant: blocks[k - 1].instant)) }
            edges.append(Edge(step: block.steps.lowerBound, entering: true, instant: block.instant))
        }
        if let last = blocks.last { edges.append(Edge(step: last.steps.upperBound, entering: false, instant: last.instant)) }
        return edges
    }
}
