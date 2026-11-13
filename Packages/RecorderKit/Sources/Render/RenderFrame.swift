// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// Everything one output frame shows, worked out from the project and the time alone. Positions are in
/// output pixels with the origin at the top left.
public struct RenderFrame: Equatable, Sendable {
    public var outputSize: SIMD2<Int>
    public var gradientStart: SIMD4<Float>
    public var gradientEnd: SIMD4<Float>
    public var gradientAngleDegrees: Float
    /// `nil` when the take has no display track.
    public var screen: ScreenLayer?
    /// `nil` when the cursor's position is unknown or off the recorded display.
    public var cursor: CursorLayer?

    public init(
        outputSize: SIMD2<Int>,
        gradientStart: SIMD4<Float>,
        gradientEnd: SIMD4<Float>,
        gradientAngleDegrees: Float,
        screen: ScreenLayer? = nil,
        cursor: CursorLayer? = nil
    ) {
        self.outputSize = outputSize
        self.gradientStart = gradientStart
        self.gradientEnd = gradientEnd
        self.gradientAngleDegrees = gradientAngleDegrees
        self.screen = screen
        self.cursor = cursor
    }
}

/// The recorded screen: the frame of track `trackID` shown at host time `sourceTime`, drawn into `rect`.
public struct ScreenLayer: Equatable, Sendable {
    public var trackID: String
    public var sourceTime: HostTime
    /// In output pixels, origin at the top left.
    public var rect: Rect
    /// In output pixels.
    public var cornerRadius: Double

    public init(trackID: String, sourceTime: HostTime, rect: Rect, cornerRadius: Double) {
        self.trackID = trackID
        self.sourceTime = sourceTime
        self.rect = rect
        self.cornerRadius = cornerRadius
    }
}

/// The redrawn cursor: `CursorSprite`'s hotspot goes at `hotspot`, and the sprite is `height` tall.
public struct CursorLayer: Equatable, Sendable {
    /// In output pixels, origin at the top left.
    public var hotspot: SIMD2<Double>
    /// In output pixels.
    public var height: Double

    public init(hotspot: SIMD2<Double>, height: Double) {
        self.hotspot = hotspot
        self.height = height
    }
}
