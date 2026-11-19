// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// Where a privacy block is (design §7.1): its rect in fractions of the screen's content, over time, and the change of
/// frame between that content and what a layer draws. Pure; the render, the editor's rect and the scan share it.
public enum PrivacyGeometry {
    /// The shortest side of a block's rect, as a fraction of the content: a rect cannot be dragged to nothing.
    public static let minimumSide = 0.02

    /// The rect of `block` at source time `t`: `block.rect` with no keys; with keys, linear between the two around `t`
    /// (each of the four numbers), held before the first and after the last.
    public static func rect(of block: PrivacyBlock, atSource t: HostTime) -> NormalizedRect {
        let keys = block.keys.sorted { $0.t < $1.t }
        guard let first = keys.first, let last = keys.last else { return block.rect }
        if t <= first.t { return first.rect }
        if t >= last.t { return last.rect }
        guard let next = keys.firstIndex(where: { $0.t > t }), next > 0 else { return last.rect }
        let (a, b) = (keys[next - 1], keys[next])
        let span = Double(b.t.nanoseconds - a.t.nanoseconds)
        guard span > 0 else { return b.rect }
        let f = Double(t.nanoseconds - a.t.nanoseconds) / span
        func mix(_ p: Double, _ q: Double) -> Double { p + (q - p) * f }
        return NormalizedRect(
            x: mix(a.rect.x, b.rect.x), y: mix(a.rect.y, b.rect.y),
            width: mix(a.rect.width, b.rect.width), height: mix(a.rect.height, b.rect.height))
    }

    /// `rect` inside the content (0…1 each way) and at least `minimumSide` wide and high. Numbers that are not finite
    /// are taken as 0 (the minimum side at the origin).
    public static func clamped(_ rect: NormalizedRect) -> NormalizedRect {
        func finite(_ v: Double) -> Double { v.isFinite ? v : 0 }
        let width = min(max(finite(rect.width), minimumSide), 1)
        let height = min(max(finite(rect.height), minimumSide), 1)
        return NormalizedRect(
            x: min(max(finite(rect.x), 0), 1 - width), y: min(max(finite(rect.y), 0), 1 - height), width: width, height: height)
    }

    /// `rect`, in fractions of the screen's content, as fractions of what the layer draws: the content is the Area
    /// `contentCrop` of the frame and the layer shows `layerCrop` of the frame (both in fractions of the frame). Not
    /// clipped: a rect partly or wholly outside the layer's crop has parts outside 0…1 (the editor still draws its handles).
    public static func inLayerCrop(_ rect: NormalizedRect, contentCrop: Rect, layerCrop: Rect) -> Rect {
        let x = contentCrop.x + rect.x * contentCrop.width
        let y = contentCrop.y + rect.y * contentCrop.height
        let width = rect.width * contentCrop.width
        let height = rect.height * contentCrop.height
        return Rect(
            x: (x - layerCrop.x) / layerCrop.width, y: (y - layerCrop.y) / layerCrop.height,
            width: width / layerCrop.width, height: height / layerCrop.height)
    }

    /// The inverse of `inLayerCrop`: a rect in fractions of what the layer draws, as fractions of the screen's content.
    /// Not clamped (see `clamped`).
    public static func inContent(_ rect: Rect, contentCrop: Rect, layerCrop: Rect) -> NormalizedRect {
        let x = layerCrop.x + rect.x * layerCrop.width
        let y = layerCrop.y + rect.y * layerCrop.height
        let width = rect.width * layerCrop.width
        let height = rect.height * layerCrop.height
        return NormalizedRect(
            x: (x - contentCrop.x) / contentCrop.width, y: (y - contentCrop.y) / contentCrop.height,
            width: width / contentCrop.width, height: height / contentCrop.height)
    }
}
