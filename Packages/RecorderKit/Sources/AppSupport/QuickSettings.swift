// SPDX-License-Identifier: GPL-3.0-or-later
import Recording

/// The capture settings the island changes in place, saved between takes.
public struct QuickSettings: Codable, Equatable, Sendable {
    /// The frame rate of each display that has one other than the default, by display ID.
    public var framesPerSecondByDisplay: [UInt32: Int] = [:]
    public var displayScale: CaptureScale = .native

    public init(framesPerSecondByDisplay: [UInt32: Int] = [:], displayScale: CaptureScale = .native) {
        self.framesPerSecondByDisplay = framesPerSecondByDisplay
        self.displayScale = displayScale
    }

    /// A field missing from what was saved (by a version that did not have it) takes its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = QuickSettings()
        framesPerSecondByDisplay = try container.decodeIfPresent([UInt32: Int].self, forKey: .framesPerSecondByDisplay)
            ?? defaults.framesPerSecondByDisplay
        displayScale = try container.decodeIfPresent(CaptureScale.self, forKey: .displayScale) ?? defaults.displayScale
    }

    /// The frame rate to record `display` at: 60 unless another was chosen.
    public func framesPerSecond(display: UInt32) -> Int {
        framesPerSecondByDisplay[display] ?? 60
    }
}
