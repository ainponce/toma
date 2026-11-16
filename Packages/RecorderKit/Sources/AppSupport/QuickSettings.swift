// SPDX-License-Identifier: GPL-3.0-or-later
import Recording

/// The capture settings the island changes in place, saved between takes.
public struct QuickSettings: Codable, Equatable, Sendable {
    /// The frame rate of each display that has one other than the default, by display ID. Only positive
    /// values count (`framesPerSecond(display:)`).
    public var framesPerSecondByDisplay: [UInt32: Int] = [:]
    public var displayScale: CaptureScale = .native
    /// The frame rate a window is recorded at (Window mode); at the scale of `displayScale`.
    public var windowFramesPerSecond: Int = 60
    /// The camera's quality: the size the camera is recorded at, if it has it, and the bubble shows it at.
    public var cameraPreset: CameraPreset = .p1080
    public var cameraFramesPerSecond: Int = 30

    public init(
        framesPerSecondByDisplay: [UInt32: Int] = [:], displayScale: CaptureScale = .native, windowFramesPerSecond: Int = 60,
        cameraPreset: CameraPreset = .p1080, cameraFramesPerSecond: Int = 30
    ) {
        self.framesPerSecondByDisplay = framesPerSecondByDisplay
        self.displayScale = displayScale
        self.windowFramesPerSecond = windowFramesPerSecond
        self.cameraPreset = cameraPreset
        self.cameraFramesPerSecond = cameraFramesPerSecond
    }

    /// A field missing from what was saved (by a version that did not have it), or that this version
    /// cannot read (a value from another version), takes its default; the others are kept. A frame rate that is not
    /// positive is not one: the window's and the camera's take their default, as a display's does.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = QuickSettings()
        framesPerSecondByDisplay = (try? container.decodeIfPresent([UInt32: Int].self, forKey: .framesPerSecondByDisplay))
            ?? defaults.framesPerSecondByDisplay
        displayScale = (try? container.decodeIfPresent(CaptureScale.self, forKey: .displayScale)) ?? defaults.displayScale
        windowFramesPerSecond = (try? container.decodeIfPresent(Int.self, forKey: .windowFramesPerSecond)).flatMap { $0 > 0 ? $0 : nil }
            ?? defaults.windowFramesPerSecond
        cameraPreset = (try? container.decodeIfPresent(CameraPreset.self, forKey: .cameraPreset)) ?? defaults.cameraPreset
        cameraFramesPerSecond = (try? container.decodeIfPresent(Int.self, forKey: .cameraFramesPerSecond)).flatMap { $0 > 0 ? $0 : nil }
            ?? defaults.cameraFramesPerSecond
    }

    /// The frame rate to record `display` at: 60 unless another positive one was chosen.
    public func framesPerSecond(display: UInt32) -> Int {
        guard let chosen = framesPerSecondByDisplay[display], chosen > 0 else { return 60 }
        return chosen
    }
}
