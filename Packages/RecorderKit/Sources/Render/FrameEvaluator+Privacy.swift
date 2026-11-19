// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// A part of the screen hidden by privacy (phase 2 design §7.1 and §7.2), drawn in the screen's shader (§11, step 2):
/// blurred, pixelated or filled with `color`, by `strength` (`privacy-1`, `ShaderSource.privacyMetal`).
public struct PrivacyRegion: Equatable, Sendable {
    /// As fractions of the screen's crop as it is drawn (`ScreenLayer.crop`, after a change cut it to the rect's shape):
    /// 0, 0 its top-left corner, 1, 1 its bottom-right one. A pixel is in it when what it shows of the crop is in
    /// `[x, x + width) × [y, y + height)`.
    public var rect: Rect
    public var effect: PrivacyEffect
    /// 0 to 1: how much a blur hides (a pixelation's cells do not depend on it).
    public var strength: Double
    /// sRGB from 0 to 1, not premultiplied: the fill's, drawn opaque.
    public var color: SIMD4<Float>

    /// The most regions a screen is drawn with in one frame.
    public static let maxPerFrame = 8

    public init(rect: Rect, effect: PrivacyEffect, strength: Double, color: SIMD4<Float>) {
        self.rect = rect
        self.effect = effect
        self.strength = strength
        self.color = color
    }
}

/// The privacy blocks of a document (`EditDocument.privacy`) as the frames draw them (`privacy-1`, plan 2c decision 3),
/// worked out once for the scene (`FrameEvaluator.init`).
///
/// A block of the take is shown at the source instants `[start, end)` of it that the output shows, over whichever of the
/// take's screens is shown, at its rect then (`PrivacyGeometry.rect(of:atSource:)`: its keys interpolated, held before
/// the first and after the last), clamped to the screen's content (`PrivacyGeometry.clamped`). More than
/// `PrivacyRegion.maxPerFrame` at an instant are never left out: the first 7 of the document's order are drawn, and the
/// eighth region is a blur at full strength over the rect that holds all the others.
///
/// A document without blocks of the take has no region anywhere, and `apply` changes no layer: it draws as in phase 1.
struct PrivacyScene: Sendable {
    /// The take's blocks, in the document's order, their keys in time order.
    private let blocks: [PrivacyBlock]
    /// Where each of the take's screens is, by track ID: what its content is (`ShownScreen.crop`, the Area in Area mode).
    /// Empty without blocks.
    private let screens: [String: ScreenGeometry]

    init(document: EditDocument, take: TakeRecord, events: [InputEvent]) {
        let blocks = document.privacy.blocks.filter { $0.take == take.id }.map { block in
            var sorted = block
            sorted.keys = block.keys.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
            return sorted
        }
        self.blocks = blocks
        guard !blocks.isEmpty else {
            screens = [:]
            return
        }
        let ordered = events.sortedByTime()
        screens = Dictionary(
            take.tracks.filter(\.kind.isScreen).map { ($0.id, ScreenGeometry(track: $0, events: ordered)) },
            uniquingKeysWith: { first, _ in first })
    }

    /// The regions over track `trackID` at source instant `t`, at most `PrivacyRegion.maxPerFrame`, with their rects in
    /// fractions of the screen's content (as the blocks are): none for a track that is not one of the take's screens.
    func regions(atSource t: HostTime, trackID: String) -> [PrivacyRegion] {
        guard screens[trackID] != nil else { return [] }
        let shown = blocks.filter { $0.start <= t && t < $0.end }
        let rects = shown.map { PrivacyGeometry.clamped(PrivacyGeometry.rect(of: $0, atSource: t)) }
        func region(_ block: PrivacyBlock, _ rect: NormalizedRect) -> PrivacyRegion {
            let color = block.color
            return PrivacyRegion(
                rect: Rect(x: rect.x, y: rect.y, width: rect.width, height: rect.height), effect: block.effect,
                strength: block.strength.isNaN ? 1 : min(max(block.strength, 0), 1),
                color: SIMD4(Float(color.r), Float(color.g), Float(color.b), Float(color.a)))
        }
        guard shown.count > PrivacyRegion.maxPerFrame else { return zip(shown, rects).map(region) }
        let kept = PrivacyRegion.maxPerFrame - 1
        let rest = rects[kept...]
        let left = rest.map(\.x).min()!, top = rest.map(\.y).min()!
        let right = rest.map { $0.x + $0.width }.max()!, bottom = rest.map { $0.y + $0.height }.max()!
        let all = PrivacyRegion(
            rect: Rect(x: left, y: top, width: right - left, height: bottom - top), effect: .blur, strength: 1,
            color: SIMD4(0, 0, 0, 1))
        return zip(shown.prefix(kept), rects.prefix(kept)).map(region) + [all]
    }

    /// Puts the regions of `layer`'s track at source instant `t` onto `layer` (`ScreenLayer.privacy`), in fractions of its
    /// crop as it is drawn (`PrivacyGeometry.inLayerCrop`, from the content shown then: the Area in Area mode), so they
    /// cover the same content while a change cuts the crop, and through the zoom, the card and the motion blur, which move
    /// the whole layer. With any, the layer is sampled with mipmaps, which its blur and its pixels are made from, whatever
    /// the document's sampling. `FrameEvaluator.finishLayers` calls it for the screen and for the screen being left.
    func apply(to layer: inout ScreenLayer, atSource t: HostTime) {
        let regions = regions(atSource: t, trackID: layer.trackID)
        guard !regions.isEmpty else { return }
        let content = screens[layer.trackID]?.shown(at: t)?.crop ?? layer.crop
        let crop = layer.crop
        layer.privacy = regions.map { region in
            var drawn = region
            let rect = region.rect
            drawn.rect = PrivacyGeometry.inLayerCrop(
                NormalizedRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height), contentCrop: content, layerCrop: crop)
            // A crop of no size cannot place it: then it covers all the layer draws.
            if ![drawn.rect.x, drawn.rect.y, drawn.rect.width, drawn.rect.height].allSatisfy(\.isFinite) {
                drawn.rect = Rect(x: 0, y: 0, width: 1, height: 1)
            }
            return drawn
        }
        layer.mipmapped = true
    }
}

extension RenderFrame {
    /// The screen as it is drawn (`Compositor.drawStage`): through the zoom camera (`stage`) on the stage; in a card's mode,
    /// through the card's content, square, or through the background's transform without a card. For the editor's rect of
    /// a privacy block (plan 2c task P6), whose regions are fractions of its `crop` over its `rect`. `nil` without a screen.
    public var drawnScreen: ScreenLayer? {
        guard let screen else { return nil }
        if let card {
            var drawn = Compositor.moving(card.content, outputSize: outputSize)?.drawn(screen, outputSize: outputSize) ?? screen
            drawn.cornerRadius = 0
            return drawn
        }
        let through = Compositor.moving(isCardMode ? backgroundTransform : stage, outputSize: outputSize)
        return through?.drawn(screen, outputSize: outputSize) ?? screen
    }
}
