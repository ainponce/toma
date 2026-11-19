// SPDX-License-Identifier: GPL-3.0-or-later

/// What is behind the person in the camera's picture (phase 2 design §6.1): `CameraPlan.background`.
public enum CameraBackground: String, Codable, Sendable, CaseIterable {
    /// As recorded: what phase 1 draws.
    case original
    /// The camera's own picture, blurred, behind the person (`personMask-1`).
    case blurred
    /// The person alone, cut out (`personMask-1`).
    case removed
}

/// Which part of the camera's picture fills its shape (phase 2 design §6.2): `CameraPlan.framing`. The crop is the one
/// that fills the shape, divided by `zoom` and centered at the center (the face's, or `center`), never outside the frame.
public struct CameraFraming: Codable, Equatable, Sendable {
    public var mode: CameraFramingMode
    /// The center of `manual`, in fractions of the camera's picture.
    public var center: NormalizedPoint
    /// In `zoomRange`.
    public var zoom: Double

    /// What phase 1 draws: the middle, not zoomed.
    public static let legacy = CameraFraming(mode: .center, center: NormalizedPoint(x: 0.5, y: 0.5), zoom: 1)
    /// The zooms the framing can have.
    public static let zoomRange: ClosedRange<Double> = 1...2.5
    /// The zoom "Follow the Face" starts with.
    public static let faceZoom = 1.4

    public init(mode: CameraFramingMode, center: NormalizedPoint, zoom: Double) {
        self.mode = mode
        self.center = center
        self.zoom = zoom
    }
}

public enum CameraFramingMode: String, Codable, Sendable, CaseIterable {
    /// Centered in the picture.
    case center
    /// At the face, followed (`faceTrack-1`, `faceFraming-1`).
    case face
    /// At `CameraFraming.center`, set by hand.
    case manual
}

/// The colour of the camera's picture (phase 2 design §6.3): `CameraPlan.look`. Each preset is a 3D LUT made in code
/// (`cameraLook-1`); `custom` is the user's `.cube`. Not the `CameraLook` of 1c, which is the camera's mirror, border,
/// shadow and layout.
public struct CameraColor: Codable, Equatable, Sendable {
    public var preset: CameraColorPreset
    /// The `.cube` of `custom`, copied into the package: its path from the package root, `assets/<sha256>.cube`. Left out
    /// of the JSON when `nil`.
    public var lut: String?
    /// 0 to 1: how much of the result is mixed over the original.
    public var intensity: Double

    /// What phase 1 draws: the identity, whole.
    public static let natural = CameraColor(preset: .natural, lut: nil, intensity: 1)

    public init(preset: CameraColorPreset, lut: String?, intensity: Double) {
        self.preset = preset
        self.lut = lut
        self.intensity = intensity
    }
}

public enum CameraColorPreset: String, Codable, Sendable, CaseIterable {
    case natural, warm, cool, vivid, soft, mono, custom
}

/// A point in fractions of something (the camera's picture), each from 0 to 1, with y going down.
public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
