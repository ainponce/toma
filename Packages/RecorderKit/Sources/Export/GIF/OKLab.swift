// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// OKLab (Björn Ottosson, 2020): the colour space the GIF palette is built and searched in (design §7.2), where the
/// distance between two colours follows how different they look.
///
/// Colours are sRGB-encoded in 0...1, the render's (the GIF carries no profile). A colour goes through the sRGB curve to
/// linear light, Ottosson's M1 to LMS, the cube root and M2; back, the inverses. The coefficients are written once,
/// here: `shaderSource`, the Metal text the GIF kernels compile, is made from these same `Float`s, so the GPU and the
/// CPU convert with the same numbers. The CPU works in `Double` between its `Float` input and output: in `Float`, the
/// round trip of a dark red with bright green loses 1.2e-5 (M1's inverse and the sRGB curve near black magnify the
/// rounding); in `Double`, under 3e-6. The GPU's `float` stays within 1e-5 of it.
public enum OKLab {
    /// A 3 × 3 matrix by rows.
    struct Rows: Sendable {
        var x: SIMD3<Float>
        var y: SIMD3<Float>
        var z: SIMD3<Float>

        func callAsFunction(_ v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3((SIMD3<Double>(x) * v).sum(), (SIMD3<Double>(y) * v).sum(), (SIMD3<Double>(z) * v).sum())
        }

        /// The product with the MSL `float3` named `vector`, as an MSL expression.
        func metal(times vector: String) -> String {
            [x, y, z].map { "dot(float3(\(OKLab.metal($0.x)), \(OKLab.metal($0.y)), \(OKLab.metal($0.z))), \(vector))" }
                .joined(separator: ",\n        ")
        }
    }

    /// Linear sRGB → LMS.
    static let m1 = Rows(
        x: SIMD3(0.4122214708, 0.5363325363, 0.0514459929),
        y: SIMD3(0.2119034982, 0.6806995451, 0.1073969566),
        z: SIMD3(0.0883024619, 0.2817188376, 0.6299787005))
    /// The cube roots of LMS → (L, a, b).
    static let m2 = Rows(
        x: SIMD3(0.2104542553, 0.7936177850, -0.0040720468),
        y: SIMD3(1.9779984951, -2.4285922050, 0.4505937099),
        z: SIMD3(0.0259040371, 0.7827717662, -0.8086757660))
    /// (L, a, b) → the cube roots of LMS.
    static let m2Inverse = Rows(
        x: SIMD3(1, 0.3963377774, 0.2158037573),
        y: SIMD3(1, -0.1055613458, -0.0638541728),
        z: SIMD3(1, -0.0894841775, -1.2914855480))
    /// LMS → linear sRGB.
    static let m1Inverse = Rows(
        x: SIMD3(4.0767416621, -3.3077115913, 0.2309699292),
        y: SIMD3(-1.2684380046, 2.6097574011, -0.3413193965),
        z: SIMD3(-0.0041960863, -0.7034186147, 1.7076147010))

    /// The sRGB curve: an encoded value up to `srgbKnee` is linear light times `srgbSlope`; above it,
    /// `((c + srgbOffset) / srgbScale) ^ srgbGamma`. `srgbLinearKnee` is the knee in linear light.
    static let srgbKnee: Float = 0.04045
    static let srgbLinearKnee: Float = 0.0031308
    static let srgbSlope: Float = 12.92
    static let srgbOffset: Float = 0.055
    static let srgbScale: Float = 1.055
    static let srgbGamma: Float = 2.4

    /// An sRGB colour in 0...1 in OKLab: L in 0...1 (white is (1, 0, 0)), a and b around 0.
    public static func fromSRGB(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let lms = m1(SIMD3(linear(Double(rgb.x)), linear(Double(rgb.y)), linear(Double(rgb.z))))
        return SIMD3<Float>(m2(SIMD3(cbrt(lms.x), cbrt(lms.y), cbrt(lms.z))))
    }

    /// An OKLab colour in sRGB, not clamped: a colour outside the sRGB gamut comes out of 0...1.
    public static func toSRGB(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let root = m2Inverse(SIMD3<Double>(lab))
        let linearRGB = m1Inverse(root * root * root)
        return SIMD3<Float>(SIMD3(encoded(linearRGB.x), encoded(linearRGB.y), encoded(linearRGB.z)))
    }

    /// The Euclidean distance between two OKLab colours.
    public static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return (d * d).sum().squareRoot()
    }

    private static func linear(_ c: Double) -> Double {
        let (knee, slope, offset, scale) = (Double(srgbKnee), Double(srgbSlope), Double(srgbOffset), Double(srgbScale))
        return c <= knee ? c / slope : pow((c + offset) / scale, Double(srgbGamma))
    }

    private static func encoded(_ l: Double) -> Double {
        let (knee, slope, offset, scale) = (Double(srgbLinearKnee), Double(srgbSlope), Double(srgbOffset), Double(srgbScale))
        return l <= knee ? l * slope : scale * pow(l, 1 / Double(srgbGamma)) - offset
    }

    /// A `Float` as an MSL literal that is that same `Float` (Swift writes the shortest digits that read back to it).
    static func metal(_ value: Float) -> String { "\(value)f" }

    /// The MSL of the conversion, to put before the kernels that use it (it brings `metal_stdlib`):
    /// `float3 oklabFromSRGB(float3 rgb)` and `float oklabDistance(float3 a, float3 b)`, as `fromSRGB` and `distance`.
    /// `precise::pow` keeps the curve as the CPU's whatever the compiler's math mode; MSL has no `cbrt`, so the cube
    /// root is `pow(|x|, 1/3)` with the sign of `x` (LMS is never negative for a colour in 0...1).
    public static let shaderSource: String = """
        #include <metal_stdlib>
        using namespace metal;

        static float oklabLinear(float c) {
            return c <= \(metal(srgbKnee))
                ? c / \(metal(srgbSlope))
                : precise::pow((c + \(metal(srgbOffset))) / \(metal(srgbScale)), \(metal(srgbGamma)));
        }

        static float oklabCubeRoot(float x) {
            return copysign(precise::pow(fabs(x), 1.0f / 3.0f), x);
        }

        static float3 oklabFromSRGB(float3 rgb) {
            float3 linearRGB = float3(oklabLinear(rgb.r), oklabLinear(rgb.g), oklabLinear(rgb.b));
            float3 lms = float3(
                \(m1.metal(times: "linearRGB")));
            float3 root = float3(oklabCubeRoot(lms.x), oklabCubeRoot(lms.y), oklabCubeRoot(lms.z));
            return float3(
                \(m2.metal(times: "root")));
        }

        static float oklabDistance(float3 a, float3 b) {
            float3 d = a - b;
            return precise::sqrt(dot(d, d));
        }

        """
}
