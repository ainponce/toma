// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The title card a frame of the sequence shows (phase 3 design §5.2 and §12, `titleCard-1`, plan 3a decision 10), in the
/// place of steps 1 to 6 and under the output's annotations (base plan decision 9): its texts in its style, and what goes
/// over the frame under them, the colour of a `.color` card (`fill`) or the black veil of a `.blurredFrame` one (`scrim`),
/// all of it at `opacity`, how far the card has faded in (or not yet out). The compositor draws it in output space, the
/// fill or the veil over the whole frame and then the texts, one texel a pixel (`Compositor.drawTitleCard`,
/// `TitleCardTextures`).
public struct TitleCardLayer: Equatable, Sendable {
    public var title: String
    /// `""` draws none.
    public var subtitle: String
    public var style: TitleCardStyle
    /// sRGB from 0 to 1, not premultiplied, written to the output as it is: the title's, and the subtitle's at 70 % of it.
    public var textColor: RGBA
    /// The colour over the whole frame, at `opacity` times its own alpha (a `.color` card's); `nil` without one.
    public var fill: RGBA?
    /// The opacity of the black veil over the whole frame, times `opacity` (a `.blurredFrame` card's 0.35); 0 none. Not
    /// drawn with a `fill`.
    public var scrim: Double
    /// 0 to 1: `p`, how far the card has faded in against the clip before it, or not yet out against the clip after it;
    /// 1 everywhere else and without a neighbor to fade against.
    public var opacity: Double

    public init(
        title: String, subtitle: String = "", style: TitleCardStyle, textColor: RGBA = RGBA(1, 1, 1, 1), fill: RGBA? = nil,
        scrim: Double = 0, opacity: Double = 1
    ) {
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.textColor = textColor
        self.fill = fill
        self.scrim = scrim
        self.opacity = opacity
    }
}

/// The title cards of a document's sequence (`ClipContent.card`) as the frames draw them (`titleCard-1`, plan 3a decision
/// 10), worked out once for the scene and again for each size (`FrameEvaluator.init` and `resized(to:)`): nothing of it
/// depends on the size, which only the card's texts do (`TitleCardTextures`).
///
/// A card of `D` ns of output (`ClipContent.outputDuration`) fades in over its first `F = min(0.3 s, D / 2)` against the
/// frame the output shows at `O_k − 1`, the last instant of the clip before it, held there: the same frame all the fade
/// long (`p = offset / F`); and out over its last `F` against the frame of `O_k + D`, the first instant of the clip after
/// it (`p = (D − offset) / F`). Without a clip on a side (the card starts or ends the output), or with a title card there,
/// that side cuts (`p = 1`): two cards never ask each other for a frame, and a card never asks for one of its own, so a
/// frame is never worked out again inside itself. With `p` that, what is under the card's texts:
///
/// - `.stage`: the neighbor's frame with the screen's group (`RenderFrame.screenOpacity`: the screens, the window frame,
///   the shadow, the device, the cursor and the click effects) and the camera at `1 − p`, without keys or captions; at
///   `p = 1`, the background alone.
/// - `.color`: the neighbor's frame held, without keys or captions, under the colour at `p` (`TitleCardLayer.fill`); the
///   background alone where the colour is opaque at `p = 1`, or without any neighbor.
/// - `.blurredFrame`: the neighbor's frame held, without cursor, camera, click effects, keys or captions, its screen
///   under it sharp (`RenderFrame.previousScreen`, with its own privacy) and over it the same screen with a blur over all
///   of its crop at full strength (`PrivacyRegion`) at `p` times its opacity, and the black veil at 35 % × `p`
///   (`TitleCardLayer.scrim`). In the first half of the card the clip before's frame is held, in the second the clip
///   after's (either side's when the other has none). Without a screen in that frame (the camera full screen, no
///   neighbor), as `.stage`.
///
/// The texts at `p` over all of it. The output's annotations go over the card (`FrameEvaluator.frame(at:)`).
struct TitleCardScene: Sendable {
    /// The longest fade of a card, in ns of output: 0.3 s.
    static let fade: Int64 = 300_000_000
    /// The black veil of a `.blurredFrame` card at `p = 1`.
    static let scrim = 0.35

    /// One card of the sequence as its frames read it.
    private struct Card: Sendable {
        var card: TitleCard
        /// `D`, ns of output.
        var duration: Int64
        /// `F`, ns of output: above 0, since `D` is at least 0.1 s.
        var fade: Int64
        /// The output instant it fades in against, `O_k − 1`: `nil` at the output's start or after a title card.
        var before: Int64?
        /// The output instant it fades out against, `O_k + D`: `nil` at the output's end or before a title card.
        var after: Int64?

        /// `p` at `offset` ns into the card.
        func progress(at offset: Int64) -> Double {
            if before != nil, offset < fade { return Double(offset) / Double(fade) }
            if after != nil, duration - offset < fade { return Double(duration - offset) / Double(fade) }
            return 1
        }

        /// The output instant whose frame is held under the card at `offset`: the clip before's in the first half of it,
        /// the clip after's in the second, either one's when the other has none. While it fades, the side it fades
        /// against.
        func held(at offset: Int64) -> Int64? {
            offset < duration - offset ? before ?? after : after ?? before
        }
    }

    /// The cards, by their index in the sequence.
    private let cards: [Int: Card]

    init(document: EditDocument, timeMap: TimeMap, outputSize: SIMD2<Int>) {
        let sequence = document.sequence
        var cards: [Int: Card] = [:]
        guard sequence.count == timeMap.clipOutputStarts.count else {
            self.cards = cards
            return
        }
        /// `output` when the output shows a clip there that is no title card; `nil` outside the output and on a card.
        func neighbor(at output: Int64) -> Int64? {
            guard output >= 0, output < timeMap.duration, let shown = timeMap.source(atOutput: output) else { return nil }
            if case .card? = sequence[shown.clip].content { return nil }
            return output
        }
        for (k, clip) in sequence.enumerated() {
            guard case let .card(card, _)? = clip.content else { continue }
            let start = timeMap.clipOutputStarts[k], duration = TimeMap.outputDuration(of: clip)
            let (end, overflow) = start.addingReportingOverflow(duration)
            guard duration > 0, !overflow else { continue }
            cards[k] = Card(
                card: card, duration: duration, fade: max(min(Self.fade, duration / 2), 1), before: neighbor(at: start - 1),
                after: neighbor(at: end))
        }
        self.cards = cards
    }

    /// The frame at `offset` ns into clip `k` of the sequence, a title card (`TimeMap.contentOffset(atOutput:)`), over
    /// `background`, the frame with the background alone; `neighbor` gives the frame the output shows at an output time,
    /// before its output's annotations (the clip next to the card, which it fades against: see the type's notes, never
    /// asked for an instant of a card). `background` itself for a clip that is no title card.
    func frame(
        clip k: Int, offset: Int64, background: RenderFrame, neighbor: (_ output: Int64) throws -> RenderFrame
    ) rethrows -> RenderFrame {
        guard let card = cards[k] else { return background }
        let p = card.progress(at: offset)
        var layer = TitleCardLayer(
            title: card.card.title, subtitle: card.card.subtitle, style: card.card.style, textColor: card.card.textColor, opacity: p)
        let held = card.held(at: offset)
        var frame: RenderFrame
        switch card.card.background {
        case .stage:
            frame = try Self.stage(p, held: held, background: background, neighbor: neighbor)
        case let .color(color):
            layer.fill = color
            if let held, p < 1 || !(color.a >= 1) {
                frame = Self.withoutOverlays(try neighbor(held))
            } else {
                frame = background
            }
        case .blurredFrame:
            if let held, let blurred = Self.blurred(try neighbor(held), p) {
                frame = blurred
                layer.scrim = Self.scrim
            } else {
                frame = try Self.stage(p, held: held, background: background, neighbor: neighbor)
            }
        }
        frame.titleCard = layer
        return frame
    }

    /// `.stage`'s frame at `p`: the neighbor's at `held` with the screen's group and the camera at `1 − p`, or the
    /// background alone at `p = 1` (and without a neighbor, which only happens there).
    private static func stage(
        _ p: Double, held: Int64?, background: RenderFrame, neighbor: (_ output: Int64) throws -> RenderFrame
    ) rethrows -> RenderFrame {
        guard p < 1, let held else { return background }
        return faded(try neighbor(held), keeping: 1 - p)
    }

    /// `frame` without what a card never shows: its keys and its captions. Its captions' layers ahead stay: they are not
    /// drawn in the frame, only made ahead for the frames that come (`RenderFrame.captionsAhead`), the clip's after the
    /// card among them.
    static func withoutOverlays(_ frame: RenderFrame) -> RenderFrame {
        var frame = frame
        frame.keys = nil
        frame.captions = nil
        return frame
    }

    /// `frame` without keys or captions, with the screen's group and the camera faded to `f` (0 to 1) of what they are, as
    /// the camera layouts fade the group (`RenderFrame.screenOpacity`): the group's opacity times `f`, the screen's too,
    /// and the screen being left under it so that the two together are the change at that, `f·q·(1 − s) / (1 − f·s)`
    /// with `s` and `q` their opacities; the cursors, the click effects, the device and the camera times `f`. A camera
    /// that covered every pixel no longer does below 1. `frame` as it is (without keys or captions) at `f = 1`.
    static func faded(_ frame: RenderFrame, keeping f: Double) -> RenderFrame {
        var faded = withoutOverlays(frame)
        let f = f.isNaN ? 0 : min(max(f, 0), 1)
        guard f < 1 else { return faded }
        faded.screenOpacity = (frame.screenOpacity.map { $0.isNaN ? 0 : min(max($0, 0), 1) } ?? 1) * f
        let s = frame.screen?.opacity ?? 0
        faded.screen?.opacity = s * f
        if var previous = faded.previousScreen {
            let shown = s * f
            previous.opacity = shown < 1 ? f * previous.opacity * (1 - min(max(s, 0), 1)) / (1 - shown) : 0
            faded.previousScreen = previous
        }
        func cursor(_ layer: CursorLayer?) -> CursorLayer? {
            layer.map { layer in
                var faded = layer
                faded.opacity = layer.opacity * f
                return faded
            }
        }
        faded.cursor = cursor(frame.cursor)
        faded.cursorSamples = frame.cursorSamples.compactMap(cursor)
        faded.subframes = frame.subframes.map { StageSubframe(stage: $0.stage, cursor: cursor($0.cursor)) }
        faded.clickEffects = frame.clickEffects.map { effect in
            var faded = effect
            faded.opacity = effect.opacity * f
            return faded
        }
        faded.deviceFrame?.opacity *= f
        faded.camera?.opacity *= f
        faded.coveredByCamera = false
        return faded
    }

    /// `.blurredFrame`'s frame at `p` over the neighbor's `frame` (see the type's notes); `nil` when it shows no screen.
    static func blurred(_ frame: RenderFrame, _ p: Double) -> RenderFrame? {
        guard let screen = frame.screen else { return nil }
        let p = p.isNaN ? 0 : min(max(p, 0), 1)
        var blurred = withoutOverlays(frame)
        blurred.cursor = nil
        blurred.cursorSamples = []
        blurred.subframes = frame.subframes.map { StageSubframe(stage: $0.stage, cursor: nil) }
        blurred.clickEffects = []
        blurred.camera = nil
        var over = screen
        over.privacy = [PrivacyRegion(rect: Rect(x: 0, y: 0, width: 1, height: 1), effect: .blur, strength: 1, color: SIMD4(0, 0, 0, 1))]
        over.opacity = screen.opacity * p
        blurred.previousScreen = screen
        blurred.screen = over
        return blurred
    }
}
