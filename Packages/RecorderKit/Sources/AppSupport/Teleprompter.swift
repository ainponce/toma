// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// The teleprompter (notch design §5.4): whether it shows, the one script (the last used, kept in the app's
/// settings), and how it reads it.
public struct TeleprompterSettings: Codable, Equatable, Sendable {
    public var isOn: Bool = false
    public var script: String = ""
    /// In points: from 14 to 40, in steps of 2.
    public var fontSize: Double = 22
    /// How fast the script goes up, as a multiple of `pointsPerSecondAtOneX`: from 0.3× to 3×.
    public var speed: Double = 1
    /// Of its background and its text: from 20 to 100 %.
    public var opacity: Double = 0.85

    public static let fontSizes = 14.0...40.0
    public static let fontStep = 2.0
    public static let speeds = 0.3...3.0
    public static let opacities = 0.2...1.0
    /// How far the script goes up in a second at 1×.
    public static let pointsPerSecondAtOneX = 24.0

    public init(isOn: Bool = false, script: String = "", fontSize: Double = 22, speed: Double = 1, opacity: Double = 0.85) {
        self.isOn = isOn
        self.script = script
        self.fontSize = fontSize
        self.speed = speed
        self.opacity = opacity
    }

    /// A field missing from what was saved (by a version that did not have it), or that this version
    /// cannot read, takes its default; the others are kept.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TeleprompterSettings()
        isOn = (try? container.decodeIfPresent(Bool.self, forKey: .isOn)) ?? defaults.isOn
        script = (try? container.decodeIfPresent(String.self, forKey: .script)) ?? defaults.script
        fontSize = (try? container.decodeIfPresent(Double.self, forKey: .fontSize)) ?? defaults.fontSize
        speed = (try? container.decodeIfPresent(Double.self, forKey: .speed)) ?? defaults.speed
        opacity = (try? container.decodeIfPresent(Double.self, forKey: .opacity)) ?? defaults.opacity
    }

    /// Each value in its range, and the size on its step: `14 + ((size − 14) / 2).rounded() × 2`, a tie going
    /// away from zero.
    public func clamped() -> TeleprompterSettings {
        var clamped = self
        let size = Self.clamp(fontSize, to: Self.fontSizes)
        let smallest = Self.fontSizes.lowerBound
        clamped.fontSize = smallest + ((size - smallest) / Self.fontStep).rounded() * Self.fontStep
        clamped.speed = Self.clamp(speed, to: Self.speeds)
        clamped.opacity = Self.clamp(opacity, to: Self.opacities)
        return clamped
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// How far the script has gone up, in points from where it starts.
public struct TeleprompterScroll: Equatable, Sendable {
    public private(set) var offset: Double = 0

    public init() {}

    /// Goes up `speed × pointsPerSecondAtOneX × seconds` while `isRunning` (recording and not paused), never
    /// past `maximum`: the height of the text less what is visible of it.
    public mutating func advance(seconds: Double, speed: Double, isRunning: Bool, maximum: Double) {
        guard isRunning else { return }
        let step = max(0, speed * TeleprompterSettings.pointsPerSecondAtOneX * seconds)
        offset = min(offset + step, max(0, maximum))
    }

    /// Back to the top.
    public mutating func reset() {
        offset = 0
    }
}

/// Where the teleprompter is, and when it shows.
public enum TeleprompterLayout {
    public static let width = 640.0
    /// Between the island's bottom edge and the teleprompter's top.
    public static let gap = 10.0
    public static let height = 160.0

    /// Centered under `island`, `gap` below its bottom edge. AppKit coordinates.
    public static func frame(below island: CGRect) -> CGRect {
        CGRect(x: Double(island.midX) - width / 2, y: Double(island.minY) - gap - height, width: width, height: height)
    }

    /// When it is on, with the island open, counting down, recording (with its wings, open, or with a
    /// notice): never at rest, peeking, choosing on the screen, nor while a take is saved.
    public static func isVisible(isOn: Bool, island: IslandState) -> Bool {
        guard isOn else { return false }
        switch island {
        case .open, .countdown, .recording, .recordingOpen, .notice: return true
        case .rest, .peek, .choosing, .saving, .saved: return false
        }
    }
}
