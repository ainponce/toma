// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// Everything one output frame shows, worked out from the project and the time alone. Positions are in
/// output pixels with the origin at the top left.
public struct RenderFrame: Equatable, Sendable {
    public var outputSize: SIMD2<Int>
    /// `gradientStart`, `gradientEnd` and `gradientAngleDegrees`: the gradient that a `.gradient` `background` draws.
    public var gradientStart: SIMD4<Float>
    public var gradientEnd: SIMD4<Float>
    public var gradientAngleDegrees: Float
    /// `nil` when the take has no screen track, and when its area cannot be shown: no part of it is on the display, or
    /// it cannot be placed (a `captureArea` with a size that is not usable, or a display without a usable
    /// `globalFrame`).
    public var screen: ScreenLayer?
    /// `nil` when the cursor's position is unknown or off what is shown of the screen.
    public var cursor: CursorLayer?
    /// `nil` when the take has no camera, and before its first frame.
    public var camera: CameraLayer?
    /// What is drawn behind everything: the gradient above (today's), a colour or a wallpaper.
    public var background: BackgroundLayer

    public init(
        outputSize: SIMD2<Int>,
        gradientStart: SIMD4<Float>,
        gradientEnd: SIMD4<Float>,
        gradientAngleDegrees: Float,
        screen: ScreenLayer? = nil,
        cursor: CursorLayer? = nil,
        camera: CameraLayer? = nil,
        background: BackgroundLayer = .gradient
    ) {
        self.outputSize = outputSize
        self.gradientStart = gradientStart
        self.gradientEnd = gradientEnd
        self.gradientAngleDegrees = gradientAngleDegrees
        self.screen = screen
        self.cursor = cursor
        self.camera = camera
        self.background = background
    }
}

/// The recorded screen: the `crop` of the frame of track `trackID` shown at host time `sourceTime`, drawn into
/// `rect`.
public struct ScreenLayer: Equatable, Sendable {
    public var trackID: String
    public var sourceTime: HostTime
    /// In output pixels, origin at the top left.
    public var rect: Rect
    /// In output pixels.
    public var cornerRadius: Double
    /// The part of the frame shown, as fractions of it (0, 0 is its top-left corner, 1, 1 the bottom-right one):
    /// the area recorded in Area mode, the whole frame otherwise.
    public var crop: Rect

    public init(
        trackID: String, sourceTime: HostTime, rect: Rect, cornerRadius: Double, crop: Rect = Rect(x: 0, y: 0, width: 1, height: 1)
    ) {
        self.trackID = trackID
        self.sourceTime = sourceTime
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.crop = crop
    }
}

/// The camera: the frame of track `trackID` shown at host time `sourceTime`, filling `rect` (cropped to its shape,
/// centred) with corners of `cornerRadius`.
public struct CameraLayer: Equatable, Sendable {
    public var trackID: String
    public var sourceTime: HostTime
    /// In output pixels, origin at the top left.
    public var rect: Rect
    /// In output pixels: half the side for a circle.
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
