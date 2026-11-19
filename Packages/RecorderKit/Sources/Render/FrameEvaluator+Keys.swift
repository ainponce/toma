// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The keys shown in a frame (phase 2 design §7.4, `keyOverlay-1`), drawn over the camera and under the captions (§11,
/// step 5): what the timeline shows at that instant (`KeyOverlayTimeline.shown(atOutput:)`), at most two, the one going
/// first first (a cross-fade draws the new one over it). The compositor draws the texture `KeyOverlayTexture` makes of
/// each item over its rect, one texel a pixel, at its opacity.
public struct KeyOverlayLayer: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        /// Loose keys (a shortcut) or the pill of what is typed.
        public var content: KeyOverlayContent
        /// The box in output pixels: whole pixels across and down (`KeyOverlayMetrics.size(of:capHeight:)`), where
        /// `KeyOverlayPlacement.rect` puts it.
        public var rect: Rect
        /// The height of a key in output pixels (`KeyOverlayPlacement.capHeight`): every measure of the box is a fraction
        /// of it.
        public var capHeight: Double
        /// 0 to 1.
        public var opacity: Double

        public init(content: KeyOverlayContent, rect: Rect, capHeight: Double, opacity: Double) {
            self.content = content
            self.rect = rect
            self.capHeight = capHeight
            self.opacity = opacity
        }
    }

    public var items: [Item]

    public init(items: [Item] = []) {
        self.items = items
    }
}

/// The keys on screen of a document (`EditDocument.keys` over the `keyPress` events of its take `take`) as the frames
/// draw them, worked out once for the scene and again for each size (`FrameEvaluator.init` and `resized(to:)`): the
/// take's `KeyOverlayTimeline`, each display measured (`KeyOverlayMetrics`) at the height of a key of `keys.size` and put
/// where `KeyOverlayPlacement` says, clear of what the captions reserve at the same edge when they are shown.
///
/// None with the keys off (`keys.mode` `.off`, every document of phase 1) or when the take shows no key: such a document
/// draws as it did.
struct KeyOverlayScene: Sendable {
    /// `nil` when nothing is ever shown.
    private let timeline: KeyOverlayTimeline?
    private let keys: KeyOverlayPlan
    private let captions: CaptionPlan
    private let outputSize: SIMD2<Int>
    private let capHeight: Double

    init(document: EditDocument, take: String, events: [InputEvent], timeMap: TimeMap, outputSize: SIMD2<Int>) {
        keys = document.keys
        captions = document.captions
        self.outputSize = outputSize
        capHeight = KeyOverlayPlacement.capHeight(document.keys.size, outputSize: outputSize)
        guard document.keys.mode != .off, outputSize.x > 0, outputSize.y > 0, capHeight >= 1 else {
            timeline = nil
            return
        }
        let timeline = KeyOverlayTimeline(events: events, take: take, timeMap: timeMap, mode: document.keys.mode)
        self.timeline = timeline.isEmpty ? nil : timeline
    }

    /// The keys at output time `output` (nanoseconds): an item for each display then on, in the timeline's order; `nil`
    /// when none is.
    func layer(atOutput output: Int64) -> KeyOverlayLayer? {
        guard let timeline else { return nil }
        let items = timeline.shown(atOutput: output).compactMap { shown -> KeyOverlayLayer.Item? in
            let box = KeyOverlayMetrics.size(of: shown.content, capHeight: capHeight)
            guard box.x > 0, box.y > 0 else { return nil }
            let rect = KeyOverlayPlacement.rect(boxSize: box, keys: keys, captions: captions, outputSize: outputSize)
            return KeyOverlayLayer.Item(content: shown.content, rect: rect, capHeight: capHeight, opacity: shown.opacity)
        }
        return items.isEmpty ? nil : KeyOverlayLayer(items: items)
    }
}
