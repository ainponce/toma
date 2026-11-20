// SPDX-License-Identifier: GPL-3.0-or-later

/// How a zoom block shows its focus (phase 3 design §6): `ZoomRegion.mode`, and `AutoZoomSettings.mode` for the automatic
/// blocks without one. A value that is not one of these makes the document invalid, not newer.
public enum ZoomMode: String, Codable, Sendable, CaseIterable {
    /// The camera moves in, as in phases 1 and 2.
    case classic
    /// A ring around the focus and the rest a little darker; the picture does not move (`calmZoom-1`).
    case highlight
    /// Outside the focus darker and blurred; the picture does not move (`calmZoom-1`).
    case dim
    /// A lens over the focus that shows what is under it bigger; the picture does not move (`loupe-1`).
    case loupe
}

/// The shape of a loupe's lens.
public enum LoupeShape: String, Codable, Sendable, CaseIterable {
    case circle, roundedRect
}

/// The lens of a block in `loupe` mode (phase 3 design §6): `ZoomRegion.loupe`, `nil` for `LoupeStyle.default`.
public struct LoupeStyle: Codable, Equatable, Sendable {
    /// The lens's radius, as a fraction of the output's short side: 0.06 to 0.4 (`radiusRange`).
    public var radius: Double
    public var shape: LoupeShape

    /// The lens of a block without its own: a circle of 0.16 of the short side.
    public static let `default` = LoupeStyle()
    /// The radii a lens can have.
    public static let radiusRange: ClosedRange<Double> = 0.06...0.4

    public init(radius: Double = 0.16, shape: LoupeShape = .circle) {
        self.radius = radius
        self.shape = shape
    }
}
