// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The camera's code-made looks, `cameraLook-1` (phase 2 design §6.3, plan 2b decision 7): each preset but Natural and
/// Custom is a 3D LUT of 33³ made here, which the render uploads as an `rgba16Float` texture and samples trilinearly
/// with `uvw = c (N − 1) / N + 0.5 / N`. Natural is the identity and draws nothing; Custom is the user's `.cube`.
///
/// Each look takes the color, clamped to 0…1, to linear light (IEC 61966-2-1), multiplies it by its white balance (a
/// gain per channel: black stays black), moves it from or towards its gray by its saturation (`L + s (c − L)`, with `L`
/// the Rec. 709 luma in linear light), encodes it again, then sets its contrast around mid-grey (`0.5 + k (c − 0.5)`)
/// and last sets its blacks: what the contrast made of black, `c₀ = max(0, 0.5 − 0.5 k)`, goes to `b` and 1 stays 1
/// (`b + (c − c₀) (1 − b) / (1 − c₀)`, the identity when `b` and `c₀` are 0). In that order, each step clamped to 0…1.
///
/// | Look | White balance (linear) | Saturation | Contrast | Blacks |
/// |---|---|---|---|---|
/// | Warm | R × 1.06, B × 0.95 | 1.05 | 1 | 0 |
/// | Cool | R × 0.96, B × 1.06 | 1 | 1 | 0 |
/// | Vivid | — | 1.3 | 1.1 | 0 |
/// | Soft | — | 0.9 | 0.9 (black to 0.05) | 0.04 (black to exactly 0.04; white, from 0.95, to 0.9495) |
/// | Black and white | — | 0 (the luma) | 1.05 | 0 |
///
/// Frozen once merged (`cameraLook1IsFrozen`): a different look is a new id.
public enum CameraLooks {
    public static let id = "cameraLook-1"
    /// The points on each side of a look's LUT.
    public static let size = 33

    /// The color `rgb` (sRGB-encoded, 0 to 1) with the look of `preset`: the math each lattice point of its LUT holds.
    /// `rgb` unchanged for Natural and Custom.
    public static func apply(_ preset: CameraColorPreset, to rgb: SIMD3<Float>) -> SIMD3<Float> {
        guard let recipe = Recipe(preset) else { return rgb }
        return SIMD3<Float>(recipe.apply(SIMD3<Double>(rgb)))
    }

    /// The 33³ LUT of `preset`, its domain 0…1 and its point `(r, g, b)` the look of `(r, g, b) / 32`; `nil` for Natural,
    /// which draws nothing, and for Custom, whose LUT is the user's file.
    public static func lut(_ preset: CameraColorPreset) -> CubeLUT? {
        guard Recipe(preset) != nil else { return nil }
        var values: [SIMD3<Float>] = []
        values.reserveCapacity(size * size * size)
        let last = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    values.append(apply(preset, to: SIMD3(Float(r), Float(g), Float(b)) / last))
                }
            }
        }
        return CubeLUT(size: size, domainMin: SIMD3(repeating: 0), domainMax: SIMD3(repeating: 1), values: values)
    }
}

/// The four numbers of a look.
private struct Recipe {
    /// The white balance: a gain per channel, in linear light.
    var gain: SIMD3<Double>
    /// In linear light, around the Rec. 709 luma: 1 keeps the color, 0 is its gray.
    var saturation: Double
    /// Encoded, around 0.5.
    var contrast: Double
    /// Encoded: what black becomes in the end, white staying white.
    var blacks: Double

    init?(_ preset: CameraColorPreset) {
        switch preset {
        case .natural, .custom: return nil
        case .warm: (gain, saturation, contrast, blacks) = (SIMD3(1.06, 1, 0.95), 1.05, 1, 0)
        case .cool: (gain, saturation, contrast, blacks) = (SIMD3(0.96, 1, 1.06), 1, 1, 0)
        case .vivid: (gain, saturation, contrast, blacks) = (SIMD3(1, 1, 1), 1.3, 1.1, 0)
        case .soft: (gain, saturation, contrast, blacks) = (SIMD3(1, 1, 1), 0.9, 0.9, 0.04)
        case .mono: (gain, saturation, contrast, blacks) = (SIMD3(1, 1, 1), 0, 1.05, 0)
        }
    }

    func apply(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        var c = Self.clamped(rgb)
        c = SIMD3(Self.linear(c.x), Self.linear(c.y), Self.linear(c.z))
        c = Self.clamped(c * gain)
        let luma = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        c = Self.clamped(luma + saturation * (c - luma))
        c = SIMD3(Self.encoded(c.x), Self.encoded(c.y), Self.encoded(c.z))
        c = Self.clamped(0.5 + contrast * (c - 0.5))
        let contrastBlack = max(0, 0.5 - 0.5 * contrast)
        return Self.clamped(blacks + (c - contrastBlack) * ((1 - blacks) / (1 - contrastBlack)))
    }

    /// IEC 61966-2-1: sRGB-encoded to linear light.
    private static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// IEC 61966-2-1: linear light to sRGB-encoded.
    private static func encoded(_ l: Double) -> Double {
        l <= 0.0031308 ? 12.92 * l : 1.055 * pow(l, 1 / 2.4) - 0.055
    }

    private static func clamped(_ c: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(min(max(c.x, 0), 1), min(max(c.y, 0), 1), min(max(c.z, 0), 1))
    }
}
