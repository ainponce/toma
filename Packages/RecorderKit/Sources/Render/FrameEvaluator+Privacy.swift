// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// A part of the screen hidden by privacy (phase 2 design §7.1 and §7.2), drawn in the screen's shader (§11, step 2):
/// blurred, pixelated or filled with `color`, by `strength`.
public struct PrivacyRegion: Equatable, Sendable {
    /// As fractions of the screen's crop as it is drawn (`ScreenLayer.crop`, after a change cut it to the rect's shape):
    /// 0, 0 its top-left corner, 1, 1 its bottom-right one.
    public var rect: Rect
    public var effect: PrivacyEffect
    /// 0 to 1.
    public var strength: Double
    /// sRGB from 0 to 1, not premultiplied: the fill's.
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

/// The privacy blocks of a document (`EditDocument.privacy`) as the frames draw them, worked out once for the scene
/// (`FrameEvaluator.init`).
///
/// The base of phase 2 leaves it empty: no region, and `apply` changes nothing, so a document without blocks draws as in
/// phase 1. Milestone 2c fills it here.
struct PrivacyScene: Sendable {
    init(document: EditDocument, take: TakeRecord, events: [InputEvent]) {}

    /// The regions over track `trackID` at source instant `t`, at most `PrivacyRegion.maxPerFrame`, in fractions of the
    /// track's whole frame: none in the base.
    func regions(atSource t: HostTime, trackID: String) -> [PrivacyRegion] {
        []
    }

    /// Puts the regions of `layer`'s track at source instant `t` onto `layer` (`ScreenLayer.privacy`), in fractions of its
    /// crop as it is drawn; a blur makes it sampled with mipmaps. `FrameEvaluator.finishLayers` calls it for the screen
    /// and for the screen being left. Nothing in the base.
    func apply(to layer: inout ScreenLayer, atSource t: HostTime) {}
}
