// SPDX-License-Identifier: GPL-3.0-or-later

/// The size the preview draws at while it plays (design §7.8, plan decision 38): the export's, until the frames have been
/// late for `lateWindow` seconds in a row; from then until playback pauses (`reset()`), half the side, never less than
/// `minimumShortSide` on the short side. Only the size changes: no effect is ever turned off and no algorithm changes.
public struct PreviewQuality: Equatable, Sendable {
    /// The shortest short side the preview is reduced to, in pixels.
    public static let minimumShortSide = 720
    /// Seconds of late frames in a row after which the preview draws smaller.
    public static let lateWindow = 0.5

    /// The size of the export: what the preview draws at until it falls behind, and while paused.
    public let exportSize: SIMD2<Int>
    /// Whether the preview draws at `reducedSize(of: exportSize)`.
    private(set) var isReduced = false
    /// When the frames started being late, in a row; `nil` while the last one was in time.
    private var lateSince: Double?

    public init(exportSize: SIMD2<Int>) {
        self.exportSize = exportSize
    }

    /// The size to draw at now.
    public var size: SIMD2<Int> { isReduced ? Self.reducedSize(of: exportSize) : exportSize }

    /// Notes a frame presented at `atSeconds` (any clock that runs with the wall clock), late or in time, and returns the
    /// size to draw the next one at: half the side once the frames have been late for `lateWindow` seconds in a row.
    public mutating func record(late: Bool, atSeconds seconds: Double) -> SIMD2<Int> {
        guard late else {
            lateSince = nil
            return size
        }
        let since = lateSince ?? seconds
        lateSince = since
        if seconds - since >= Self.lateWindow { isReduced = true }
        return size
    }

    /// Back to the export's size, as when playback pauses.
    public mutating func reset() {
        isReduced = false
        lateSince = nil
    }

    /// Half the side of `size`, with a short side of at least `minimumShortSide` (and never more than `size`'s own), both
    /// sides even: 3840 × 2160 → 1920 × 1080, 1920 × 1080 → 1280 × 720, 1080 × 1920 → 720 × 1280.
    static func reducedSize(of size: SIMD2<Int>) -> SIMD2<Int> {
        let short = min(size.x, size.y)
        guard short > minimumShortSide, short > 0 else { return size }
        let reducedShort = max(short / 2, minimumShortSide)
        let scale = Double(reducedShort) / Double(short)
        func even(_ side: Int) -> Int { max(2, Int((Double(side) * scale / 2).rounded()) * 2) }
        return SIMD2(even(size.x), even(size.y))
    }
}
