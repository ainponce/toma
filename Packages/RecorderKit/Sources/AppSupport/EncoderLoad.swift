// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Recording

/// What a video track of a take records.
public enum LoadSource: Equatable, Sendable {
    /// A display, by its `CGDirectDisplayID` (also the display of an area: the whole display is recorded).
    case display(UInt32)
    case window
    case camera
}

/// One video track as the encoder sees it: the pixels of each frame and how many frames a second.
public struct VideoLoadItem: Equatable, Sendable {
    public var source: LoadSource
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int

    public init(source: LoadSource, width: Int, height: Int, framesPerSecond: Int) {
        self.source = source
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
    }
}

/// A change that takes load off the encoder. The app says each one in a sentence of its own.
public enum LoadSuggestion: Equatable, Sendable {
    /// Record the display at `to` frames a second.
    case lowerDisplayRate(displayID: UInt32, to: Int)
    /// Record the camera at this quality.
    case lowerCameraPreset(to: CameraPreset)
    /// Record the camera at `to` frames a second.
    case lowerCameraRate(to: Int)
}

/// How much of the encoder's budget a take would use (`ratio`, 1 being all of it), and what to change when it is
/// a lot.
public enum EncoderLoadVerdict: Equatable, Sendable {
    /// Below `EncoderLoad.warnRatio`.
    case ok(ratio: Double)
    /// From `EncoderLoad.warnRatio` to the whole budget: frames may be dropped.
    case high(ratio: Double, suggestions: [LoadSuggestion])
    /// Past the budget: frames will be dropped.
    case over(ratio: Double, suggestions: [LoadSuggestion])
}

/// Estimates whether the hardware encoder keeps up with a take: the pixels it encodes a second, all video tracks
/// together, against a budget measured on the Mac (`docs/performance.md`, "Presupuesto del encoder").
public enum EncoderLoad {
    public static let defaultBudgetPixelsPerSecond = 800_000_000
    /// From this share of the budget the load is `high`.
    public static let warnRatio = 0.8
    /// The `UserDefaults` key that overrides the budget, in pixels a second.
    static let budgetKey = "encoderBudgetPixelsPerSecond"

    /// The verdict for `items` within `budget` pixels a second. The suggestions, in this order: every display that
    /// is not the main one (`mainDisplayID`) and goes faster than 30 fps, down to 30; a camera larger than
    /// `.p1080`, down to `.p1080`; a camera faster than 30 fps, down to 30. A window, and the main display, are
    /// never asked to go lower: they are what the take is about.
    public static func evaluate(
        _ items: [VideoLoadItem], mainDisplayID: UInt32?, budget: Int = defaultBudgetPixelsPerSecond
    ) -> EncoderLoadVerdict {
        let pixelsPerSecond = items.reduce(0) { $0 + $1.width * $1.height * $1.framesPerSecond }
        let ratio = Double(pixelsPerSecond) / Double(max(budget, 1))
        guard ratio >= warnRatio else { return .ok(ratio: ratio) }
        let suggestions = suggestions(for: items, mainDisplayID: mainDisplayID)
        return ratio > 1 ? .over(ratio: ratio, suggestions: suggestions) : .high(ratio: ratio, suggestions: suggestions)
    }

    /// The budget `defaults` sets under `encoderBudgetPixelsPerSecond`, if it is positive; otherwise the default.
    public static func budget(defaults: UserDefaults) -> Int {
        let budget = defaults.integer(forKey: budgetKey)
        return budget > 0 ? budget : defaultBudgetPixelsPerSecond
    }

    private static func suggestions(for items: [VideoLoadItem], mainDisplayID: UInt32?) -> [LoadSuggestion] {
        let reducedRate = 30
        let largestCamera = CameraPreset.p1080
        var displays: [LoadSuggestion] = []
        var cameraPreset: [LoadSuggestion] = []
        var cameraRate: [LoadSuggestion] = []
        for item in items {
            switch item.source {
            case .display(let id):
                if id != mainDisplayID, item.framesPerSecond > reducedRate {
                    displays.append(.lowerDisplayRate(displayID: id, to: reducedRate))
                }
            case .camera:
                if item.width * item.height > largestCamera.width * largestCamera.height {
                    cameraPreset.append(.lowerCameraPreset(to: largestCamera))
                }
                if item.framesPerSecond > reducedRate { cameraRate.append(.lowerCameraRate(to: reducedRate)) }
            case .window:
                break
            }
        }
        return displays + cameraPreset + cameraRate
    }
}
