// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// A stretch of the output where one layout rules: a block of the camera track, or the project's layout between blocks
/// (1c design §5.1 and §5.5).
public struct LayoutSpan: Equatable, Sendable {
    /// The block's id; `nil` for the project's layout.
    public var blockID: String?
    /// The layout shown: the block's or the project's, or `screenOnly` where the camera is not shown (`camera.show` off, or
    /// a camera that cannot be read) and the layout needs it.
    public var kind: LayoutKind
    /// The split's settings, kept whatever the kind.
    public var split: SplitLayout?
    /// The block's own bubble (`LayoutBlock.bubble`), kept whatever the kind; `nil` for the take's bubble.
    public var bubbleStyle: CameraStyle?
    /// Whether the layout jumps at the span's edges instead of blending with the spring: the block's `instant`.
    public var instant: Bool
    /// In output nanoseconds.
    public var output: Range<Int64>

    public init(
        blockID: String? = nil, kind: LayoutKind, split: SplitLayout? = nil, bubbleStyle: CameraStyle? = nil, instant: Bool,
        output: Range<Int64>
    ) {
        self.blockID = blockID
        self.kind = kind
        self.split = split
        self.bubbleStyle = bubbleStyle
        self.instant = instant
        self.output = output
    }
}

/// What is live at an output instant, which the layouts' geometry is drawn from: the output's size, the style's stage,
/// the screen's aspect as it animates (1b §7.6; with a macOS window frame, the whole window with its bar) and the take's
/// bubble as it is presented (`CameraBubble`, its spring under way included; `nil` where it is not drawn).
public struct LayoutInputs: Sendable {
    /// In pixels.
    public var output: SIMD2<Double>
    /// `StageStyle.padding`.
    public var padding: Double
    /// `StageStyle.cornerRadius`.
    public var cornerRadius: Double
    /// Width over height; `nil` without a screen.
    public var screenAspect: Double?
    public var takeBubble: CameraFrame?
    /// `CameraPlan.sizeReference`, which a Bubble block's style is measured against.
    public var sizeReference: SizeReference

    public init(
        output: SIMD2<Double>, padding: Double, cornerRadius: Double, screenAspect: Double? = nil, takeBubble: CameraFrame? = nil,
        sizeReference: SizeReference
    ) {
        self.output = output
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.screenAspect = screenAspect
        self.takeBubble = takeBubble
        self.sizeReference = sizeReference
    }
}

/// Which layout rules at each output instant of a take, and what is shown as they change (1c design §5.1, §5.3 and §5.5),
/// part of `cameraLayout-1`.
///
/// - The spans: the take's blocks of `camera.layouts` in their output ranges (`TimeMap.outputRange(ofSource:take:)`, cuts
///   closed, as the zoom's blocks: plan decision 9), so a block entirely in a cut is not shown and comes back with its
///   source; the project's layout (`camera.layout`) in the gaps. They cover the output, in order. Blocks can overlap: the
///   track stops a new block, a move or a trim at the blocks it shows, but a block hidden whole in a cut takes no room
///   there (as on the Zoom track), so a block placed across the closed cut can hold its source and overlap it once the
///   stretch is recovered; and so can blocks in a document edited by hand. Where blocks overlap, the one that starts
///   first rules: one that starts inside the one before it starts where that one ends, and one entirely inside it is not
///   shown. Two blocks at most 1 ns apart touch, and a block that ends at most 1 ns before the end of the output reaches
///   it: a block's end goes back to the source as the source of its last nanosecond and 1 ns more (plan decision 9),
///   which at a speed above 1 maps back 1 ns short. This placement is `placedBlocks(of:take:timeMap:)`, which the
///   editor's Camera track uses too. With `camera.show` off, or a camera that cannot be read (plan decision 40), every
///   span whose layout needs the camera is `screenOnly`; the blocks stay in the document.
/// - The borders: the start of every span but the first, in output time. A block that starts at output 0 is in place on
///   the first frame and one that ends at the output's end never leaves. At a border, what is shown goes from what was
///   shown to the new span's geometry along `p`, the step response of `camera.spring` (with the design's 0.95 and 0.5 s,
///   `CameraStyleTimeline.progress`), of the time since the border: every number blended linearly (`LayoutGeometry.mix`).
///   Both ends are live: the geometry of each layout is evaluated at the instant drawn, so a bubble or a screen that moves
///   goes on moving through the transition. A border reached before the transition before it has settled starts from
///   what was shown, as `CameraStyleTimeline` does: the burst is played forward from its first border. A border at an
///   edge of an instant block jumps to the new geometry, and a burst starts there.
/// - Appearing and leaving (1c design §5.3): a part the new layout shows while nothing of it was seen starts as
///   `CameraLayoutGeometry` hides it where it goes (at 90 % of its size around its centre, its corners too, the camera
///   with that layout's border and shadow weights) and grows from there; a part the new layout hides while it is seen
///   ends so where it was seen at the border, and fades there (one already leaving goes on to where it was going), so in
///   a burst too what leaves never slides. A part that is not seen (opacity 0 or less) can be anywhere, so its place and
///   weights jump while it is not seen; what is seen never does.
/// - A span's geometry is `CameraLayoutGeometry`'s at the instant's inputs: in Bubble, the camera is the take's bubble
///   presented for the project's layout and a block's own style measured against the output (`CameraStyle
///   .frame(in:reference:)`) for a Bubble block, which, as the take's bubble in 1b, is not drawn before the camera's
///   first frame (while the take's bubble is `nil`). Opacities and the camera's border and shadow weights are kept in
///   0…1: the spring overshoots by about 10⁻⁴.
public struct LayoutTimeline: Sendable {
    /// The spans, in output order, covering the output: there is always one, the project's over `0..<0` for an empty one.
    public let spans: [LayoutSpan]
    /// No block shown and the project's layout is Bubble, as in every document of 1b: the render keeps 1b's path for it
    /// (plan decision 13), whatever `camera.show` and the camera's frames.
    public let isTrivial: Bool
    /// Some span shows a split: the zoom in its card is simulated only then.
    public let hasSplit: Bool

    private let takeID: String
    private let timeMap: TimeMap
    private let response: StepResponse

    public init(document: EditDocument, take: TakeRecord, timeMap: TimeMap, cameraReadable: Bool) {
        let camera = document.camera
        let showsCamera = camera.show && cameraReadable
        func shown(_ kind: LayoutKind) -> LayoutKind { showsCamera ? kind : .screenOnly }
        let end = max(timeMap.duration, 0)
        let kept = Self.placedBlocks(of: document, take: take.id, timeMap: timeMap)
            .map { (output: $0.output, block: camera.layouts[$0.index]) }

        let project = { (range: Range<Int64>) in
            LayoutSpan(kind: shown(camera.layout.kind), split: camera.layout.split, instant: false, output: range)
        }
        var spans: [LayoutSpan] = []
        var cursor: Int64 = 0
        for (output, block) in kept {
            if output.lowerBound > cursor { spans.append(project(cursor..<output.lowerBound)) }
            spans.append(LayoutSpan(
                blockID: block.id, kind: shown(block.kind), split: block.split, bubbleStyle: block.bubble?.style,
                instant: block.instant, output: output))
            cursor = output.upperBound
        }
        if cursor < end || spans.isEmpty { spans.append(project(cursor..<end)) }

        self.spans = spans
        isTrivial = camera.layout.kind == .bubble && spans.allSatisfy { $0.blockID == nil }
        hasSplit = spans.contains { $0.kind == .split }
        takeID = take.id
        self.timeMap = timeMap
        response = StepResponse(camera.spring)
    }

    /// Whether the camera of `take` can be read (plan decision 40): some camera track has a segment that `availability`
    /// finds present (not empty nor unreadable, and its file there: `SegmentAvailability`). A take without a camera track
    /// has none to read. The one rule the render (`FrameRenderer`), the zoom's paths and the editor (`LayoutTrackRules`) go
    /// by, so they all see the same layouts.
    public static func cameraReadable(take: TakeRecord, availability: (SegmentRecord) -> SegmentAvailability) -> Bool {
        take.tracks.contains { $0.kind == .camera && $0.segments.contains { availability($0) == .present } }
    }

    /// The blocks of take `take` of `document` where the output shows them, as the type's notes place them: each one's index
    /// in `camera.layouts` and its output range, in output order (the document's among those that start together), never
    /// overlapping. A block that shows nothing (in a cut, or entirely inside the one before it) is not there.
    public static func placedBlocks(
        of document: EditDocument, take: String, timeMap: TimeMap
    ) -> [(index: Int, output: Range<Int64>)] {
        let end = max(timeMap.duration, 0)
        var placed: [(index: Int, output: Range<Int64>)] = []
        for (index, block) in document.camera.layouts.enumerated() where block.take == take && block.start < block.end {
            guard let output = timeMap.outputRange(ofSource: block.start..<block.end, take: take) else { continue }
            let clamped = max(output.lowerBound, 0)..<min(max(output.upperBound, 0), end)
            if !clamped.isEmpty { placed.append((index, clamped)) }
        }
        placed.sort { ($0.output.lowerBound, $0.index) < ($1.output.lowerBound, $1.index) }
        var kept: [(index: Int, output: Range<Int64>)] = []
        for var entry in placed {
            if let last = kept.last {
                let start = max(entry.output.lowerBound, last.output.upperBound)
                guard start < entry.output.upperBound else { continue }
                entry.output = start..<entry.output.upperBound
                if start - last.output.upperBound <= touching { kept[kept.count - 1].output = last.output.lowerBound..<start }
            }
            kept.append(entry)
        }
        if let last = kept.last, end - last.output.upperBound <= touching {
            kept[kept.count - 1].output = last.output.lowerBound..<end
        }
        return kept
    }

    /// Where the output shows each block of `camera.layouts` of `document`, every take's, as `placedBlocks(of:take:timeMap:)`
    /// places them, in the order of the document; `nil` for one that shows nothing.
    public static func blockOutputs(of document: EditDocument, timeMap: TimeMap) -> [Range<Int64>?] {
        var outputs = [Range<Int64>?](repeating: nil, count: document.camera.layouts.count)
        for take in Set(document.camera.layouts.map(\.take)) {
            for placed in placedBlocks(of: document, take: take, timeMap: timeMap) { outputs[placed.index] = placed.output }
        }
        return outputs
    }

    /// The span that rules at output time `τ`: the first one before the output, the last one from its end on.
    public func span(atOutput τ: Int64) -> LayoutSpan {
        spans[index(atOutput: τ)]
    }

    /// What is shown at output time `τ`, with what is live then (see the type's notes).
    public func geometry(atOutput τ: Int64, _ inputs: LayoutInputs) -> LayoutGeometry {
        let burst = burst(atOutput: τ)
        // The live geometry of the spans the burst reads, from the one before its start on.
        let base = max(burst.first - 2, 0)
        let live = spans[base...burst.last].map { layoutGeometry($0, inputs) }
        func geometry(_ i: Int) -> LayoutGeometry { live[i - base] }
        // What span `k` shows once its border has settled: its geometry, with what it hides where the span before showed it.
        func settled(_ k: Int) -> LayoutGeometry {
            k == 0 ? geometry(0) : Self.placingHidden(geometry(k), where: geometry(k - 1))
        }
        var shown = settled(burst.first - 1)
        // Where the transition before was going: at the start of a burst, what is shown.
        var heading = shown
        for (offset, p) in burst.progress.enumerated() {
            let k = burst.first + offset
            // What comes grows from 90 % of where it goes; what leaves goes to 90 % of where it is seen, or on to where it
            // was already going.
            let from = Self.placingHidden(shown, where: geometry(k))
            let to = Self.leaving(settled(k), from: from, heading: heading, before: geometry(k - 1))
            shown = LayoutGeometry.mix(from, to, p)
            heading = to
        }
        return Self.clamped(shown)
    }

    /// The screen's opacity at output time `τ`, as `geometry(atOutput:_:)` draws it, without the inputs: 1 where the layout
    /// shows the screen and 0 where it does not (Camera only and Camera full screen), blended by the same transitions and
    /// kept in 0…1.
    public func screenOpacity(atOutput τ: Int64) -> Double {
        Self.unit(blended(atOutput: τ) { kind in
            switch kind {
            case .bubble, .screenOnly, .split: 1
            case .cameraOnly, .cameraFull: 0
            }
        })
    }

    /// How much of the way from the stage to a card the layouts are at output time `τ` (1c design §5.4), without the
    /// inputs: 0 where the zoom acts on the whole stage (Bubble and Screen only) and 1 where the background stays still and
    /// the screen is in its card (Split, Camera only and Camera full screen), the geometry's `mode`, blended by the same
    /// transitions. It is the weight the background's transform, the screen's content and its clip blend with, as the
    /// rest of the geometry: not kept in 0…1, so it overshoots with the card's rect.
    public func cardWeight(atOutput τ: Int64) -> Double {
        blended(atOutput: τ) { kind in
            switch kind {
            case .bubble, .screenOnly: 0
            case .split, .cameraOnly, .cameraFull: 1
            }
        }
    }

    /// The camera changes of `doc` (`camera.changes`, this take's) that start to rule inside a block shown, by the id of
    /// that block: the instant where the take's bubble takes each one (`TimeMap.output(ofChangeAt:take:)`, one in a cut from
    /// the first instant kept after it) in the block's output range. Such a change is not seen while the block rules, and
    /// still counts after it.
    public func hiddenChanges(_ doc: EditDocument) -> [String: String] {
        var hidden: [String: String] = [:]
        for change in doc.camera.changes where change.take == takeID {
            guard let output = timeMap.output(ofChangeAt: change.t, take: takeID) else { continue }
            let span = spans[index(atOutput: output)]
            if let block = span.blockID, span.output.contains(output) { hidden[change.id] = block }
        }
        return hidden
    }

    // MARK: - Internal

    /// How far a transition has got, with a document's `camera.spring` (1c design §5.3 and §13.1).
    struct StepResponse: Sendable {
        /// From this long after a border on, it is done: `progress` is 1.
        let settleSeconds: Double
        private let damping: Double
        private let omega: Double

        /// `spring` read as `StepGrid.stable(_:)` reads a document's springs (damping 0 to 2, response at least 0.06 s), so
        /// a document edited by hand never stops the render. It is done once the slowest part of its motion has decayed
        /// as far as the design's spring (0.95, 0.5 s) has at `CameraStyleTimeline.settleSeconds` (by e^−17.9, which leaves
        /// it a few 10⁻⁷ of the way at most, so the step to 1 is not seen): exactly 1.5 s for that spring, and never (an
        /// undamped one) for a damping of 0.
        init(_ spring: SpringSpec) {
            let read = StepGrid.stable(spring)
            damping = read.damping
            omega = 2 * Double.pi / read.response
            settleSeconds = CameraStyleTimeline.settleSeconds * (Self.decay(of: CameraLayoutRules.spring) / Self.decay(of: spring))
        }

        /// 0 up to 0 s (and for NaN), 1 from `settleSeconds` on, and in between the step response of the spring, with
        /// ω = 2π / response and ζ the damping: `1 − e^(−ζωt)(cos(ω_d t) + (ζω/ω_d) sin(ω_d t))` with ω_d = ω√(1 − ζ²)
        /// under 1, `CameraStyleTimeline.progress` term for term; `1 − (1 + ωt)e^(−ωt)` at 1; and
        /// `1 − e^(−ζωt)(cosh(ω_h t) + (ζω/ω_h) sinh(ω_h t))` with ω_h = ω√(ζ² − 1) above.
        func progress(seconds t: Double) -> Double {
            guard t > 0 else { return 0 }
            guard t < settleSeconds else { return 1 }
            if damping < 1 {
                let dampedOmega = omega * (1 - damping * damping).squareRoot()
                let decay = exp(-damping * omega * t)
                return 1 - decay * (cos(dampedOmega * t) + damping * omega / dampedOmega * sin(dampedOmega * t))
            }
            if damping == 1 { return 1 - (1 + omega * t) * exp(-omega * t) }
            let hyperbolicOmega = omega * (damping * damping - 1).squareRoot()
            let decay = exp(-damping * omega * t)
            return 1 - decay * (cosh(hyperbolicOmega * t) + damping * omega / hyperbolicOmega * sinh(hyperbolicOmega * t))
        }

        /// The rate at which the slowest part of `spring`'s motion decays, per second: ζω up to a damping of 1, and
        /// ω(ζ − √(ζ² − 1)) above.
        private static func decay(of spring: SpringSpec) -> Double {
            let read = StepGrid.stable(spring)
            let omega = 2 * Double.pi / read.response
            guard read.damping > 1 else { return read.damping * omega }
            return omega * (read.damping - (read.damping * read.damping - 1).squareRoot())
        }
    }

    // MARK: - Private

    /// Two blocks this far apart in the output touch.
    private static let touching: Int64 = 1

    /// The span that rules at output time `τ`.
    private func index(atOutput τ: Int64) -> Int {
        // The last span starting at or before `τ`; the first one before the output.
        var low = 0, high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if spans[mid].output.lowerBound <= τ { low = mid + 1 } else { high = mid }
        }
        return max(low - 1, 0)
    }

    /// The transitions that make what is shown at an instant (see `burst(atOutput:)`).
    private struct Burst {
        /// What is shown starts from span `first − 1` settled.
        var first: Int
        /// How far each border from `first` on has got: by the next border, or by the instant for the last one. Empty
        /// without a transition under way.
        var progress: [Double]
        /// The span that rules.
        var last: Int { first - 1 + progress.count }
    }

    /// The transitions that make what is shown at `τ`: from the border of the span that rules back to the first border
    /// reached while the one before it was still moving. An instant border is never under way, so a burst starts after it.
    private func burst(atOutput τ: Int64) -> Burst {
        let last = index(atOutput: τ)
        guard isMoving(border: last, at: τ) else { return Burst(first: last + 1, progress: []) }
        var first = last
        while first > 1, isMoving(border: first - 1, at: spans[first].output.lowerBound) { first -= 1 }
        return Burst(first: first, progress: (first...last).map { k in
            let until = k < last ? spans[k + 1].output.lowerBound : τ
            return response.progress(seconds: CursorPath.seconds(until, since: spans[k].output.lowerBound))
        })
    }

    /// Whether the transition at the start of span `k` is under way at output time `x`: a border that is not an edge of an
    /// instant block, less than `settleSeconds` before `x`. There is none at the first span.
    private func isMoving(border k: Int, at x: Int64) -> Bool {
        guard k > 0, !spans[k].instant, !spans[k - 1].instant else { return false }
        return CursorPath.seconds(x, since: spans[k].output.lowerBound) < response.settleSeconds
    }

    /// What `span` shows settled, with `inputs`.
    private func layoutGeometry(_ span: LayoutSpan, _ inputs: LayoutInputs) -> LayoutGeometry {
        let region = Rect(x: 0, y: 0, width: inputs.output.x, height: inputs.output.y)
        let bubble = span.blockID == nil || inputs.takeBubble == nil
            ? inputs.takeBubble
            : span.bubbleStyle.map { $0.frame(in: region, reference: inputs.sizeReference) } ?? inputs.takeBubble
        return CameraLayoutGeometry.geometry(
            kind: span.kind, split: span.split, bubble: bubble, output: inputs.output, padding: inputs.padding,
            cornerRadius: inputs.cornerRadius, screenAspect: inputs.screenAspect)
    }

    /// `value` of each span's kind, blended by the transitions at `τ` as `LayoutGeometry.mix` blends a number.
    private func blended(atOutput τ: Int64, _ value: (LayoutKind) -> Double) -> Double {
        let burst = burst(atOutput: τ)
        var shown = value(spans[burst.first - 1].kind)
        for (offset, p) in burst.progress.enumerated() {
            shown = shown * (1 - p) + value(spans[burst.first + offset].kind) * p
        }
        return shown
    }

    /// `geometry` with each part it does not show (opacity 0 or less) where `other` shows it, as `CameraLayoutGeometry`
    /// hides a part (at `hiddenScale` of its size around its centre, its corners too, the camera with its border and
    /// shadow weights), keeping its opacity: so a part comes, or leaves, as it is where it is seen.
    private static func placingHidden(_ geometry: LayoutGeometry, where other: LayoutGeometry) -> LayoutGeometry {
        var geometry = geometry
        if geometry.screen.opacity <= 0, other.screen.opacity > 0 {
            geometry.screen = hidden(other.screen, opacity: geometry.screen.opacity)
        }
        if geometry.camera.opacity <= 0, other.camera.opacity > 0 {
            geometry.camera = hidden(other.camera, opacity: geometry.camera.opacity)
        }
        return geometry
    }

    /// `to`, a span settled, with each part it hides that is still seen in `from` (what was shown at the border) where
    /// that part goes: to where the transition before was `heading` if the layout `before` hid it too (it was already
    /// leaving), and otherwise hidden where it is seen. So what leaves fades in its place, in a burst too.
    private static func leaving(
        _ to: LayoutGeometry, from: LayoutGeometry, heading: LayoutGeometry, before: LayoutGeometry
    ) -> LayoutGeometry {
        var to = to
        if to.screen.opacity <= 0, from.screen.opacity > 0 {
            let opacity = to.screen.opacity
            to.screen = before.screen.opacity <= 0 ? heading.screen : CameraLayoutGeometry.hidden(from.screen)
            to.screen.opacity = opacity
        }
        if to.camera.opacity <= 0, from.camera.opacity > 0 {
            let opacity = to.camera.opacity
            to.camera = before.camera.opacity <= 0 ? heading.camera : CameraLayoutGeometry.hidden(from.camera)
            to.camera.opacity = opacity
        }
        return to
    }

    /// `screen` as `CameraLayoutGeometry` hides it, with `opacity`.
    private static func hidden(_ screen: ScreenCard, opacity: Double) -> ScreenCard {
        var hidden = CameraLayoutGeometry.hidden(screen)
        hidden.opacity = opacity
        return hidden
    }

    /// `camera` as `CameraLayoutGeometry` hides it, with `opacity`.
    private static func hidden(_ camera: CameraCard, opacity: Double) -> CameraCard {
        var hidden = CameraLayoutGeometry.hidden(camera)
        hidden.opacity = opacity
        return hidden
    }

    /// `geometry` with its opacities and weights kept in 0…1.
    private static func clamped(_ geometry: LayoutGeometry) -> LayoutGeometry {
        var geometry = geometry
        geometry.screen.opacity = unit(geometry.screen.opacity)
        geometry.camera.opacity = unit(geometry.camera.opacity)
        geometry.camera.borderWeight = unit(geometry.camera.borderWeight)
        geometry.camera.shadowWeight = unit(geometry.camera.shadowWeight)
        return geometry
    }

    private static func unit(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
