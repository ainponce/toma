// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// The panel's sliders show an integer from 0 to 100 and the document keeps the render's measure (design §5.4): each
/// pair converts one way and back, rounding to the nearest integer.
public enum PanelValues {
    /// The cursor's size as a percentage of the real size.
    public static let cursorScaleRange = 50...300
    /// What a slider's integer goes over.
    public static let sliderRange = 0...100

    /// Padding: `v / 100 × 0.20` of the output's width, on each side.
    public static func padding(slider: Int) -> Double { Double(slider) * 0.20 / 100 }
    public static func slider(padding: Double) -> Int { integer(padding / 0.20 * 100) }

    /// Corners: `v / 100 × 0.04` of the output's width.
    public static func cornerRadius(slider: Int) -> Double { Double(slider) * 0.04 / 100 }
    public static func slider(cornerRadius: Double) -> Int { integer(cornerRadius / 0.04 * 100) }

    /// The background's blur: `v / 100` (σ = that × 0.04 × the output's width).
    public static func backgroundBlur(slider: Int) -> Double { Double(slider) / 100 }
    public static func slider(backgroundBlur: Double) -> Int { integer(backgroundBlur * 100) }

    /// The shadow: `v / 100`.
    public static func shadow(slider: Int) -> Double { Double(slider) / 100 }
    public static func slider(shadow: Double) -> Int { integer(shadow * 100) }

    /// Motion blur (the shutter, as a fraction of a frame): `v / 100`.
    public static func motionBlur(slider: Int) -> Double { Double(slider) / 100 }
    public static func slider(motionBlur: Double) -> Int { integer(motionBlur * 100) }

    /// The cursor's scale: `percent / 100`, and the percentage of a scale.
    public static func cursorScale(percent: Int) -> Double { Double(percent) / 100 }
    public static func percent(cursorScale: Double) -> Int { integer(cursorScale * 100, in: cursorScaleRange) }

    /// The camera's size as a percentage of the output's height, from 0.10 to 0.45 (the bar of the Camera tab).
    public static let cameraSizeRange = 10...45
    public static func cameraSize(percent: Int) -> Double { Double(min(max(percent, cameraSizeRange.lowerBound), cameraSizeRange.upperBound)) / 100 }
    public static func percent(cameraSize: Double) -> Int { integer(cameraSize * 100, in: cameraSizeRange) }

    /// The camera's border: `v / 100` (the width is that × 0.012 × the output's short side).
    public static func cameraBorder(slider: Int) -> Double { Double(slider) / 100 }
    public static func slider(cameraBorder: Double) -> Int { integer(cameraBorder * 100) }

    /// The camera's shadow: `v / 100`.
    public static func cameraShadow(slider: Int) -> Double { Double(slider) / 100 }
    public static func slider(cameraShadow: Double) -> Int { integer(cameraShadow * 100) }

    /// The camera's part of a split, as a percentage from 25 to 60 (`SplitLayout.shareRange`).
    public static let splitShareRange = 25...60
    public static func splitShare(percent: Int) -> Double {
        Double(min(max(percent, splitShareRange.lowerBound), splitShareRange.upperBound)) / 100
    }
    public static func percent(splitShare: Double) -> Int { integer(splitShare * 100, in: splitShareRange) }

    /// The click sound's volume: `percent / 100`, from 0 to 100 %.
    public static func clickSoundGain(percent: Int) -> Double { Double(percent) / 100 }
    public static func percent(clickSoundGain: Double) -> Int { integer(clickSoundGain * 100) }

    /// The track's volume: `percent / 100`, from 0 to 200 % (the document's gain goes from 0 to 2).
    public static let trackVolumeRange = 0...200
    public static func trackGain(percent: Int) -> Double { Double(min(max(percent, trackVolumeRange.lowerBound), trackVolumeRange.upperBound)) / 100 }
    public static func percent(trackGain: Double) -> Int { integer(trackGain * 100, in: trackVolumeRange) }

    /// The seconds without moving before the cursor is hidden: 1 to 5 s, in steps of half a second.
    public static let idleDelayRange: ClosedRange<Double> = 1...5
    public static let idleDelayStep = 0.5

    /// Where a gradient of `angle` degrees (as in CSS: 0 goes up, 90 to the right, 135 down and to the right) starts and
    /// ends in a box, as fractions of it with y down: through the centre, along the angle.
    public static func gradientEnds(angle: Double) -> (start: SIMD2<Double>, end: SIMD2<Double>) {
        let radians = (angle.isFinite ? angle : 180) * Double.pi / 180
        let direction = SIMD2(sin(radians), -cos(radians)) / 2
        let center = SIMD2(0.5, 0.5)
        return (center - direction, center + direction)
    }

    /// The corners slider's integer for the window frame's cover: a cover can need more than the slider's top (a 300 pt
    /// window gives 0.0465), so it is kept to the slider's range.
    private static func integer(_ value: Double, in range: ClosedRange<Int> = sliderRange) -> Int {
        guard value.isFinite else { return range.lowerBound }
        return min(max(Int(value.rounded()), range.lowerBound), range.upperBound)
    }
}

/// How the drawn cursor follows the recorded one, as the Cursor tab offers it (design §8.4): the spring of each choice as
/// damping · response.
public enum CursorSmoothingPreset: CaseIterable, Sendable {
    case off, fast, medium, smooth

    public var smoothing: CursorSmoothing {
        switch self {
        case .off: .off
        case .fast: .spring(SpringSpec(damping: 1.0, response: 0.10))
        case .medium: .spring(SpringSpec(damping: 1.0, response: 0.16))
        case .smooth: .spring(SpringSpec(damping: 0.92, response: 0.26))
        }
    }

    /// The choice that is `smoothing`, if it is one of them (another spring, from an older project or by hand, is none).
    public init?(_ smoothing: CursorSmoothing) {
        guard let match = Self.allCases.first(where: { $0.smoothing == smoothing }) else { return nil }
        self = match
    }
}

/// The ids of the cursor's click effects and sounds (`CursorStyle.clickEffect` and `clickSound`).
public enum ClickChoice {
    public static let effects = ["none", "ripple-1", "circle-1"]
    public static let sounds = ["none", "soft-1", "mechanical-1"]
}
