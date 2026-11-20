// SPDX-License-Identifier: GPL-3.0-or-later

extension ZoomMode {
    /// Whether the mode leaves the picture where it is (`highlight`, `dim` and `loupe`): everything but `classic`.
    public var isCalm: Bool { self != .classic }
}

extension ZoomRegion {
    /// The mode the block shows its focus in (phase 3 design §6, plan decision 1): its own, or without one `classic` for a
    /// block of the user's and `auto.mode` for an automatic one.
    public func resolvedMode(auto: AutoZoomSettings) -> ZoomMode {
        mode ?? (origin == .auto ? auto.mode : .classic)
    }

    /// The lens of the block (plan decision 2): its own or `LoupeStyle.default`, with the radius held in
    /// `LoupeStyle.radiusRange` (0.16 if it is not a number).
    public var resolvedLoupe: LoupeStyle {
        let style = loupe ?? .default
        let range = LoupeStyle.radiusRange
        let radius = style.radius.isNaN ? LoupeStyle.default.radius : min(max(style.radius, range.lowerBound), range.upperBound)
        return LoupeStyle(radius: radius, shape: style.shape)
    }
}
