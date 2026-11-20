// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// The calm zoom at one instant (phase 3 design §6, `calmZoom-1`): what a calm block (highlight, dim or loupe) points at
/// while the picture does not move, in stage units (the stage is 1 tall), so it does not depend on the size the output
/// is drawn at.
public struct CalmZoomState: Equatable, Sendable {
    /// The block's, or that of the last one left while it fades.
    public var mode: ZoomMode
    /// How much of the effect is seen, from `CalmAmount.unseen` (1/255) to 1: below it there is no state.
    public var amount: Double
    /// The depth of the instant, at least 1: it goes from 1 to `blockDepth` and back with the spring, as the classic
    /// camera's would. The focus is the stage over it, and the loupe magnifies by it.
    public var depth: Double
    /// The depth of the block, or of the last one left while it fades.
    public var blockDepth: Double
    /// The focus's centre, placed with `StageCrop` over the screen's rect of the instant at the larger of `depth` and the
    /// depth of the block it is placed for (`blockDepth`; across a gap the next block goes on from, that block's): where
    /// the classic camera's crop would be at that depth once it has settled.
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
    /// the whole stage about `center` at depth 1, what the classic crop would show once settled.
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
///   travelling, and from jumping where it is seen: outside every block the centre stays where it is, and on entering a
///   block from outside every one it jumps to its target only when nothing of the blocks before is seen any more
///   (`amount` on the step before below `CalmAmount.unseen`, 1/255), and otherwise goes there with the spring from where
///   it stayed (the depth goes on with the spring, but into an instant block, where both jump). Its centre is placed with
///   `StageCrop` at the larger of the depth of the instant and that of the block (that of the last one left while it
///   fades, or across a gap that the next block goes on from without a jump, the next one's): the block's while it closes
///   in, while it is there and while it fades, so the focus does not move, and between two blocks of other depths that
///   touch or nearly touch, the instant's, which goes from one to the other with the spring, so the focus does not jump
///   there. One jump is left, accepted: a calm block shorter than about 0.5 s that ends before its centre settles,
///   beside one of another depth, near a screen's edge; where the gap after it starts, the centre still on its way is
///   placed at the next block's depth at once, which can move it (66 px at 720p with 4×, 2× for 0.2 s and 4× at an edge).
///   Its size is the stage over the depth of the instant, so Highlight and Dim close on the focus from the whole stage
///   and the loupe magnifies from 1× to the block's depth, without moving.
/// - How much is seen (`amount`): the step response of `zoom.spring` (`stepResponse(of:)`) summed over the edges of each
///   run of calm blocks that touch (+1 on entering, −1 on leaving), from the last instant edge, which sets its value at
///   once (1 entering, 0 leaving), held from 0 to 1 and mixed linearly between steps. Two calm blocks that touch are one
///   run, which does not fade between them; where their modes differ, the mode changes on the step of the border.
/// - The mode, the lens and the block's depth are those of the block of the step, or of the last one left while it
///   fades. There is no state where less than `CalmAmount.unseen` (1/255) is seen, nor, after a run, from the first step
///   it is below that to the next run (`CalmAmount.isSeen(atStep:)`): the effect is drawn only where it can be seen,
///   and one that fades with an underdamped spring does not come and go.
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
    /// How much is seen on each step.
    private let seen: CalmAmount

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
        seen = CalmAmount(blocks: blocks, spring: document.zoom.spring)
    }

    /// Whether the take has a calm block on the grid, its overlaps settled, with `zoom.show` on.
    private static func hasCalmBlocks(_ document: EditDocument, take: TakeRecord, timeMap: TimeMap) -> Bool {
        document.zoom.show
            && document.zoom.regions.contains { $0.take == take.id && $0.resolvedMode(auto: document.zoom.auto).isCalm }
            && ZoomBlock.blocks(of: document.zoom, take: take.id, timeMap: timeMap).contains { ZoomSelection.calm.selects($0) }
    }

    /// The calm zoom at output time `τ`: on the grid, its step's; between two steps, the amount and the camera mixed
    /// linearly, with the block of the later step, and none once the step before has faded. Before the output, its
    /// first step's; after its end, its last step's. `nil` where it is not seen (`CalmAmount.isSeen(atStep:)`).
    public func state(atOutput τ: Int64) -> CalmZoomState? {
        let (s, fraction) = StepGrid.position(ofOutput: τ)
        let amount: Double
        let step: Int
        if fraction > 0, s >= 0, s < camera.lastStep {
            guard !seen.hasFaded(atStep: s) else { return nil }
            let a = self.amount(atStep: s), b = self.amount(atStep: s + 1)
            amount = a + (b - a) * fraction
            step = s + 1
        } else {
            step = min(max(s, 0), camera.lastStep)
            guard !seen.hasFaded(atStep: step) else { return nil }
            amount = self.amount(atStep: step)
        }
        guard amount >= CalmAmount.unseen, let k = blockIndex(atStep: step) else { return nil }
        let block = blocks[k]
        // Across a gap the next block goes on from without a jump, the focus is placed for it already.
        let placing = step >= block.steps.upperBound && k + 1 < blocks.count && !blocks[k + 1].focusJumpsIn
            ? blocks[k + 1] : block
        let placed = camera.state(atOutput: τ, placedAtLeast: placing.depth)
        return CalmZoomState(
            mode: block.mode, amount: amount, depth: placed.depth, blockDepth: block.depth, center: placed.center,
            loupe: block.loupe)
    }

    // MARK: - Internal

    /// How many steps the step response is read for before it is 1: 10 s.
    static var responseSteps: Int { CalmAmount.responseSteps }

    /// The response of `spring` to a step from 0 to 1 on the grid (`CalmAmount.stepResponse(of:)`).
    static func stepResponse(of spring: SpringSpec) -> [Double] {
        CalmAmount.stepResponse(of: spring)
    }

    /// How much is seen on step `s` (0 to 1), `CalmAmount.amount(atStep:)`.
    func amount(atStep s: Int) -> Double {
        seen.amount(atStep: s)
    }

    /// The index of the block of step `s`: the one it is in, or the last one before it; `nil` before the first.
    private func blockIndex(atStep s: Int) -> Int? {
        var low = 0, high = blocks.count
        while low < high {
            let mid = (low + high) / 2
            if blocks[mid].steps.lowerBound <= s { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }
}

/// How much of the calm zoom is seen on each step (plan 3b decision 5), from the calm blocks on the grid and
/// `zoom.spring`: the step response of the spring (`stepResponse(of:)`) summed over the edges of each run of calm blocks
/// that touch (+1 on entering, −1 on leaving), from the last edge settled (instant, which sets its value at once, or
/// `responseSteps` or more before), held from 0 to 1; and where it is seen (`isSeen(atStep:)`). What `CalmZoomPath`
/// draws, and what its simulation reads to tell whether the focus can jump into a block (`marked(_:spring:)`).
struct CalmAmount: Sendable {
    /// How many steps the step response is read for before it is 1: 10 s.
    static let responseSteps = 10 * StepGrid.rate
    /// Below this much, nothing of the calm zoom is seen (less than one level of 8 bits): there is no state, and the focus
    /// can jump into a block there (plan 3b decisions 4 and 5, as the controller ruled on Z2).
    static let unseen = 1.0 / 255

    /// The edges of the runs, in output order (strictly: runs that do not touch have a step between them).
    private let edges: [Edge]
    /// `stepResponse(of: spring)`.
    private let response: [Double]
    /// For each edge that leaves a run, the first step from it on which less than `unseen` is seen, when that is before
    /// the next run; `nil` for the others.
    private let fades: [Int?]

    /// An edge of a run of calm blocks that touch: the first step of its first block, or the step after its last block.
    private struct Edge: Sendable {
        var step: Int
        var entering: Bool
        /// The block on its inner side is instant: the amount is set at once.
        var instant: Bool
    }

    /// `blocks`: the calm ones, in output order, never overlapping; a block that starts on the step the one before it
    /// ends goes on its run.
    init(blocks: [ZoomBlock], spring: SpringSpec) {
        var edges: [Edge] = []
        for (k, block) in blocks.enumerated() {
            if k > 0, blocks[k - 1].steps.upperBound == block.steps.lowerBound { continue }
            if k > 0 { edges.append(Edge(step: blocks[k - 1].steps.upperBound, entering: false, instant: blocks[k - 1].instant)) }
            edges.append(Edge(step: block.steps.lowerBound, entering: true, instant: block.instant))
        }
        if let last = blocks.last { edges.append(Edge(step: last.steps.upperBound, entering: false, instant: last.instant)) }
        let response = Self.stepResponse(of: spring)
        self.edges = edges
        self.response = response
        // At most `responseSteps` after it leaves, the run's edges have settled to 0.
        fades = edges.indices.map { i in
            guard !edges[i].entering else { return nil }
            let next = i + 1 < edges.count ? edges[i + 1].step : Int.max
            var s = edges[i].step
            while s < next, s <= edges[i].step + Self.responseSteps,
                Self.amount(atStep: s, edges: edges, response: response) >= Self.unseen
            {
                s += 1
            }
            return s < next ? s : nil
        }
    }

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
        Self.amount(atStep: s, edges: edges, response: response)
    }

    /// Whether the effect is seen on step `s`: at least `unseen` of it, and not after its run faded (`hasFaded(atStep:)`).
    func isSeen(atStep s: Int) -> Bool {
        !hasFaded(atStep: s) && amount(atStep: s) >= Self.unseen
    }

    /// Whether step `s` is after a run, from the first step on which less than `unseen` of it was seen: from there to the
    /// next run nothing is drawn, even where an underdamped spring brings some of it back.
    func hasFaded(atStep s: Int) -> Bool {
        let last = Self.lastEdge(atOrBefore: s, edges)
        return last.map { fades[$0].map { $0 <= s } ?? false } ?? false
    }

    /// The index of the last of `edges` at or before step `s`; `nil` before the first.
    private static func lastEdge(atOrBefore s: Int, _ edges: [Edge]) -> Int? {
        var low = 0, high = edges.count
        while low < high {
            let mid = (low + high) / 2
            if edges[mid].step <= s { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }

    private static func amount(atStep s: Int, edges: [Edge], response: [Double]) -> Double {
        guard let last = lastEdge(atOrBefore: s, edges) else { return 0 }
        var settled = last
        while settled >= 0, !edges[settled].instant, s - edges[settled].step < response.count { settled -= 1 }
        var value = settled >= 0 && edges[settled].entering ? 1.0 : 0.0
        for edge in edges[(settled + 1)..<(last + 1)] {
            let r = response[s - edge.step]
            value = edge.entering ? value + r : value - r
        }
        return min(max(value, 0), 1)
    }

    /// `blocks` (the calm ones, as for `init(blocks:spring:)`) with `ZoomBlock.focusJumpsIn` set: on each that starts a
    /// run, whether nothing is seen on the step before it (`isSeen(atStep:)`), so nothing of the blocks before shows the
    /// jump; on the others, which are entered from the block before, `false`. Read from the blocks before each one alone.
    static func marked(_ blocks: [ZoomBlock], spring: SpringSpec) -> [ZoomBlock] {
        let seen = CalmAmount(blocks: blocks, spring: spring)
        return blocks.enumerated().map { k, block in
            var block = block
            let startsARun = k == 0 || blocks[k - 1].steps.upperBound != block.steps.lowerBound
            block.focusJumpsIn = startsARun && !seen.isSeen(atStep: block.steps.lowerBound - 1)
            return block
        }
    }
}
