// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The shadow's arithmetic (design §7.3, plan decision 30), in `Float` and in the order the shader does it
/// (`shadowFragment` in `ShaderSource`): `alpha` is the CPU reference of what the GPU draws.
///
/// The shadow of a rounded box blurred by a Gaussian of σ is Evan Wallace's ("Fast Rounded Rectangle Shadows"): along x,
/// exact, with two `erf`, the box's row at each height (narrower in its rounded corners) blurred; along y, that row
/// integrated against the Gaussian at `ySamples` fixed samples, at the middle of equal steps over `[−3σ, 3σ]` clipped to
/// the box. Metal's shading language has no `erf` (nor `metal::precise::erf`, which does not compile), so the shader and
/// this use the same approximation, `erf`.
public enum ShadowMath {
    /// The samples of the integral along y.
    public static let ySamples = 4

    /// Abramowitz and Stegun 7.1.26: `1 − (a₁t + a₂t² + a₃t³ + a₄t⁴ + a₅t⁵) e^(−x²)` with `t = 1 / (1 + 0.3275911 |x|)`,
    /// with the sign of `x`; within 1.5 × 10⁻⁷ of erf, plus the rounding of `Float`.
    public static func erf(_ x: Float) -> Float {
        let a = abs(x)
        let t: Float = 1 / (1 + 0.3275911 * a)
        var poly: Float = 1.061405429
        poly = -1.453152027 + t * poly
        poly = 1.421413741 + t * poly
        poly = -0.284496736 + t * poly
        poly = 0.254829592 + t * poly
        poly = t * poly
        let y: Float = 1 - poly * exp(-a * a)
        return x < 0 ? -y : y
    }

    /// The shadow's alpha at `p` (output pixels): `layer.opacity` times how much of the box, blurred, covers the point. 0
    /// for a layer of which nothing is drawn.
    public static func alpha(at p: SIMD2<Double>, _ layer: ShadowLayer) -> Double {
        guard let box = Box(layer) else { return 0 }
        return Double(box.alpha(at: SIMD2<Float>(p)))
    }

    /// A shadow as the shader takes it, in `Float`: the box, its corners at most half its shorter side, σ and the opacity
    /// at most 1. The compositor draws with these very values.
    struct Box {
        /// The box's top-left and bottom-right corners: the layer's rect moved down by its offset.
        var lower: SIMD2<Float>
        var upper: SIMD2<Float>
        var sigma: Float
        var corner: Float
        var opacity: Float

        /// `nil` when nothing is drawn of `layer`: a rect, an offset or a σ that is not finite, a rect of no size, a σ or
        /// an opacity that is not above 0.
        init?(_ layer: ShadowLayer) {
            let rect = layer.rect
            guard [rect.x, rect.y, rect.width, rect.height, layer.offsetY].allSatisfy(\.isFinite), rect.width > 0, rect.height > 0,
                  layer.sigma.isFinite, layer.sigma > 0, layer.opacity.isFinite, layer.opacity > 0
            else { return nil }
            let top = rect.y + layer.offsetY
            lower = SIMD2(Float(rect.x), Float(top))
            upper = SIMD2(Float(rect.x + rect.width), Float(top + rect.height))
            sigma = Float(layer.sigma)
            let radius = layer.cornerRadius.isFinite ? max(layer.cornerRadius, 0) : 0
            corner = Float(min(radius, min(rect.width, rect.height) / 2))
            opacity = Float(min(layer.opacity, 1))
        }

        /// The shadow's alpha at `point`, as `shadowFragment` works it out.
        func alpha(at point: SIMD2<Float>) -> Float {
            let centre = (lower + upper) * 0.5
            let halfSize = (upper - lower) * 0.5
            let p = point - centre
            // Only the Gaussian's [−3σ, 3σ] that the box covers adds anything.
            let low = p.y - halfSize.y, high = p.y + halfSize.y
            let start = min(max(-3 * sigma, low), high)
            let end = min(max(3 * sigma, low), high)
            let span = (end - start) / Float(ShadowMath.ySamples)
            var y = start + span * 0.5
            var value: Float = 0
            for _ in 0..<ShadowMath.ySamples {
                value += Self.row(p.x, p.y - y, sigma: sigma, corner: corner, halfSize: halfSize) * Self.gaussian(y, sigma: sigma) * span
                y += span
            }
            return opacity * value
        }

        /// The box's row at height `y` from its centre blurred along x by σ, at `x` from its centre: narrower in the
        /// rounded corners.
        private static func row(_ x: Float, _ y: Float, sigma: Float, corner: Float, halfSize: SIMD2<Float>) -> Float {
            let delta = min(halfSize.y - corner - abs(y), 0)
            let curved = halfSize.x - corner + max(0, corner * corner - delta * delta).squareRoot()
            let k = 0.70710678 / sigma
            return 0.5 * (ShadowMath.erf((x + curved) * k) - ShadowMath.erf((x - curved) * k))
        }

        /// The normal density of σ at `x`.
        private static func gaussian(_ x: Float, sigma: Float) -> Float {
            exp(-(x * x) / (2 * sigma * sigma)) / (2.5066282746 * sigma)
        }
    }
}
